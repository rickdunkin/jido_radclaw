defmodule JidoClaw.Gates.SafetyGate do
  @moduledoc """
  The `safety` gate (AR-8c) — the always-on human approval checkpoint before a
  machine/environment change is applied on the **system** path.

  Wired by `JidoClaw.Orchestration.Reactors.SafetyGate`: the composer dispatches
  a `{:gate, "safety"}` stage as that single-stage gate reactor, which `GateStep`s
  on this module. Approve resumes and emits `safety-approved` (releasing the held
  `system-executor`); reject cancels the run (the user declined the change — the
  system path has no `plan-rejected` subscriber, so a safety reject does NOT
  re-plan, see `RouteComposer.terminalize_gate_disposition/3`).

  Its **kind** reuses `:irreversible_write` (decision 3: every machine change is
  threat-model-weighted as an irreversible write, so it shares that kind's
  approval surface — zero migration, no new inbox label). A dedicated `:safety`
  kind remains a one-line option in `Gate.Kinds` if distinct labeling is later
  wanted. The hooks keep the `HumanGate` no-op defaults — the composer's durable
  park/wake is the must-happen work, never a best-effort hook.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:irreversible_write)
    title("Approve system change")

    description(
      "The agent wants to apply an approved change to the machine/environment. " <>
        "Review before it runs."
    )

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
