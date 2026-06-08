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

  ## Gate pause (human approval)

  A gate-bearing reactor's `GateStep` returns `{:halt, _}`, so `Reactor.run`
  returns `{:halted, reactor}`. `finalize/3` treats a halt as a **legitimate
  gate pause iff the reloaded run is `:awaiting_approval`** (only the gate's
  in-transaction `approval_requested` reaches that status). On a legit pause it
  persists the serialized halted reactor as the run's durable
  `resume_checkpoint`, looks up the pending `AgentCase`, broadcasts
  `{:gate_requested, …}` (only *after* the checkpoint exists — closing the
  approve-before-checkpoint race), and returns `{:ok, {:paused, case_id}, run}`
  — the same 3-element envelope, with `{:paused, id}` as the value (Decision 4).
  Any other halt (status unchanged, or `{:halted}` from `max_iterations`) stays
  a defensive failure via `ensure_failed/3`.

  `finalize/3` is the **shared finalizer**: `JidoClaw.Orchestration.GateResume`
  reuses it so the initial run and every resume complete/fail/re-pause through
  one path. The terminal-clears-checkpoint rule lives in the projection
  (Decision 7), so the runner never clears a checkpoint by hand.
  """

  # run/3 is a never-raises seam (mirrors WorkflowRunner): a body-level rescue
  # normalizes any pre-run raise (malformed opts, a WorkflowRun.create raise),
  # and the rescue in execute/6 normalizes any reactor/finalize raise into the
  # error envelope; reload/ensure_failed rescue their own internal errors.
  # Narrowing the rescues would mean enumerating the open set of reactor/Ash
  # exceptions.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ReactorMiddleware
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias Reactor.Builder

  # Statuses from which a `run_failed` transition is legal — i.e. the run has
  # not yet reached a terminal state (mirrors `Projection`'s non-terminal set).
  @non_terminal [:pending, :running, :awaiting_approval]

  # Checkpoint envelope version. The encoded blob is
  # `term_to_binary({@checkpoint_version, module_string, inner_binary})` — an
  # all-builtin outer tuple so `GateResume` can decode it with `[:safe]`
  # *before* the gate-reactor module's atoms are loaded. Bump on any envelope
  # shape change; `GateResume` rejects unknown versions.
  @checkpoint_version 1

  # Cancellation reason stamped on a pending case when a gate pause fails to
  # persist; also the human-facing `run_failed` error context.
  @gate_pause_reason "gate pause failed"

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

    # `inputs` + `reactor_module` ride in the finalizer opts so the halted
    # clause can serialize a checkpoint (Reactor re-validates declared inputs
    # on resume, and the module string keys the safe decode). `reactor_module`
    # is also needed to re-encode if a *resumed* run halts again at a later gate.
    finalize_opts = [
      tenant: tenant,
      actor: actor,
      inputs: inputs,
      reactor_module: reactor_module
    ]

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

  @doc false
  # The shared finalizer: the initial `run/3` and every `GateResume.resume/2`
  # route their `Reactor.run` result through here, so completion, failure, and
  # gate-pause are handled identically. `opts` carries `:tenant`, `:actor`,
  # `:inputs`, and `:reactor_module`.
  @spec finalize(
          {:ok, term()} | {:ok, term(), Reactor.t()} | {:error, term()} | {:halted, Reactor.t()},
          WorkflowRun.t(),
          keyword()
        ) :: run_result()
  def finalize({:ok, value}, run, opts), do: {:ok, value, reload(run, opts)}
  def finalize({:ok, value, _reactor}, run, opts), do: {:ok, value, reload(run, opts)}

  def finalize({:error, reason}, run, opts) do
    ensure_failed(run, reason, opts)
    {:error, reason, reload(run, opts)}
  end

  # A halt is a legitimate gate pause iff the reloaded run is
  # `:awaiting_approval` — only the gate step's in-transaction
  # `approval_requested` flips it there. Any other halt (status unchanged, or
  # `{:halted}` from `max_iterations`) is defensively failed so a run never
  # strands non-terminal.
  def finalize({:halted, reactor}, run, opts) do
    reloaded = reload(run, opts)

    if reloaded.status == :awaiting_approval do
      handle_gate_pause(reactor, reloaded, opts)
    else
      ensure_failed(run, :unexpected_halt, opts)
      {:error, :unexpected_halt, reload(run, opts)}
    end
  end

  # Persist the durable checkpoint, capture the pending case id *before*
  # broadcasting (so the broadcast→approve→resume race can't clear the case out
  # from under the lookup), then announce the gate now that its checkpoint
  # exists.
  defp handle_gate_pause(reactor, run, opts) do
    with {:ok, checkpoint} <- safe_encode_checkpoint(reactor, opts),
         {:ok, updated} <-
           WorkflowRun.set_checkpoint(run, %{resume_checkpoint: checkpoint},
             tenant: Keyword.get(opts, :tenant, run.tenant_id),
             actor: Keyword.get(opts, :actor)
           ),
         {:ok, case_id} <- pending_case_id(updated, opts) do
      RunPubSub.broadcast_gate(
        {:gate_requested, updated.id, %{tenant_id: updated.tenant_id, agent_case_id: case_id}}
      )

      {:ok, {:paused, case_id}, updated}
    else
      {:error, reason} ->
        # Checkpoint encode/write failed, or the (just-committed) pending case
        # vanished — none should happen. Cancel the pending case AND fail the run
        # in one transaction so a terminal run never leaves a stale :pending case
        # in the inbox.
        cancel_pending_and_fail(run, reason, opts)
        {:error, {:gate_pause_failed, reason}, reload(run, opts)}
    end
  end

  # Fold the checkpoint serialization into the gate-pause `with` so a
  # `term_to_binary` raise (the 4th, otherwise-leaking failure path — it would
  # escape to execute/6's rescue → ensure_failed → stale :pending case) takes
  # the same cancellation path as a checkpoint-write or pending-case failure.
  # The rescue here is covered by the file-level bare_rescue pragma.
  defp safe_encode_checkpoint(reactor, opts) do
    {:ok,
     encode_checkpoint(
       reactor,
       Keyword.get(opts, :inputs, %{}),
       Keyword.fetch!(opts, :reactor_module)
     )}
  rescue
    error -> {:error, {:encode_failed, Exception.message(error)}}
  end

  # On any gate-pause failure, cancel the pending case(s) AND fail the run in one
  # transaction (the shared WorkflowLog helper), so a terminal run never leaves a
  # stale :pending case behind. The cancellation MUST be in the terminal's
  # transaction: failing the run alone while leaving the case :pending is
  # strictly worse than today, because a terminal run is never re-scanned by
  # recovery → permanent orphan.
  defp cancel_pending_and_fail(run, reason, opts) do
    case WorkflowLog.terminate_cancelling_cases(
           run,
           :run_failed,
           %{error: Reason.format({:gate_pause_failed, reason})},
           @gate_pause_reason,
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, _} ->
        :ok

      {:error, cleanup_error} ->
        # Cleanup transaction rolled back. Do NOT fall back to a run-only
        # ensure_failed — a terminal run + still-:pending case is never
        # re-scanned. Leaving the run :awaiting_approval (no checkpoint, or
        # checkpoint-but-no-case) lets recovery's dangling-gate / parked-orphan
        # branch reap it on the next boot.
        Logger.warning(
          "[ReactorRunner] gate-pause cleanup failed for run #{run.id}: " <>
            "#{inspect(cleanup_error)} — leaving for recovery"
        )

        :ok
    end
  end

  defp pending_case_id(run, opts) do
    case AgentCase.pending_for_run(run.id,
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, [%AgentCase{id: id} | _]} -> {:ok, id}
      {:ok, []} -> {:error, :pending_case_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two-layer envelope: the outer tuple is all-builtin
  # (`{integer, string, binary}`) so `GateResume` can `binary_to_term/[:safe]`
  # it without the gate-reactor module's atoms loaded; the inner binary holds
  # the halted `%Reactor{}` + the original inputs and is decoded only once the
  # module is confirmed loaded.
  defp encode_checkpoint(reactor, inputs, module) do
    inner = :erlang.term_to_binary({reactor, inputs})
    :erlang.term_to_binary({@checkpoint_version, Atom.to_string(module), inner})
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
