defmodule JidoClaw.Workflows.StepResult do
  @moduledoc """
  Internal step result struct used during workflow execution.

  Carries the step name, template, result text, optional typed output
  (populated when the spawning worker carried a structured `:output`
  schema and validation succeeded), and any dynamic artifacts discovered
  at runtime. Converted to `{label, text}` tuples at the workflow output
  boundary by `JidoClaw.Skills.Result.build/3`.

  `request_id` (OB1-3) is the ENGINE-minted correlation id
  (`JidoClaw.register_child_correlation/1`) stamped by
  `JidoClaw.Skills.Steps.AgentRunner.run_recorded/6` on both executor arms —
  never agent-relayable data. It lets the evidence floor read the step's
  durable `:tool_call`/`:tool_result` rows back via
  `Conversations.Message.by_request/2+`. Nil outside the agent-runner path.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          template: String.t() | nil,
          result: String.t(),
          typed_output: map() | nil,
          request_id: String.t() | nil,
          artifacts: map()
        }

  defstruct [:name, :template, :result, :typed_output, :request_id, artifacts: %{}]
end
