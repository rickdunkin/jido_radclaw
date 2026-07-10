defmodule JidoClaw.Orchestration.GateResume do
  @moduledoc """
  The shared "run the persisted reactor" mechanism for a resumed gate.

  `resume/2` is **pure deserialize + run + finalize — it appends no status
  event itself**. The `approval_resolved` status flip is committed atomically
  by `JidoClaw.Orchestration.Cases.decide/4` *before* this is ever called (and
  on the boot-recovery path the decision is already durable), so by the time
  we resume the run is already `:running`. `ReactorMiddleware.init/1` appends
  `run_resumed` automatically on the resumed run (it sees
  `initial_state: :halted` — Decision 6), so this module never appends it.

  Used by two callers, with one difference (Decision 8):

    * `Cases.decide/4` (operator approve) — after `resume/2` returns, the caller
      runs the gate's `after_approved` hook (best-effort).
    * `WorkflowRecovery` (boot recovery, `recovered: true`) — the hook is
      **skipped**; durability comes from the reactor's downstream steps, which
      re-run from the frozen gate-halt checkpoint.

  ## Resume contract

  When the gate step halted it was **dropped from the plan** and its halt value
  (the `AgentCase` id) stored as the step's intermediate result. So on resume:

    * `resume/2` sources the operator decision from the durable **approved
      `AgentCase`** (never a parameter) and seeds it into the resumed reactor's
      `context[:approval]`. A downstream step that needs it reads
      `context[:approval]` in its own `run/3` — Reactor's `argument` sources are
      input/result/value only, so there is no `argument … context:` form; use
      `wait_for` to position a step after the gate.
    * Downstream steps must **not** depend on the gate step's result (it is the
      case id, meaningless downstream) for anything but ordering.
    * The full original input set is re-supplied — Reactor re-validates every
      declared input on each run.
    * Downstream steps must be idempotent: a crash mid-resume re-runs them from
      the frozen gate-halt checkpoint (Decision 7 caveat; per-step idempotency
      keys are a Phase-4 follow-up).

  ## Killable execution

  The resumed reactor runs through
  `JidoClaw.Orchestration.RunExecution.run_killable/4` (same seam as
  `ReactorRunner.execute`), so a resumed run is killable by
  `JidoClaw.Orchestration.Cancellation` too. An executor death maps through
  `ReactorRunner.finalize_exit/3` (cancelled vs crash); a registration
  conflict — a defense-in-depth same-node duplicate after the DB resume claim — returns
  `{:error, {:already_running, pid}, run}` and must leave the winner's
  `:running` run untouched (never `ensure_failed`).

  ## Safe decode (the only place DB content becomes an atom)

  The checkpoint is the two-layer envelope `ReactorRunner` writes, encrypted
  at rest by AshCloak (`encrypted_resume_checkpoint`); this module is the
  **only** consumer that decrypts it (loading the `resume_checkpoint`
  calculation — every other consumer checks presence on the encrypted column).
  The decrypted outer layer `{version, module_string, inner}` is all-builtin,
  so it decodes with `[:safe]` before any gate-reactor atom exists. The module
  string is accepted **only** if it starts with an allowlisted gate-reactor
  prefix — bounding atom creation to our own namespace — and the module must
  be loaded (`Code.ensure_loaded?/1`). Only *then* is the inner binary (the
  halted `%Reactor{}` + inputs) decoded with `[:safe]`, its atoms now
  resolvable. Any undecryptable / corrupt / undecodable / disallowed /
  unknown-version / unloaded-module blob fails-with-audit (appends
  `run_failed`, logs) — it never resumes.

  Decode happens only after a mode-specific ownership check. Ordinary approval
  receives the live token atomically rotated by the decision transaction and
  reuses it; live reclaim likewise reuses the token `claim_next/1` already
  rotated. The `:parked` mode remains for lower-level/manual callers that must
  promote a parked NULL/expired lease, while the synchronous boot barrier may
  CAS-force a future claim left by the dead prior BEAM. A loser returns
  `:resume_claim_lost` before decrypting, and every preflight failure append
  carries the winning token.
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  # Must match `ReactorRunner`'s encoder. Bump together on any envelope change.
  @checkpoint_version 1

  # Atom-creation fence: a checkpoint module string must name a reactor in our
  # own gate-reactor namespace. This is the boundary where DB content becomes
  # an atom, so it is constrained to a known prefix before `String.to_atom/1`.
  @allowed_module_prefix "Elixir.JidoClaw.Orchestration.Reactors."

  @doc """
  Reload `run`, claim its parked lease, decode its checkpoint, and resume the persisted reactor through
  the shared `ReactorRunner.finalize`. Returns the same envelope as
  `ReactorRunner.run/3` (`{:ok, value, run}` / `{:ok, {:paused, id}, run}` /
  `{:error, reason, run}`). Resumes only a `:running` run that still carries a
  checkpoint; any other state is a clean `{:error, :not_resumable, run}`
  (no mutation).

  Opts: `:tenant`, `:actor`, `:recovered` (informational; the hook-skip on the
  recovery path is enforced by the caller), and the internal `:claim_mode`:
  `:parked` (default low-level fallback), `:boot_force` (the synchronous
  sole-owner boot barrier may CAS-rotate regardless of a future expiry), or
  `{:reuse, token}` (the decision transaction or live reclaim already rotated
  the token and must reuse it).
  """
  @spec resume(WorkflowRun.t(), keyword()) :: ReactorRunner.run_result()
  def resume(run, opts \\ []) do
    tenant = Keyword.get(opts, :tenant, run.tenant_id)
    actor = Keyword.get(opts, :actor) || Actor.system(tenant)
    reloaded = reload(run, tenant, actor)

    cond do
      reloaded.status != :running ->
        {:error, {:not_resumable, reloaded.status}, reloaded}

      # Presence is the ENCRYPTED column — the `resume_checkpoint` calculation
      # is `%Ash.NotLoaded{}` on a plain read; only the decode path below
      # loads/decrypts it.
      is_nil(reloaded.encrypted_resume_checkpoint) ->
        {:error, :not_resumable_no_checkpoint, reloaded}

      true ->
        claim_and_resume(
          reloaded,
          Keyword.get(opts, :claim_mode, :parked),
          tenant,
          actor
        )
    end
  end

  # -- Internal --

  # Low-level fallback for a caller that did not atomically preclaim in its
  # decision transaction. Claim BEFORE decrypt/read preflight. The parked-expiry
  # predicate means a second contender cannot rotate a live winner even when it
  # reloads after the first rotation. Every failure terminal below carries this
  # token into fence B, so only the preflight owner can fail the run.
  defp claim_and_resume(run, :parked, tenant, actor) do
    token = Ash.UUID.generate()

    case WorkflowLease.claim_resume(run.id, token, run.claim_token) do
      {:ok, :claimed} ->
        claimed = reload(run, tenant, actor)
        do_resume(claimed, token, tenant, actor)

      {:ok, :lost} ->
        {:error, :resume_claim_lost, reload(run, tenant, actor)}

      {:error, reason} ->
        {:error, {:resume_claim_failed, reason}, reload(run, tenant, actor)}
    end
  end

  # Boot recovery is a synchronous startup barrier: no executor from the prior
  # BEAM survives, and external decision/launch surfaces have not started yet.
  # It may therefore CAS-force a fresh token even when the crashed resumer left
  # a future expiry. The expected-token CAS still catches data races/corruption.
  defp claim_and_resume(run, :boot_force, tenant, actor) do
    token = Ash.UUID.generate()

    case WorkflowLease.stamp(run.id, token, run.claim_token, tenant: tenant) do
      {:ok, :claimed} -> do_resume(reload(run, tenant, actor), token, tenant, actor)
      {:ok, :lost} -> {:error, :resume_claim_lost, reload(run, tenant, actor)}
      {:error, reason} -> {:error, {:resume_claim_failed, reason}, reload(run, tenant, actor)}
    end
  end

  # `ReclaimPooler.claim_next/1` already rotated this run to `token` and gave it
  # a live expiry. Taking the ordinary parked claim again would reject forever;
  # verify/refresh the held token once, then carry it through middleware/fence B.
  defp claim_and_resume(run, {:reuse, token}, tenant, actor) when is_binary(token) do
    if run.claim_token == token do
      case WorkflowLease.renew(run.id, token) do
        {:ok, 1} -> do_resume(reload(run, tenant, actor), token, tenant, actor)
        {:ok, 0} -> {:error, :resume_claim_lost, reload(run, tenant, actor)}
        {:error, reason} -> {:error, {:resume_claim_failed, reason}, reload(run, tenant, actor)}
      end
    else
      {:error, :resume_claim_lost, reload(run, tenant, actor)}
    end
  end

  defp claim_and_resume(run, _invalid_mode, tenant, actor),
    do: {:error, :invalid_resume_claim_mode, reload(run, tenant, actor)}

  defp do_resume(run, claim_token, tenant, actor) do
    with {:ok, blob} <- decrypt_checkpoint(run, tenant, actor),
         {:ok, module, reactor, inputs} <- decode_checkpoint(blob),
         {:ok, decision} <- approved_decision(run, tenant, actor) do
      run_reactor(run, module, reactor, inputs, decision, claim_token, tenant, actor)
    else
      {:error, reason} -> fail_with_audit(run, reason, claim_token, tenant, actor)
    end
  end

  # The one place the checkpoint is decrypted: load the AshCloak
  # `resume_checkpoint` calculation, which returns the original envelope blob
  # (vault-decrypted). A vault failure (key rotation, corrupt ciphertext)
  # raises inside the calculation — mapped to the same fail-with-audit path as
  # a corrupt envelope, never resumed.
  defp decrypt_checkpoint(run, tenant, actor) do
    case Ash.load(run, :resume_checkpoint, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{resume_checkpoint: blob}} when is_binary(blob) -> {:ok, blob}
      {:ok, _} -> {:error, :no_checkpoint}
      {:error, reason} -> {:error, {:checkpoint_decrypt_failed, reason}}
    end
  rescue
    # reach:disable-next-line bare_rescue
    error ->
      # Cloak raises (Cloak.MissingCipher / decrypt failures) are an open set;
      # any of them means the blob can never be resumed -> fail-with-audit.
      {:error, {:checkpoint_decrypt_failed, Exception.message(error)}}
  end

  # The killable-execution seam (mirrors ReactorRunner.execute): `tenant_id:`
  # is RunExecution-local registry metadata and never reaches Reactor.run.
  defp run_reactor(run, module, reactor, inputs, decision, claim_token, tenant, actor) do
    context = %{
      tenant: tenant,
      actor: actor,
      workflow_run: run,
      reactor: inspect(module),
      approval: decision,
      claim_token: claim_token
    }

    finalize_opts = [
      tenant: tenant,
      actor: actor,
      inputs: inputs,
      reactor_module: module,
      claim_token: claim_token
    ]

    # Re-establish `Lease.Middleware` on the DECODED reactor before running, so a
    # checkpoint written before WS1 still claims its lease on resume (don't rely
    # on the deserialized reactor carrying it). A normalize failure routes
    # through the same fail-with-audit path as a decode/decrypt failure — never a
    # raise.
    case ReactorRunner.normalize_middleware(reactor) do
      {:ok, normalized} ->
        run_normalized(run, normalized, inputs, context, finalize_opts, tenant, actor)

      {:error, reason} ->
        fail_with_audit(run, {:lease_middleware, reason}, claim_token, tenant, actor)
    end
  end

  defp run_normalized(run, reactor, inputs, context, finalize_opts, tenant, actor) do
    case RunExecution.run_killable(reactor, inputs, context,
           run_id: run.id,
           tenant_id: run.tenant_id,
           async?: false,
           timeout: :infinity,
           max_iterations: :infinity
         ) do
      {:reactor, result} ->
        ReactorRunner.finalize(result, run, finalize_opts)

      {:exit, reason} ->
        ReactorRunner.finalize_exit(run, reason, finalize_opts)

      # The loser of an approve-vs-boot-recovery race on the same run id must
      # leave the winner's :running run untouched — report, never fail it.
      {:duplicate, pid} ->
        {:error, {:already_running, pid}, reload(run, tenant, actor)}
    end
  end

  # Two-stage `[:safe]` decode. The outer tuple needs no custom atoms; the
  # inner reactor's atoms need the gate-reactor module AND the execution
  # machinery's modules loaded (see `safe_decode_inner/1`'s sweep-retry).
  # `decrypt_checkpoint/3` guarantees a binary by construction.
  defp decode_checkpoint(blob) when is_binary(blob) do
    with {:ok, {version, module_string, inner}} <- safe_decode_outer(blob),
         :ok <- check_version(version),
         :ok <- check_allowed_module(module_string),
         {:ok, module} <- resolve_module(module_string),
         {:ok, {reactor, inputs}} <- safe_decode_inner(inner) do
      {:ok, module, reactor, inputs}
    end
  end

  # `:erlang.binary_to_term/2` with `[:safe]` raises `ArgumentError` on a
  # malformed/truncated blob or an atom that does not currently exist — a
  # narrow, typed rescue (not a bare rescue).
  defp safe_decode_outer(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      {version, module_string, inner}
      when is_integer(version) and is_binary(module_string) and is_binary(inner) ->
        {:ok, {version, module_string, inner}}

      _ ->
        {:error, :malformed_checkpoint_envelope}
    end
  rescue
    ArgumentError -> {:error, :corrupt_checkpoint_outer}
  end

  defp safe_decode_inner(inner) do
    match_inner(:erlang.binary_to_term(inner, [:safe]))
  rescue
    # EITHER corruption or lazy loading: `[:safe]` refuses atoms this VM has
    # not interned, and a fresh BEAM (boot recovery, a cluster peer
    # reclaiming) interns a dependency's atoms only when its modules load —
    # `resolve_module/1`'s `Code.ensure_loaded?` covers the gate-reactor
    # module, NOT the halted struct's transitive machinery (proven cross-BEAM
    # by `Ash.Reactor.Notifications`' agent key, which rides every halted
    # context). Load the compiled closure and retry once; a second refusal is
    # genuine corruption.
    ArgumentError -> decode_inner_after_module_sweep(inner)
  end

  defp decode_inner_after_module_sweep(inner) do
    Logger.debug(
      "[GateResume] inner checkpoint decode refused an atom — " <>
        "loading the compiled module closure and retrying"
    )

    load_compiled_modules()
    match_inner(:erlang.binary_to_term(inner, [:safe]))
  rescue
    ArgumentError -> {:error, :corrupt_checkpoint_inner}
  end

  defp match_inner({%Reactor{} = reactor, inputs}) when is_map(inputs),
    do: {:ok, {reactor, inputs}}

  defp match_inner(_decoded), do: {:error, :malformed_checkpoint_inner}

  # Best-effort embedded-mode sweep: intern every compile-time atom by
  # loading each loaded application's modules (parallel, idempotent, cheap
  # when everything is already loaded). Per-module load failures are ignored
  # — the retry decode is the arbiter of whether the needed atoms arrived.
  defp load_compiled_modules do
    modules =
      for {app, _desc, _vsn} <- Application.loaded_applications(),
          module <- Application.spec(app, :modules) || [],
          do: module

    _ = :code.ensure_modules_loaded(modules)
    :ok
  end

  defp check_version(@checkpoint_version), do: :ok
  defp check_version(version), do: {:error, {:unknown_checkpoint_version, version}}

  defp check_allowed_module(module_string) do
    if String.starts_with?(module_string, @allowed_module_prefix) do
      :ok
    else
      {:error, {:disallowed_checkpoint_module, module_string}}
    end
  end

  # `String.to_existing_atom/1` (not `to_atom/1`): to have *written* this
  # checkpoint the gate-reactor module must have been loaded, so its atom
  # exists; if it does not, the module is not available in this VM and the run
  # cannot be resumed anyway → fail-with-audit. The prefix check already fenced
  # the string to our own namespace, so this never resolves a foreign module.
  defp resolve_module(module_string) do
    module = String.to_existing_atom(module_string)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, {:checkpoint_module_not_loaded, module_string}}
    end
  rescue
    ArgumentError -> {:error, {:checkpoint_module_unknown, module_string}}
  end

  defp approved_decision(run, tenant, actor) do
    case AgentCase.approved_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, %AgentCase{decision: decision}} -> {:ok, decision}
      {:ok, nil} -> {:error, :approved_case_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  # A run that reached `:running` + checkpoint but cannot be resumed (corrupt
  # blob, missing approved case) is failed with an audit trail — it can never
  # make progress, and the terminal clears the checkpoint (Decision 7).
  defp fail_with_audit(run, reason, claim_token, tenant, actor) do
    formatted = "gate resume failed: #{inspect(reason)}"
    Logger.warning("[GateResume] #{formatted} (run #{run.id})")

    case WorkflowLog.append(run, :run_failed, %{error: formatted},
           tenant: tenant,
           actor: actor,
           claim_fence_token: claim_token
         ) do
      {:ok, _event} ->
        :ok

      {:error, append_error} ->
        Logger.warning("[GateResume] run_failed audit append failed: #{inspect(append_error)}")
    end

    {:error, reason, reload(run, tenant, actor)}
  end

  defp reload(run, tenant, actor) do
    case WorkflowRun.by_id(run.id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _ -> run
    end
  end
end
