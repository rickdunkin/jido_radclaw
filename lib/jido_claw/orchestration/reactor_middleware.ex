defmodule JidoClaw.Orchestration.ReactorMiddleware do
  @moduledoc """
  The sole event producer for reactor-driven `WorkflowRun`s.

  A `Reactor.Middleware` that translates the Reactor execution lifecycle into
  the durable `WorkflowEvent` log: the run-level `init`/`complete`/`error`
  hooks append `run_started`/`run_completed`/`run_failed`, and the per-step
  `event/3` hook appends the `step_*` timeline (including `step_undone` when a
  saga undo fires). `JidoClaw.Orchestration.ReactorRunner` injects this
  middleware into the reactor it runs (dedup-safe), so a reactor *may* declare
  it in its `middlewares` block but need not; the runner also seeds the run
  identity into the Reactor context as
  `%{tenant: ..., actor: ..., workflow_run: %WorkflowRun{}, reactor: ...}`.

  ## Synchronous in this slice

  Every callback appends synchronously through `WorkflowLog.append`. The
  `event/3` docstring warns it blocks the reactor, but Phase 1 runs
  `async?: false`: appends are deterministic and the per-run `FOR UPDATE`
  lock in `WorkflowEvent.Changes.Allocate` already serializes `seq`. The async
  step-timeline `Writer` is a deferred follow-up for the first concurrent
  producer (the skills->Reactor compiler).

  ## Terminal durability is not owned here

  `run_failed` is status-authority, but `error/2` is best-effort (it returns
  `:ok` so co-resident middleware still see the reason, and logs on append
  failure). The runner's `finalize` backstop guarantees a terminal event for
  any non-terminal run after `Reactor.run` returns, and boot recovery is the
  final net. This middleware never blocks the reactor's forward progress.

  ## JSON-safe payloads

  The `WorkflowEvent.payload` column is jsonb and the projection copies
  `run_completed`'s payload into the run's `result` map column, so payloads
  here carry only identifiers (`inspect(step.name)`) and formatted error
  strings — never raw Ash record structs. Structured result capture is a
  follow-up.
  """

  use Reactor.Middleware

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @impl true
  @spec init(Reactor.context()) :: {:ok, Reactor.context()} | {:error, term()}
  def init(context) do
    case run_from(context) do
      {:ok, run} ->
        # A misconfigured caller fails loudly rather than dropping events: a
        # failed run_started append aborts the run before any step executes.
        case append(run, :run_started, %{reactor: context[:reactor]}, context) do
          {:ok, _event} -> {:ok, context}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, {:invalid_reactor_context, "missing %WorkflowRun{} under :workflow_run"}}
    end
  end

  @impl true
  @spec complete(Reactor.Middleware.result(), Reactor.context()) ::
          {:ok, Reactor.Middleware.result()} | {:error, term()}
  def complete(result, context) do
    with {:ok, run} <- run_from(context),
         {:ok, _event} <- append(run, :run_completed, %{}, context) do
      {:ok, result}
    else
      :error -> {:error, {:invalid_reactor_context, "missing %WorkflowRun{} under :workflow_run"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec error(Reactor.Middleware.error_or_errors(), Reactor.context()) :: :ok
  def error(errors, context) do
    with {:ok, run} <- run_from(context),
         {:ok, _event} <- append(run, :run_failed, %{error: Reason.format(errors)}, context) do
      :ok
    else
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("[ReactorMiddleware] run_failed append failed: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  @spec event(Reactor.Middleware.step_event(), Reactor.Step.t(), Reactor.context()) :: :ok
  def event(step_event, step, context) do
    case map_event(step_event, step) do
      {kind, payload} -> emit(kind, payload, context)
      :ignore -> :ok
    end
  end

  # -- Internal --

  # The per-step timeline mapping. Unmapped events (halts, guard events,
  # undo_start, ...) are ignored — they gain meaning in later phases.
  defp map_event({:run_start, _args}, step), do: {:step_started, step_payload(step)}
  defp map_event({:run_complete, _result}, step), do: {:step_completed, step_payload(step)}

  defp map_event({:run_error, errors}, step),
    do: {:step_failed, Map.put(step_payload(step), :error, Reason.format(errors))}

  defp map_event({:run_retry, _value}, step), do: {:step_retried, step_payload(step)}
  defp map_event(:run_retry, step), do: {:step_retried, step_payload(step)}
  defp map_event(:compensate_complete, step), do: {:step_compensated, step_payload(step)}

  defp map_event({:compensate_continue, _value}, step),
    do: {:step_compensated, step_payload(step)}

  defp map_event(:undo_complete, step), do: {:step_undone, step_payload(step)}
  defp map_event(_step_event, _step), do: :ignore

  defp step_payload(step), do: %{step: inspect(step.name)}

  # Best-effort append for the step timeline: never blocks the reactor.
  defp emit(kind, payload, context) do
    with {:ok, run} <- run_from(context),
         {:ok, _event} <- append(run, kind, payload, context) do
      :ok
    else
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("[ReactorMiddleware] #{kind} append failed: #{inspect(reason)}")
        :ok
    end
  end

  defp append(run, kind, payload, context) do
    WorkflowLog.append(run, kind, payload,
      tenant: run.tenant_id,
      actor: context_actor(context, run)
    )
  end

  defp run_from(%{workflow_run: %WorkflowRun{} = run}), do: {:ok, run}
  defp run_from(_context), do: :error

  defp context_actor(%{actor: actor}, _run) when not is_nil(actor), do: actor
  defp context_actor(_context, run), do: Actor.system(run.tenant_id)
end
