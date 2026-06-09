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

  ## Kind + presentation come from the gate DSL

  The case's `kind` is derived **exclusively** from the gate module's
  `gate do kind(...) end` declaration (`Gate.Info.gate_kind!/1`) — there is
  deliberately no `:kind` option, which could silently diverge from the DSL.
  The DSL's `title`/`description`/`fields` seed the operator-visible
  `details` (under `"gate_title"`/`"gate_description"`/`"fields"`), merged
  over by any caller-supplied `:details`.

  ## Options

    * `:gate_module` (required) — a `use JidoClaw.Orchestration.HumanGate`
      module (declares the gate DSL + the `Gates` notification hooks).
    * `:step_name` (optional) — operator-facing step label (default `"gate"`).
    * `:details` (optional) — a **redactor-safe** operator-visible map
      (default `%{}`). Do not put raw Ash records here — `details` lands in the
      `AgentCase` row's jsonb column and the inbox surfaces it verbatim.
  """

  use Reactor.Step

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.Gate
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:halt, Ecto.UUID.t()} | {:error, term()}
  def run(_arguments, %{workflow_run: %WorkflowRun{} = run} = context, options) do
    gate_module = Keyword.fetch!(options, :gate_module)
    step_name = Keyword.get(options, :step_name, "gate")
    details = Keyword.get(options, :details, %{})

    attrs = %{
      workflow_run_id: run.id,
      step_name: step_name,
      kind: Gate.Info.gate_kind!(gate_module),
      gate_module: gate_module,
      details: Map.merge(dsl_details(gate_module), details)
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

  # The gate DSL's presentation, normalized to JSON-native shapes (string
  # keys/values) so the in-memory map equals its jsonb round-trip — the
  # approval surfaces read one shape.
  defp dsl_details(gate_module) do
    %{
      "gate_title" => Gate.Info.gate_title!(gate_module),
      "fields" => Enum.map(Gate.Info.fields(gate_module), &field_to_map/1)
    }
    |> put_description(gate_module)
  end

  defp put_description(details, gate_module) do
    case Gate.Info.gate_description(gate_module) do
      {:ok, description} when is_binary(description) ->
        Map.put(details, "gate_description", description)

      _ ->
        details
    end
  end

  defp field_to_map(%Gate.Field{} = field) do
    %{
      "name" => Atom.to_string(field.name),
      "type" => Atom.to_string(field.type),
      "label" => field.label || humanize(field.name),
      "options" => field.options,
      "required" => field.required?
    }
  end

  defp humanize(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
