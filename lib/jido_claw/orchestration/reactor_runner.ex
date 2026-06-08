defmodule JidoClaw.Orchestration.ReactorRunner do
  @moduledoc """
  Invocation seam that runs an `Ash.Reactor` under the `WorkflowRun` event
  envelope. Sibling to `JidoClaw.Orchestration.WorkflowRunner` (the cron
  skill-DAG producer); this one drives reactor-authored workflows.

  `run/3` creates the durable `WorkflowRun` (genesis `:pending`) *before*
  `Reactor.run/4`, then seeds the run identity into the Reactor context as
  `%{tenant:, actor:, workflow_run:, reactor:}`. `ReactorMiddleware.init/1`
  appends `run_started` (flipping the run to `:running` in the same
  transaction) and the step/terminal timeline. The reactor never creates the
  run — the envelope does.

  ## Middleware auto-wiring

  The runner is the envelope authority: `run/3` resolves the reactor module to
  a struct and injects `ReactorMiddleware` into it (dedup-safe via an explicit
  membership check — a reactor that already declares the middleware runs its
  original struct unchanged). This guarantees a `run_started`/`run_completed`
  pair, so a *successful* run can never strand the `WorkflowRun` in `:pending`
  for want of a producer. A reactor *may* declare the middleware but need not.

  ## Terminal-durability backstop

  `Reactor.Executor.Init` validates inputs *before* the middleware's `init/1`
  runs, so a missing input / bad context returns `{:error, _}` from
  `Reactor.run` without `run_started` or `run_failed` ever firing — which
  would strand the fresh run in `:pending`. `finalize/3` closes this: after
  `Reactor.run` returns, it reloads the run and, if the status is still
  non-terminal, appends `run_failed` (legal from `:pending`/`:running`). This
  one mechanism also covers a failed terminal append in the middleware. Boot
  recovery (`WorkflowRecovery`) is the final net.

  ## Never raises

  `run/3` returns a run-carrying envelope and never raises:

    * `{:ok, value, run}` — the reactor's return value plus the reloaded run.
    * `{:error, reason, run}` — a failure with the reloaded run.
    * `{:error, reason, nil}` — a *pre-run* failure, before any run exists:
      `{:not_a_reactor, mod}` (the module is not a reactor), `:missing_required_opt`
      (no `:tenant`/`:actor`), a `WorkflowRun.create` failure, or
      `{:exception, msg}` from malformed `opts` (e.g. a non-keyword list) or a
      data-layer raise during run creation.

  Two rescues cover the whole body. A body-level `try/rescue` (mirroring
  `WorkflowRunner.run/1`) normalizes any raise in the *pre-run* path — the
  `Keyword.get`/`Keyword.fetch` opt reads or `WorkflowRun.create` — into
  `{:error, {:exception, msg}, nil}`, since no run exists yet. Once the run is
  created, the `try/rescue` in `execute/6` wraps **both** `Reactor.run/4` and
  `finalize/3`, so a raise anywhere in run-or-finalize is caught (not skipped):
  the rescue calls the non-raising `ensure_failed/3` and returns the in-memory
  run without reloading (avoiding a second raise if the DB is the cause).

  Phase 1 forbids halts: the run options pin `async?: false`,
  `max_iterations: :infinity`, `timeout: :infinity`, and the reactor declares
  no halt steps. `halt/1` / `run_halted` / `run_resumed` land with human gates.
  """

  # run/3 is a never-raises seam (mirrors WorkflowRunner): a body-level rescue
  # normalizes any pre-run raise (malformed opts, a WorkflowRun.create raise),
  # and the rescue in execute/6 normalizes any reactor/finalize raise into the
  # error envelope; reload/ensure_failed rescue their own internal errors.
  # Narrowing the rescues would mean enumerating the open set of reactor/Ash
  # exceptions.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Orchestration.ReactorMiddleware
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias Reactor.Builder

  # Statuses from which a `run_failed` transition is legal — i.e. the run has
  # not yet reached a terminal state (mirrors `Projection`'s non-terminal set).
  @non_terminal [:pending, :running, :awaiting_approval]

  @type run_result ::
          {:ok, term(), WorkflowRun.t()}
          | {:error, term(), WorkflowRun.t() | nil}

  @doc """
  Run `reactor_module` with `inputs` under a fresh `WorkflowRun`.

  Required opts: `:tenant` (a tenant id) and `:actor`. Optional `:name`
  overrides the run name (defaults to `inspect(reactor_module)`). Returns the
  never-raises envelope described in the moduledoc.
  """
  @spec run(module(), map(), keyword()) :: run_result()
  def run(reactor_module, inputs, opts) do
    name = Keyword.get(opts, :name, inspect(reactor_module))

    with {:ok, runnable} <- build_runnable(reactor_module),
         {:ok, tenant} <- Keyword.fetch(opts, :tenant),
         {:ok, actor} <- Keyword.fetch(opts, :actor),
         {:ok, run} <-
           WorkflowRun.create(
             %{
               name: name,
               workflow_type: "reactor",
               config: %{reactor: inspect(reactor_module)}
             },
             tenant: tenant,
             actor: actor
           ) do
      execute(run, runnable, reactor_module, inputs, tenant, actor)
    else
      # Module is not a reactor — no run created yet.
      {:error, :not_a_reactor} -> {:error, {:not_a_reactor, reactor_module}, nil}
      # Missing :tenant / :actor opt — no run created yet.
      :error -> {:error, :missing_required_opt, nil}
      # build_runnable / WorkflowRun.create failed — no run created yet.
      {:error, reason} -> {:error, reason, nil}
    end
  rescue
    # A raise in the pre-run path (non-keyword opts -> Keyword.get/fetch raises;
    # or a data-layer exception escaping WorkflowRun.create) is normalized to
    # the pre-run envelope — no usable run exists yet, so the run slot is nil.
    # Raises *inside* execute/6 are caught by its own rescue, which carries the
    # in-memory run.
    error -> {:error, {:exception, Exception.message(error)}, nil}
  end

  # -- Internal --

  # Finding 1: the runner is the envelope authority — it guarantees
  # ReactorMiddleware is wired, so a successful run can never strand the
  # WorkflowRun in :pending. Dedup via an *explicit membership check* (not by
  # swallowing an add_middleware/2 error): a reactor that already declares the
  # middleware (e.g. ProjectRegistration) runs its original struct, while a
  # genuine add_middleware/2 failure surfaces as a pre-run {:error, reason, nil}
  # rather than silently running an un-augmented, strand-prone reactor.
  @spec build_runnable(module()) :: {:ok, Reactor.t()} | {:error, term()}
  defp build_runnable(reactor_module) do
    if Spark.Dsl.is?(reactor_module, Reactor) do
      base = reactor_module.reactor()

      if ReactorMiddleware in base.middleware do
        {:ok, base}
      else
        Builder.add_middleware(base, ReactorMiddleware)
      end
    else
      {:error, :not_a_reactor}
    end
  end

  # One try/rescue around BOTH Reactor.run AND finalize, so a raise can't skip
  # finalization. `runnable` is the auto-wired struct; `reactor_module` is kept
  # only for the context/config identity string.
  defp execute(run, runnable, reactor_module, inputs, tenant, actor) do
    context = %{
      tenant: tenant,
      actor: actor,
      workflow_run: run,
      reactor: inspect(reactor_module)
    }

    finalize_opts = [tenant: tenant, actor: actor]

    try do
      runnable
      |> Reactor.run(inputs, context,
        run_id: run.id,
        async?: false,
        timeout: :infinity,
        max_iterations: :infinity
      )
      |> finalize(run, finalize_opts)
    rescue
      error ->
        reason = {:exception, Exception.message(error)}
        ensure_failed(run, reason, finalize_opts)
        # In-memory run; do not reload here — a fresh read could raise again if
        # the DB is the cause of the rescue.
        {:error, reason, run}
    end
  end

  defp finalize({:ok, value}, run, opts), do: {:ok, value, reload(run, opts)}
  defp finalize({:ok, value, _reactor}, run, opts), do: {:ok, value, reload(run, opts)}

  defp finalize({:error, reason}, run, opts) do
    ensure_failed(run, reason, opts)
    {:error, reason, reload(run, opts)}
  end

  # No halts in this slice (forbidden via run options + no halt steps); treat a
  # halt defensively as a failure so the run never strands non-terminal.
  defp finalize({:halted, _reactor}, run, opts) do
    ensure_failed(run, :unexpected_halt, opts)
    {:error, :unexpected_halt, reload(run, opts)}
  end

  # Appends `run_failed` only when the reloaded run is still non-terminal (else
  # the middleware already recorded the terminal — no-op). Strictly
  # non-raising: rescues its own reload/append errors so a fresh failure can't
  # escape into the caller's already-entered try/rescue.
  defp ensure_failed(run, reason, opts) do
    reloaded = reload(run, opts)

    if reloaded.status in @non_terminal do
      append_failed(reloaded, reason, opts)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("[ReactorRunner] ensure_failed crashed for run #{run.id}: #{inspect(error)}")
      :ok
  end

  defp append_failed(run, reason, opts) do
    case WorkflowLog.append(run, :run_failed, %{error: Reason.format(reason)},
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, _event} ->
        :ok

      {:error, append_error} ->
        Logger.warning(
          "[ReactorRunner] backstop run_failed append failed for run #{run.id}: #{inspect(append_error)}"
        )

        :ok
    end
  end

  # Tenant-scoped reload; falls back to the in-memory run on any failure so the
  # envelope always carries a non-nil run and this never raises.
  defp reload(run, opts) do
    case WorkflowRun.by_id(run.id,
           tenant: Keyword.get(opts, :tenant),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _ -> run
    end
  rescue
    _error -> run
  end
end
