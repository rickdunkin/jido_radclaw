defmodule JidoClaw.Orchestration.Reactors.PlanGate.EmitApprovedPlan do
  @moduledoc """
  The post-gate step of `JidoClaw.Orchestration.Reactors.PlanGate` (AR-2 §9; §14
  Phase 4a): on approve-then-resume it promotes the approved plan into the
  composer's wave-emission protocol so the loop folds it exactly like a worker
  wave's `JidoClaw.RouteComposer.Steps.WaveCollect` return.

  **Generic + shared** (AR-8c): it is parameterized entirely by its
  `artifact_name`/`signal_name` inputs — nothing is plan-specific — so
  `JidoClaw.Orchestration.Reactors.SafetyGate` reuses this same step to promote
  its `approved-change` / `safety-approved`. (One step, no per-gate copy.)

  A **named** `Reactor.Step` module (not an inline fun) so the halted reactor
  stays `:erlang.term_to_binary`-serializable for the durable resume checkpoint
  (Decision 1). It runs only **after** the gate (`wait_for(:approval_gate)`), so
  by the time it executes the run has resumed and `context[:approval]` carries
  the operator decision (`:approve`); a rejected gate cancels the run before this
  step ever runs (§9 step 5/6), so it never emits on reject.

  ## What it emits

  It resolves the **raw** plan value from the opaque `plan_ref` via
  `ComposerArtifact.resolve_value/2` (the same decrypt resolver `ArtifactContext`
  uses — **not** `ArtifactContext.build/4`, whose 4 KB/16 KB caps + markdown
  rendering would persist a lossy copy), re-stores it as an encrypted `:pending`
  `approved-plan` `ComposerArtifact` (the composer's `Commit.commit_wave/4`
  promotes it `:active` on fold — the same division of labor as a worker wave),
  and returns the **identical** json-safe envelope `WaveCollect` returns so
  `decode_emissions/1` needs zero changes.

  ## Idempotent across a crash-mid-resume (Decision 7)

  A resume that crashes after the `store_pending` but before the composer folds
  would, on the next resume, insert a **second** `:pending` row — a per-resume
  leak. So before inserting, it reuses-by-lineage: it scans
  `ComposerArtifact.pending_for_wave/3` for an existing `{child_run_id, name,
  producer}` row at this wave and reuses its ref, inserting only on a miss.

  ## P1 (plan value never at rest outside the encrypted store)

  The step receives the plan's opaque **ref**, never its value, so the value is
  resolved fresh from the encrypted store on each run and never enters the
  reactor's serialized checkpoint (only the ref does).
  """

  use Reactor.Step

  alias JidoClaw.Orchestration.ComposerArtifact

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(arguments, context, _options) do
    case Map.get(context, :approval) do
      :approve -> emit(arguments, context)
      other -> {:error, {:unexpected_gate_decision, other}}
    end
  end

  defp emit(arguments, context) do
    %{
      plan_ref: plan_ref,
      wave_index: wave_index,
      stage_name: stage_name,
      artifact_name: artifact_name,
      signal_name: signal_name
    } = arguments

    child = Map.fetch!(context, :workflow_run)
    tenant = Map.fetch!(context, :tenant)
    actor = Map.fetch!(context, :actor)

    with {:ok, plan_value} <-
           ComposerArtifact.resolve_value(plan_ref, tenant: tenant, actor: actor),
         {:ok, ref} <-
           ensure_pending(child, artifact_name, stage_name, wave_index, plan_value, tenant, actor) do
      {:ok, envelope(wave_index, stage_name, signal_name, artifact_name, ref)}
    end
  end

  # Reuse-by-lineage (idempotency, Decision 7): a `{child_run_id, name, producer}`
  # row already at this wave (a prior resume that crashed before the fold) is
  # reused; only a miss inserts a fresh `:pending` row.
  defp ensure_pending(child, name, producer, wave_index, value, tenant, actor) do
    case existing_pending_ref(child, name, producer, wave_index, tenant, actor) do
      {:ok, ref} -> {:ok, ref}
      :none -> store_pending(child, name, producer, wave_index, value, tenant, actor)
      {:error, _reason} = error -> error
    end
  end

  defp existing_pending_ref(child, name, producer, wave_index, tenant, actor) do
    case ComposerArtifact.pending_for_wave(child.parent_run_id, wave_index,
           tenant: tenant,
           actor: actor
         ) do
      {:ok, rows} ->
        case Enum.find(rows, &lineage_match?(&1, child.id, name, producer)) do
          %ComposerArtifact{ref: ref} -> {:ok, ref}
          nil -> :none
        end

      {:error, reason} ->
        {:error, {:pending_lookup_failed, reason}}
    end
  end

  defp lineage_match?(%ComposerArtifact{} = row, child_run_id, name, producer) do
    row.child_run_id == child_run_id and row.name == name and row.producer == producer
  end

  defp store_pending(child, name, producer, wave_index, value, tenant, actor) do
    ComposerArtifact.store_wave_artifact(name, producer, value, child, wave_index,
      tenant: tenant,
      actor: actor
    )
  end

  # The SAME json-safe shape `WaveCollect` returns (string keys throughout), so
  # the composer's `decode_emissions/1` + `StageEmission.from_map/1` fold it with
  # zero changes — the gate wave is, on the fold path, indistinguishable from a
  # worker wave that published `signal_name` and produced `artifact_name`.
  defp envelope(wave_index, stage_name, signal_name, artifact_name, ref) do
    %{
      "wave_index" => wave_index,
      "emissions" => [
        %{
          "stage" => stage_name,
          "signals" => [signal_name],
          "artifacts" => %{artifact_name => ref}
        }
      ]
    }
  end
end

defmodule JidoClaw.Orchestration.Reactors.PlanGate do
  @moduledoc """
  The `plan` gate as a runnable single-stage composer wave (AR-2 §9; §14 Phase 4a).

  A composer plan gate runs as **this named `Ash.Reactor` module**, not a dynamic
  `%Reactor{}` struct: `ReactorRunner`'s checkpoint encoder needs a non-nil
  `reactor_module` (`reactor_runner.ex` `Keyword.fetch!(opts, :reactor_module)`)
  and `GateResume` only re-materializes modules under the
  `Elixir.JidoClaw.Orchestration.Reactors.` allowlist — so a gated struct could
  not checkpoint nor resume. The reactor uses **named `Reactor.Step` modules
  only** (the `GateStep` and `EmitApprovedPlan`) for the same serializability
  reason (Decision 1), and runs `async?: false` (the runner pins it) so the
  halted struct carries no in-flight step processes.

  ## Shape

      input(:plan_ref)       # the `plan` artifact's opaque store ref (NOT the value, P1)
      input(:wave_index)     # the composer wave index this gate occupies
      input(:stage_name)     # the gate stage's catalog name (the emission producer)
      input(:artifact_name)  # the gate's output artifact name ("approved-plan")
      input(:signal_name)    # the approval signal ("plan-approved")

      step :approval_gate, {GateStep, gate_module: Gates.PlanGate, ...}  # halts the run
      step :emit, EmitApprovedPlan do wait_for(:approval_gate) end       # promotes on approve
      return(:emit)

  `tenant`/`actor`/`workflow_run` arrive via reactor **context** (`ReactorRunner`
  seeds them on the initial run; `GateResume` re-seeds them + `approval: :approve`
  on resume). The gate's **kind** is `:plan`, sourced from `Gates.PlanGate`'s DSL
  `kind(:plan)` (never a `GateStep` option). `details` is a **short summary only**
  — never the plan text — because it lands verbatim in the `AgentCase` jsonb the
  operator inbox surfaces (P1; the full encrypted plan render is the Phase-5
  observe surface).

  No pre-gate `:prepare` step (cf. the keystone `GatedTestReactor`): the plan
  arrives as an input, so no pre-gate data step is load-bearing, and `GateStep`
  itself writes nothing a reject would orphan.
  """

  use Ash.Reactor

  alias JidoClaw.Orchestration.Reactors.PlanGate.EmitApprovedPlan

  middlewares do
    middleware(JidoClaw.Orchestration.ReactorMiddleware)
  end

  input(:plan_ref)
  input(:wave_index)
  input(:stage_name)
  input(:artifact_name)
  input(:signal_name)

  step :approval_gate,
       {JidoClaw.Orchestration.GateStep,
        gate_module: JidoClaw.Gates.PlanGate,
        step_name: "plan-gate",
        details: %{summary: "Approve the implementation plan before execution"}} do
    max_retries(0)
  end

  step :emit, EmitApprovedPlan do
    argument(:plan_ref, input(:plan_ref))
    argument(:wave_index, input(:wave_index))
    argument(:stage_name, input(:stage_name))
    argument(:artifact_name, input(:artifact_name))
    argument(:signal_name, input(:signal_name))
    wait_for(:approval_gate)
    max_retries(0)
  end

  return(:emit)
end
