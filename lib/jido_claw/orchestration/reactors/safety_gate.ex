defmodule JidoClaw.Orchestration.Reactors.SafetyGate do
  @moduledoc """
  The `safety` gate as a runnable single-stage composer wave (AR-8c) — the
  always-on human checkpoint on the **system** path, structurally identical to
  `Reactors.PlanGate` but gating a machine change instead of a plan.

  Like every composer gate it runs as **this named `Ash.Reactor` module** (not a
  dynamic `%Reactor{}`): `GateResume` only re-materializes modules under the
  `Elixir.JidoClaw.Orchestration.Reactors.` allowlist, so the module MUST live
  under that prefix to checkpoint + resume. It uses named `Reactor.Step` modules
  only (`GateStep` + the **shared** `PlanGate.EmitApprovedPlan`) for
  serializability, and runs `async?: false`.

  ## Reuses the generic emit step

  The post-gate emit step is **`PlanGate.EmitApprovedPlan`** — it is generic over
  its `artifact_name`/`signal_name` inputs (it resolves `plan_ref`, re-stores the
  value under `artifact_name`, and emits `signal_name`), so there is no
  safety-specific copy. Here the inputs carry `approved-change` / `safety-approved`
  (vs the plan-gate's `approved-plan` / `plan-approved`).

  ## Shape

      input(:plan_ref)       # the approved-change input's opaque store ref (the `plan`)
      input(:wave_index)     # the composer wave index this gate occupies
      input(:stage_name)     # the gate stage's catalog name ("safety-gate")
      input(:artifact_name)  # the gate's output artifact name ("approved-change")
      input(:signal_name)    # the approval signal ("safety-approved")

      step :approval_gate, {GateStep, gate_module: Gates.SafetyGate, ...}  # halts the run
      step :emit, EmitApprovedPlan do wait_for(:approval_gate) end          # promotes on approve
      return(:emit)

  The gate's **kind** is `:irreversible_write`, sourced from `Gates.SafetyGate`'s
  DSL `kind(:irreversible_write)` (decision 3: reuse the existing kind — zero
  migration, no new approval-UI surface). `details` is a **short summary only** —
  it lands verbatim in the `AgentCase` jsonb the operator inbox surfaces, so it
  never carries the plan/change text (the live risk signals are already visible
  via `inspect_workflow` / the dashboard).
  """

  # The `step :emit` wiring (the 5 argument/wait_for/max_retries lines) is
  # IDENTICAL to `PlanGate`'s by design — both gates dispatch the SAME generic
  # `EmitApprovedPlan` step, so the wiring must match. The only DRY alternative is
  # a shared gate-reactor macro, which the project's style avoids ("only use
  # macros if explicitly requested"). This is genuinely-intentional reactor-DSL
  # duplication, not copy-pasted logic, so ExDNA is disabled for this small,
  # single-purpose module (mirrors `lib/jido_claw/inspection.ex`).
  # ex_dna:disable-for-this-file

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
        gate_module: JidoClaw.Gates.SafetyGate,
        step_name: "safety-gate",
        details: %{summary: "Approve this system change before it is applied to the machine."}} do
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
