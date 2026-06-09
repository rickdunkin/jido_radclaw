defmodule JidoClaw.Orchestration.Gates do
  @moduledoc """
  Behaviour for human approval gate notification hooks.

  Gate modules are defined with `use JidoClaw.Orchestration.HumanGate`, which
  brings in the gate-definition Spark DSL (`gate do ... end` — kind, title,
  typed fields read back via `JidoClaw.Orchestration.Gate.Info`) and injects
  this behaviour with overridable no-op defaults. The behaviour itself is only
  the two hooks: everything the old `kind/0` / `field_metadata/0` /
  `presentation/0` callbacks carried is now declarative DSL data.

  ## Hooks are notifications, not durable steps (Decision 8)

  `after_approved/1` / `after_rejected/1` are **best-effort** side-effects that
  fire **once, on the operator decision path** (post-commit, isolated task,
  logged on failure). They are **NOT** crash-exactly-once: on the boot-recovery
  resume path they are **skipped** entirely (the decision already committed;
  re-running the reactor performs the durable work). Durable, must-happen work
  belongs in the reactor's downstream steps, which resume durably — never in a
  hook.
  """

  alias JidoClaw.Orchestration.GateContext

  @doc "Best-effort notification fired once after an operator approves."
  @callback after_approved(GateContext.t()) :: :ok | {:error, term()}

  @doc "Best-effort notification fired once after an operator rejects."
  @callback after_rejected(GateContext.t()) :: :ok | {:error, term()}
end
