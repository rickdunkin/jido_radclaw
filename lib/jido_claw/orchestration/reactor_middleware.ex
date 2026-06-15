defmodule JidoClaw.Orchestration.ReactorMiddleware do
  @moduledoc """
  The sole event producer for reactor-driven `WorkflowRun`s.

  A `Reactor.Middleware` that translates the Reactor execution lifecycle into
  the durable `WorkflowEvent` log: the run-level `init`/`halt`/`complete`/`error`
  hooks append `run_started` (or `run_resumed`) / `run_halted` /
  `run_completed` / `run_failed`, and the per-step `event/3` hook appends the
  `step_*` timeline (including `step_undone` when a saga undo fires).
  `JidoClaw.Orchestration.ReactorRunner` injects this middleware into the
  reactor it runs (dedup-safe), so a reactor *may* declare it in its
  `middlewares` block but need not; the runner also seeds the run identity into
  the Reactor context as
  `%{tenant: ..., actor: ..., workflow_run: %WorkflowRun{}, reactor: ...}`.

  ## Run-lifecycle broadcasts (dashboard)

  This middleware also owns the `RunPubSub` run-lifecycle broadcasts, fired
  **after** each durable append succeeds: `init/1`'s initial-start branch →
  `{:run_started, …}` (so the run is already `:running`, never broadcast while
  still `:pending`), `complete/2` → `{:run_completed, …}`, `error/2` →
  `{:run_failed, …}`. The resume path does not broadcast (`Cases.decide`
  already emits `{:gate_resolved, …}`). The runner's terminal backstop also
  appends `run_failed` for pre-`init/1` failures and broadcasts there — mutually
  exclusive with `error/2` via its non-terminal guard, so no double-fire.

  ## Live trace overlay

  The same lifecycle hooks emit `[:jido_claw, :workflow, :event]` telemetry via
  `JidoClaw.Trace.emit(:workflow, …)` (the collector pre-attaches this event),
  so in-flight workflow runs appear in the live trace inspection surface.
  Fired after each durable append succeeds, same policy as the broadcasts;
  metadata carries `event`/`status`/`name`/`run_id`/`tenant_id` and the
  terminal events add `%{duration_ms: …}`.

  ## Enriched step payloads

  `step_*` payloads always carry the positional Reactor id (`step:
  inspect(step.name)`), and additionally the human YAML `name` plus
  `step_type` when the skills compiler threaded them into the impl options.
  `step_completed` includes a JSON-safe `output` summary of the step's return
  value. `WorkflowEvent.Changes.Allocate` projects these into per-step
  `WorkflowStep` rows keyed on the human name.

  ## `init/1` is the single producer of `run_started`/`run_resumed`

  Reactor injects `context.__reactor__.initial_state` — `:pending` on a fresh
  run, `:halted` on **every** resume (operator approve **and** boot recovery).
  `init/1` branches on it: `:pending` appends `run_started`, `:halted` appends
  `run_resumed`. This makes `init/1` the sole producer of both for every resume
  path — callers (`ReactorRunner`, `GateResume`) never append them. A failed
  `run_started` on the **initial** start fails loudly (aborting before any step
  drops events); a failed `run_resumed` on **resume** is best-effort **while
  the run is live** (provenance — the decision is already durable), but a run
  that reloads **terminal** hard-stops the resume (the cancel-before-register
  race: the durable decision wins, mirroring the fresh-start abort).

  ## `halt/1` always succeeds

  A gate step returns `{:halt, _}`, pausing the reactor. `halt/1` appends
  `run_halted` (provenance only — the in-transaction `approval_requested` from
  `WorkflowLog.gate_open/3` is the authoritative status event) and **always
  returns `{:ok, context}`**, even when the append fails: a `halt/1` error
  would turn the paused run into `Reactor.run`'s `{:error, _}` rather than the
  `{:halted, _}` the runner needs to persist a checkpoint.

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

  ## JSON-safe payloads + result capture

  The `WorkflowEvent.payload` column is jsonb and the projection copies
  `run_completed`'s payload into the run's `result` map column. Step-timeline
  payloads carry only identifiers (`inspect(step.name)`) and formatted error
  strings. `complete/2` captures the reactor's **return value** into the
  `run_completed` payload as `%{result: value}` — but only when `value` passes
  the recursive `json_safe?/1` guard (binary/number/boolean/nil; lists thereof;
  maps with binary/atom keys and json-safe values — no structs, tuples, pids,
  refs, funs); otherwise it stores `%{}`. A bare `is_map` check is insufficient
  because `Transcript.redact/1` leaves non-JSON terms unchanged, so a dev
  reactor returning `%{workspace: %Workspace{}}` (or a tuple) would persist and
  then blow up on JSON encode. A compiled skill's `CollectStep` returns a
  strings/ints/nil map (json-safe → persisted); dev reactors returning Ash
  structs store `%{}` (result stays nil).
  """

  use Reactor.Middleware

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Trace
  alias JidoClaw.Workflows.StepResult

  # Folds onto `WorkflowEvent.Projection`'s terminal set — the compile-time call
  # bakes the literal list into the `status in @terminal` guard below: a resume
  # whose run has already reached one of these must hard-stop, never execute a step.
  @terminal Projection.terminal_statuses()

  @impl Reactor.Middleware
  @spec init(Reactor.context()) :: {:ok, Reactor.context()} | {:error, term()}
  def init(context) do
    case run_from(context) do
      {:ok, run} -> init_for_state(run, context)
      :error -> {:error, {:invalid_reactor_context, "missing %WorkflowRun{} under :workflow_run"}}
    end
  end

  # Resume (operator approve OR boot recovery): `run_resumed` is provenance; the
  # decision (`approval_resolved`/`run_cancelled`) is already durable, so a
  # failed append is best-effort while the run is live — but a run that reloads
  # terminal hard-stops the resume (the cancel-before-register race).
  defp init_for_state(run, %{__reactor__: %{initial_state: :halted}} = context) do
    case append(run, :run_resumed, %{reactor: context[:reactor]}, context) do
      {:ok, _event} ->
        trace(run, :run_resumed, :running)
        {:ok, context}

      {:error, reason} ->
        explain_resume_append_failure(run, reason, context)
    end
  end

  # Initial start (`:pending`, or any non-resume state): a misconfigured caller
  # fails loudly rather than dropping events — a failed run_started append
  # aborts the run before any step executes. Broadcast only AFTER the durable
  # append, so subscribers never see `run_started` while the run is `:pending`.
  # The payload carries the run's `definition_hash` when one was stamped
  # (durable provenance for the Phase-4 replay gates); the context-seeded run
  # is the genesis snapshot from `WorkflowRun.create`, so the column is
  # already populated.
  defp init_for_state(run, context) do
    payload =
      put_present(%{reactor: context[:reactor]}, :definition_hash, run.definition_hash)

    case append(run, :run_started, payload, context) do
      {:ok, _event} ->
        broadcast(run, {:run_started, run.id, lifecycle_info(run, status: :running)})
        trace(run, :run_started, :running)
        {:ok, context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only reached on a failed `run_resumed` append (zero cost on the happy
  # path). A reload that reads terminal means the projection's transition
  # guard refused the append — a cancel/abandon landed before the resumed
  # executor registered — so abort before any downstream step executes,
  # mirroring the fresh-start `run_started` abort. A still-live or unreadable
  # reload keeps the best-effort contract: a transient DB blip on a provenance
  # append must never fail a healthy run.
  defp explain_resume_append_failure(run, reason, context) do
    case WorkflowRun.by_id(run.id, tenant: run.tenant_id, actor: context_actor(context, run)) do
      {:ok, %WorkflowRun{status: status}} when status in @terminal ->
        {:error, {:run_already_terminal, status}}

      _live_or_unreadable ->
        Logger.warning("[ReactorMiddleware] run_resumed append failed: #{inspect(reason)}")
        {:ok, context}
    end
  end

  @impl Reactor.Middleware
  @spec halt(Reactor.context()) :: {:ok, Reactor.context()}
  def halt(context) do
    with {:ok, run} <- run_from(context),
         {:ok, _event} <- append(run, :run_halted, %{reactor: context[:reactor]}, context) do
      trace(run, :run_halted, :awaiting_approval)
      :ok
    else
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("[ReactorMiddleware] run_halted append failed: #{inspect(reason)}")
        :ok
    end

    # ALWAYS {:ok, context} — a halt/1 error would turn the paused run into
    # Reactor.run's {:error, _} (executor.ex), losing the {:halted, _} the
    # runner needs. `approval_requested` already carries the status authority.
    {:ok, context}
  end

  @impl Reactor.Middleware
  @spec complete(Reactor.Middleware.result(), Reactor.context()) ::
          {:ok, Reactor.Middleware.result()} | {:error, term()}
  def complete(result, context) do
    with {:ok, run} <- run_from(context),
         {:ok, event} <- append(run, :run_completed, result_payload(result), context) do
      broadcast(
        run,
        {:run_completed, run.id,
         lifecycle_info(run, status: :completed, completed_at: event.occurred_at)}
      )

      trace(run, :run_completed, :completed, duration_measurements(run, event.occurred_at))
      {:ok, result}
    else
      :error -> {:error, {:invalid_reactor_context, "missing %WorkflowRun{} under :workflow_run"}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Capture the reactor's return value into the run_completed payload only when
  # it is JSON-safe (the projection copies payload[:result] into the jsonb
  # result column, then it round-trips through JSON encode). A skill's
  # CollectStep map qualifies; a dev reactor returning an Ash struct does not.
  defp result_payload(result) do
    if json_safe?(result), do: %{result: result}, else: %{}
  end

  @impl Reactor.Middleware
  @spec error(Reactor.Middleware.error_or_errors(), Reactor.context()) :: :ok
  def error(errors, context) do
    formatted = Reason.format(errors)

    with {:ok, run} <- run_from(context),
         {:ok, event} <- append(run, :run_failed, %{error: formatted}, context) do
      broadcast(
        run,
        {:run_failed, run.id,
         lifecycle_info(run, status: :failed, error: formatted, completed_at: event.occurred_at)}
      )

      trace(run, :run_failed, :failed, duration_measurements(run, event.occurred_at))
      :ok
    else
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("[ReactorMiddleware] run_failed append failed: #{inspect(reason)}")
        :ok
    end
  end

  @impl Reactor.Middleware
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

  defp map_event({:run_complete, result}, step),
    do: {:step_completed, Map.merge(step_payload(step), result_summary(result))}

  defp map_event({:run_error, errors}, step),
    do: {:step_failed, Map.put(step_payload(step), :error, Reason.format(errors))}

  defp map_event({:run_retry, _value}, step), do: {:step_retried, step_payload(step)}
  defp map_event(:run_retry, step), do: {:step_retried, step_payload(step)}

  # A compensate-driven retry (`compensate/4` -> `:retry`, the skill `retry:`
  # policy in `AgentStep`) emits `compensate_retry`, NOT `run_retry`
  # (step_runner.ex handle_compensate_result) — without these clauses the
  # catch-all would silently drop every policy-driven retry.
  defp map_event({:compensate_retry, _reason}, step), do: {:step_retried, step_payload(step)}
  defp map_event(:compensate_retry, step), do: {:step_retried, step_payload(step)}
  defp map_event(:compensate_complete, step), do: {:step_compensated, step_payload(step)}

  defp map_event({:compensate_continue, _value}, step),
    do: {:step_compensated, step_payload(step)}

  defp map_event(:undo_complete, step), do: {:step_undone, step_payload(step)}
  defp map_event(_step_event, _step), do: :ignore

  # Map a compiled-skill step impl to the durable `step_type` recorded on the
  # projected `WorkflowStep` row. Dev-reactor steps (arbitrary impls) map to
  # nil and the key is omitted.
  @step_types %{
    JidoClaw.Skills.Steps.AgentStep => "agent",
    JidoClaw.Skills.Steps.IterativeStep => "iterative",
    JidoClaw.Skills.Steps.CollectStep => "collect",
    JidoClaw.Orchestration.GateStep => "gate"
  }

  # The enriched per-step payload: `:step` is always the positional Reactor id
  # (`inspect(step.name)`, e.g. `":step_1"` — the fallback identity); `:name`
  # is the human YAML step name when the compiler threaded one into the impl
  # options (`step_name:`); `:step_type` is derived from the impl module; an
  # `irreversible: true` flag rides along as durable metadata for the Phase-4
  # replay gates; `:deadline` is the validated per-step lateness policy
  # (T2-1). Static metadata deliberately rides EVERY step_* payload — a step
  # row can be created by a completed/failed event when step_started was
  # missed, and `Allocate.step_attrs/3` must still see it.
  defp step_payload(step) do
    %{step: inspect(step.name)}
    |> put_present(:name, yaml_name(step))
    |> put_present(:step_type, step_type(step))
    |> put_present(:irreversible, irreversible_flag(step))
    |> put_present(:deadline, deadline_policy(step))
    |> put_present(:depends_on, depends_on(step))
  end

  defp yaml_name(%{impl: {_mod, opts}}) when is_list(opts), do: Keyword.get(opts, :step_name)
  defp yaml_name(_step), do: nil

  # `true` or nil (omitted) — only an explicit declaration is recorded.
  defp irreversible_flag(%{impl: {_mod, opts}}) when is_list(opts) do
    if Keyword.get(opts, :irreversible, false) == true, do: true
  end

  defp irreversible_flag(_step), do: nil

  # The compiler-normalized lateness policy, or nil (omitted) when the step
  # declares none (dev-reactor steps always omit).
  defp deadline_policy(%{impl: {_mod, opts}}) when is_list(opts), do: Keyword.get(opts, :deadline)
  defp deadline_policy(_step), do: nil

  # Declared upstream YAML step names (T3-1): the compiler-stamped
  # depends_on ∪ consumes union. Empty lists map to nil (omitted) so
  # edge-less steps stay payload-light; plain name strings pass `Transcript`
  # untouched.
  defp depends_on(%{impl: {_mod, opts}}) when is_list(opts) do
    case Keyword.get(opts, :depends_on) do
      [_ | _] = deps -> deps
      _none_or_empty -> nil
    end
  end

  defp depends_on(_step), do: nil

  defp step_type(%{impl: {mod, opts}}) when is_atom(mod) and is_list(opts),
    do: Map.get(@step_types, mod)

  defp step_type(%{impl: mod}) when is_atom(mod), do: Map.get(@step_types, mod)
  defp step_type(_step), do: nil

  # JSON-safe summary of a completed step's return value, carried on the
  # `step_completed` payload (and projected into `WorkflowStep.output`):
  # an `AgentStep` `%StepResult{}` is summarized field-wise; an
  # `IterativeStep`'s `[%StepResult{}, ...]` becomes a results list; a
  # JSON-safe map (`CollectStep`) is stored as-is; any other JSON-safe value is
  # wrapped under `:result`; everything else is omitted.
  defp result_summary(%StepResult{} = result) do
    output =
      %{result: result.result}
      |> put_present(:template, result.template)
      |> put_present(:typed_output, json_safe_or_nil(result.typed_output))

    %{output: output}
  end

  defp result_summary([%StepResult{} | _] = results) do
    if Enum.all?(results, &match?(%StepResult{}, &1)) do
      %{output: %{results: Enum.map(results, &%{name: &1.name, result: &1.result})}}
    else
      %{}
    end
  end

  defp result_summary(value) when is_map(value) and not is_struct(value) do
    if json_safe?(value), do: %{output: value}, else: %{}
  end

  defp result_summary(value) do
    if json_safe?(value), do: %{output: %{result: value}}, else: %{}
  end

  defp json_safe_or_nil(value), do: if(json_safe?(value), do: value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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

  # The run-lifecycle broadcast payload. The dashboard subscribes for the tag +
  # run id and refreshes; these fields are for projections/tests.
  defp lifecycle_info(run, extra) do
    Map.merge(
      %{tenant_id: run.tenant_id, name: run.name, workflow_type: run.workflow_type},
      Map.new(extra)
    )
  end

  defp broadcast(run, event), do: RunPubSub.broadcast(run.id, event)

  # Live in-flight overlay: `[:jido_claw, :workflow, :event]` telemetry the
  # Trace collector already attaches. Fired after each durable append succeeds
  # (same policy as the RunPubSub broadcasts); `run_id` correlates events to
  # the durable WorkflowRun.
  defp trace(run, event, status, measurements \\ %{}) do
    Trace.emit(
      :workflow,
      %{
        event: event,
        status: status,
        name: run.name,
        workflow_type: run.workflow_type,
        run_id: run.id,
        tenant_id: run.tenant_id
      },
      measurements
    )
  end

  # Wall-clock from run creation to the terminal event. The context-seeded run
  # struct is the genesis snapshot, so `inserted_at` (not the projected
  # `started_at`, which is nil on that snapshot) is the stable anchor.
  defp duration_measurements(%WorkflowRun{inserted_at: %DateTime{} = at}, %DateTime{} = ended),
    do: %{duration_ms: DateTime.diff(ended, at, :millisecond)}

  defp duration_measurements(_run, _ended), do: %{}

  @doc """
  Recursive JSON-safety guard for a reactor's return value before it is
  persisted into the `run_completed` payload (and thence `WorkflowRun.result`).

  Accepts binaries, numbers, booleans, and `nil`; lists of safe values; and
  maps with binary/atom keys and safe values. Rejects structs, tuples, pids,
  refs, and functions — terms `Transcript.redact/1` leaves intact but that
  would crash on JSON encode.
  """
  @spec json_safe?(term()) :: boolean()
  def json_safe?(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: true

  def json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  def json_safe?(value) when is_struct(value), do: false

  def json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {k, v} -> (is_binary(k) or is_atom(k)) and json_safe?(v) end)
  end

  def json_safe?(_value), do: false
end
