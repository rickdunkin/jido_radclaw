defmodule JidoClaw.Gates.IrreversibleWriteGate do
  @moduledoc """
  The `:irreversible_write` gate — a human approval checkpoint placed
  **before** a write the agent cannot undo (file/DB/workspace creation,
  destructive mutation). Approve runs the downstream write; reject cancels
  the run before it executes (Decision 9).

  The one gate kind with a live producer today: a gate-bearing reactor wires
  `JidoClaw.Orchestration.GateStep` with this module (or a specialization)
  ahead of its write step.
  """

  use JidoClaw.Orchestration.HumanGate

  gate do
    kind(:irreversible_write)
    title("Approve irreversible write")
    description("The agent wants to perform a write that cannot be undone.")

    fields do
      field(:comment, type: :textarea, label: "Comment")
    end
  end
end
