defmodule JidoClaw.Orchestration.GateStep do
  @moduledoc """
  A `Reactor.Step` that opens a human approval gate and halts the reactor.

  Declared in a gate-bearing reactor as `{GateStep, gate_module: MyGate,
  step_name: "...", details: %{...}}`. On `run/3` it calls
  `WorkflowLog.gate_open/3` (one transaction: create the `AgentCase` + append
  `approval_requested`, flipping the run to `:awaiting_approval`) and returns
  `{:halt, agent_case_id}`. The runner's `finalize` then persists the durable
  resume checkpoint and broadcasts the gate request.

  Position the gate **before** the irreversible downstream write: approve runs
  the downstream steps, reject cancels the run before they execute (Decision 9).
  Order downstream steps after the gate with `wait_for`; a step that needs the
  operator decision reads `context[:approval]` in its own `run/3` (the gate's
  halt value is the case id, meaningless on resume). Downstream steps must be
  idempotent (a crash mid-resume re-runs them — Decision 7 caveat).

  ## Options

    * `:gate_module` (required) — a `JidoClaw.Orchestration.Gates` impl.
    * `:step_name` (optional) — operator-facing step label (default `"gate"`).
    * `:kind` (optional) — defaults to `gate_module.kind()`.
    * `:details` (optional) — a **redactor-safe** operator-visible map
      (default `%{}`). Do not put raw Ash records here — `details` lands in the
      `AgentCase` row's jsonb column and the inbox surfaces it verbatim.
  """

  use Reactor.Step

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:halt, Ecto.UUID.t()} | {:error, term()}
  def run(_arguments, %{workflow_run: %WorkflowRun{} = run} = context, options) do
    gate_module = Keyword.fetch!(options, :gate_module)
    step_name = Keyword.get(options, :step_name, "gate")
    kind = Keyword.get(options, :kind, gate_module.kind())
    details = Keyword.get(options, :details, %{})

    attrs = %{
      workflow_run_id: run.id,
      step_name: step_name,
      kind: kind,
      gate_module: gate_module,
      details: details
    }

    case WorkflowLog.gate_open(run, attrs,
           tenant: run.tenant_id,
           actor: context[:actor] || Actor.system(run.tenant_id)
         ) do
      {:ok, agent_case} -> {:halt, agent_case.id}
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_arguments, _context, _options) do
    {:error, {:invalid_reactor_context, "missing %WorkflowRun{} under :workflow_run"}}
  end
end
