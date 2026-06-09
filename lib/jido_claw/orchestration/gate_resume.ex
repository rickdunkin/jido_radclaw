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
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  # Must match `ReactorRunner`'s encoder. Bump together on any envelope change.
  @checkpoint_version 1

  # Atom-creation fence: a checkpoint module string must name a reactor in our
  # own gate-reactor namespace. This is the boundary where DB content becomes
  # an atom, so it is constrained to a known prefix before `String.to_atom/1`.
  @allowed_module_prefix "Elixir.JidoClaw.Orchestration.Reactors."

  @doc """
  Reload `run`, decode its checkpoint, and resume the persisted reactor through
  the shared `ReactorRunner.finalize`. Returns the same envelope as
  `ReactorRunner.run/3` (`{:ok, value, run}` / `{:ok, {:paused, id}, run}` /
  `{:error, reason, run}`). Resumes only a `:running` run that still carries a
  checkpoint; any other state is a clean `{:error, :not_resumable, run}`
  (no mutation).

  Opts: `:tenant`, `:actor`, and `:recovered` (informational; the hook-skip on
  the recovery path is enforced by the caller, not here).
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
        do_resume(reloaded, tenant, actor)
    end
  end

  # -- Internal --

  defp do_resume(run, tenant, actor) do
    with {:ok, blob} <- decrypt_checkpoint(run, tenant, actor),
         {:ok, module, reactor, inputs} <- decode_checkpoint(blob),
         {:ok, decision} <- approved_decision(run, tenant, actor) do
      run_reactor(run, module, reactor, inputs, decision, tenant, actor)
    else
      {:error, reason} -> fail_with_audit(run, reason, tenant, actor)
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

  defp run_reactor(run, module, reactor, inputs, decision, tenant, actor) do
    context = %{
      tenant: tenant,
      actor: actor,
      workflow_run: run,
      reactor: inspect(module),
      approval: decision
    }

    reactor
    |> Reactor.run(inputs, context,
      run_id: run.id,
      async?: false,
      timeout: :infinity,
      max_iterations: :infinity
    )
    |> ReactorRunner.finalize(run,
      tenant: tenant,
      actor: actor,
      inputs: inputs,
      reactor_module: module
    )
  end

  # Two-stage `[:safe]` decode. The outer tuple needs no custom atoms; the
  # inner reactor's atoms exist only after its module is loaded.
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
    case :erlang.binary_to_term(inner, [:safe]) do
      {%Reactor{} = reactor, inputs} when is_map(inputs) -> {:ok, {reactor, inputs}}
      _ -> {:error, :malformed_checkpoint_inner}
    end
  rescue
    ArgumentError -> {:error, :corrupt_checkpoint_inner}
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
  defp fail_with_audit(run, reason, tenant, actor) do
    formatted = "gate resume failed: #{inspect(reason)}"
    Logger.warning("[GateResume] #{formatted} (run #{run.id})")

    case WorkflowLog.append(run, :run_failed, %{error: formatted}, tenant: tenant, actor: actor) do
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
