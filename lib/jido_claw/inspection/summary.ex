defmodule JidoClaw.Inspection.Summary do
  @moduledoc """
  Agent-axis projection returned by `JidoClaw.Inspection.inspect_agent/2`,
  `inspect_request/2`, and `inspect_workflow/1`.

  Matches the spirit of Jidoka's `Debug.summary` shape — a single struct
  unifying agent definition (`system_prompt`, `skills`, `tool_names`,
  `mcp_tools`, `context_preview`) with current running state (`memory`,
  `compaction`, `subagents`, `workflows`, `handoffs`, `usage`,
  `duration_ms`, `interrupt`, `error`, `message_count`).

  `:subagents` and `:workflows` are populated from process-global sources
  (`JidoClaw.AgentTracker.get_state/0` and `WorkflowRun.list_active/0`)
  and are **not** tenant-scoped today. They are documented as
  "global best-effort" — local Elixir consumers see them, but the MCP
  `inspect_agent` tool drops both fields before returning output.
  """

  @type tool_summary :: %{name: String.t(), description: String.t() | nil, version: term()}
  @type skill_summary :: %{name: String.t(), description: String.t() | nil, version: term()}

  @type subagent :: %{
          id: String.t(),
          status: atom(),
          template: String.t() | nil,
          last_tool: String.t() | nil
        }

  @type workflow :: %{
          id: String.t(),
          name: String.t(),
          status: atom(),
          started_at: DateTime.t() | nil
        }

  @type handoff :: %{
          template: String.t(),
          from_template: String.t() | nil,
          message: String.t() | nil,
          updated_at_ms: integer() | nil
        }

  @type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), cost: nil}

  @type input_kind :: :module | :pid | :agent_id | :session | :request_id | :workflow_id

  @type t :: %__MODULE__{
          system_prompt: String.t() | nil,
          skills: [skill_summary()],
          tool_names: [String.t()],
          mcp_tools: [String.t()],
          context_preview: String.t() | nil,
          memory: nil | %{namespace: String.t(), blocks_count: non_neg_integer(), scope: map()},
          compaction: map() | nil,
          subagents: [subagent()],
          workflows: [workflow()],
          handoffs: handoff() | nil,
          usage: usage(),
          duration_ms: non_neg_integer() | nil,
          interrupt: map() | nil,
          error: map() | nil,
          message_count: non_neg_integer() | nil,
          request_id: String.t() | nil,
          input_kind: input_kind(),
          resolved_at_ms: integer()
        }

  defstruct system_prompt: nil,
            skills: [],
            tool_names: [],
            mcp_tools: [],
            context_preview: nil,
            memory: nil,
            compaction: nil,
            subagents: [],
            workflows: [],
            handoffs: nil,
            usage: %{input_tokens: 0, output_tokens: 0, cost: nil},
            duration_ms: nil,
            interrupt: nil,
            error: nil,
            message_count: nil,
            request_id: nil,
            input_kind: :agent_id,
            resolved_at_ms: 0
end
