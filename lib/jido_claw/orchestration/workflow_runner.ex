defmodule JidoClaw.Orchestration.WorkflowRunner do
  @moduledoc """
  Thin cron adapter for `target: :workflow` jobs.

  Driven by `Cron.Dispatcher`. On a tick it resolves the named skill, compiles
  it to a `%Reactor{}` via `JidoClaw.Skills.Compiler`, and runs it through
  `JidoClaw.Orchestration.ReactorRunner` — the same durable envelope that drives
  developer-authored reactors. The `WorkflowRun` row, event timeline, status
  projection, and `RunPubSub` broadcasts are all owned by the envelope
  (`ReactorMiddleware`); this module just maps the envelope result to the
  dispatcher's `:ok | {:error, term()}` contract.

  ## Shared per-run scope

  Builds a deterministic `workspace_id = "cron:<job_id>:<n>"` and passes it via
  the runner's `:context`, so every step in the cron workflow shares
  shell/VFS state (without it each step would fall back to a unique per-step
  key). `project_dir` is the app's boot-time `File.cwd!()` (cron is a
  single-project concern today). Cron workflows produce no
  `Conversations.Session`/correlation rows — observability lives in the
  `WorkflowRun` + event log + cron telemetry.

  ## Tick idempotency (T2-3)

  A scheduled tick carries `fire: {:scheduled, window}` (the armed timer
  window, stamped by `Cron.Worker.execute_job/2` on its local dispatch copy),
  from which this adapter derives `idempotency_key:
  "cron:<job_id>:<iso8601 window>"` — so a double-delivered tick resolves to
  the existing `WorkflowRun` instead of launching a second reactor (the
  dedupe envelope maps to `:ok`, not a failure). The key is checked against
  existing runs **before** skill resolution/compile, so the duplicate stays
  `:ok` even when the skill has since been removed or broken — a dedupe hit
  must never feed the cron worker's failure counter. That early read is an
  optimization + failure isolation only; a read error falls through to the
  normal launch, where `ReactorRunner`'s read-first + unique-violation
  backstop owns dedupe correctness. Manual triggers (`fire: :manual`) and
  non-worker callers (no `:fire`) derive no key and always run.

  ## Never raises

  `run/1` is `:ok | {:error, term()}`. `ReactorRunner.run/3` is itself a
  never-raises seam; the body-level rescue covers a `Skills.get`/`Compiler`
  raise so a misconfigured job can't crash the dispatcher.
  """

  # `run/1` is contractually `:ok | {:error, term()}`; the body rescue
  # normalizes any pre-run raise (skill lookup / compile) into the error tuple.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler

  @spec run(map()) :: :ok | {:error, term()}
  def run(%{workflow_name: name} = state) do
    tenant_id = state.tenant_id
    key = idempotency_key(state)

    case existing_run(key, tenant_id) do
      {:hit, run} ->
        Logger.debug("[WorkflowRunner] tick dedupe hit for #{key}: run #{run.id} already exists")

        :ok

      :miss ->
        with {:ok, skill} <- Skills.get(name, File.cwd!()),
             {:ok, reactor} <- Compiler.compile(skill) do
          reactor
          |> run_reactor(skill, state, tenant_id, key)
          |> finalize()
        else
          # Unknown skill / compile failure — no run created.
          {:error, reason} -> {:error, format_reason(reason)}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Defensive: a state map with no :workflow_name can never reach here from the
  # dispatcher (Job invariant + reload guard + ScheduleTask validation all
  # require it), but honor the never-raises contract anyway.
  def run(_state), do: {:error, :missing_workflow_name}

  # -- Internal --

  defp run_reactor(reactor, skill, state, tenant_id, idempotency_key) do
    workspace_id = "cron:#{state.id}:#{System.unique_integer([:positive])}"

    ReactorRunner.run(reactor, %{extra_context: extra_context(state)},
      tenant: tenant_id,
      actor: Actor.system(tenant_id),
      name: skill.name,
      async?: true,
      definition_hash: DefinitionFingerprint.for_skill(skill),
      idempotency_key: idempotency_key,
      deadline: skill.deadline,
      context: %{workspace_id: workspace_id, project_dir: File.cwd!()}
    )
  end

  # Tick-dedupe early read: a duplicate scheduled tick whose key already owns
  # a run short-circuits to :ok BEFORE skill resolution/compile — a skill
  # removed or broken since the first delivery must not turn the dedupe into
  # {:error, _} and feed the cron failure counter. Nil keys and read errors
  # fall to :miss and proceed exactly as before; ReactorRunner's read-first +
  # unique-violation backstop owns the dedupe race.
  defp existing_run(nil, _tenant_id), do: :miss

  defp existing_run(key, tenant_id) do
    case WorkflowRun.by_idempotency_key(key,
           tenant: tenant_id,
           actor: Actor.system(tenant_id)
         ) do
      {:ok, %WorkflowRun{} = run} -> {:hit, run}
      _ -> :miss
    end
  end

  # Launch dedupe key (T2-3), derived ONLY from explicit scheduled provenance:
  # `Cron.Worker.execute_job/2` stamps `fire: {:scheduled, window}` (the armed
  # timer window) on a tick, so a double-delivered tick for one window
  # resolves to one run.
  # `:manual` (operator trigger), a missing `:fire` (non-worker callers), or a
  # non-DateTime window all mean NO key — those launches always run.
  defp idempotency_key(state) do
    case Map.get(state, :fire) do
      {:scheduled, %DateTime{} = window} -> "cron:#{state.id}:#{DateTime.to_iso8601(window)}"
      _ -> nil
    end
  end

  defp finalize({:ok, _value, _run}), do: :ok
  defp finalize({:error, reason, _run}), do: {:error, format_reason(reason)}

  # The workflow input's "context" key is the extra instructions string appended
  # to every step's task; default to "" so ContextBuilder.build_task drops it.
  defp extra_context(state) do
    Map.get(Map.get(state, :workflow_input) || %{}, "context", "")
  end

  defp format_reason(%{__exception__: true} = e), do: Exception.message(e)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
