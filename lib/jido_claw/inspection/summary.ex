defmodule JidoClaw.Inspection.Summary do
  @moduledoc """
  Agent-axis projection returned by `JidoClaw.Inspection.inspect_agent/2`,
  `inspect_request/2`, and `inspect_workflow/1`.

  Matches the spirit of Jidoka's `Debug.summary` shape — a single struct
  unifying agent definition (`system_prompt`, `model`, `skills`,
  `tool_names`, `mcp_tools`, `context_preview`, `user_message`) with
  current running state (`memory`, `compaction`, `subagents`,
  `workflows`, `handoffs`, `usage`, `duration_ms`, `status`,
  `interrupt`, `error`, `message_count`).

  `model` reports the configured alias (e.g. `:fast`) on the
  definition/agent paths and the resolved label that actually ran
  (e.g. `"claude-sonnet-4-5"`) on the request path. `status` is the
  trace lifecycle status and stays `nil` on no-trace paths (module,
  `session_map`) — like `usage`/`duration_ms`. `user_message` is the
  request path's user-role context preview, the sibling of
  `context_preview` (which previews the assistant role).

  `:subagents` and `:workflows` are local best-effort inspection fields.
  Tenant-facing runtime status lives in `JidoClaw.SwarmView` and
  `JidoClaw.WorkflowView`; the MCP `inspect_agent` tool drops both fields
  before returning output.
  """

  @type tool_summary :: %{name: String.t(), description: String.t() | nil, version: term()}
  @type skill_summary :: %{
          name: String.t(),
          description: String.t() | nil,
          max_iterations: pos_integer() | nil
        }

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
          model: String.t() | atom() | nil,
          skills: [skill_summary()],
          tool_names: [String.t()],
          mcp_tools: [String.t()],
          context_preview: String.t() | nil,
          user_message: String.t() | nil,
          memory: nil | %{namespace: String.t(), blocks_count: non_neg_integer(), scope: map()},
          compaction: map() | nil,
          subagents: [subagent()],
          workflows: [workflow()],
          handoffs: handoff() | nil,
          usage: usage(),
          duration_ms: non_neg_integer() | nil,
          status: atom() | String.t() | nil,
          interrupt: map() | nil,
          error: map() | nil,
          message_count: non_neg_integer() | nil,
          request_id: String.t() | nil,
          input_kind: input_kind(),
          resolved_at_ms: integer()
        }

  defstruct system_prompt: nil,
            model: nil,
            skills: [],
            tool_names: [],
            mcp_tools: [],
            context_preview: nil,
            user_message: nil,
            memory: nil,
            compaction: nil,
            subagents: [],
            workflows: [],
            handoffs: nil,
            usage: %{input_tokens: 0, output_tokens: 0, cost: nil},
            duration_ms: nil,
            status: nil,
            interrupt: nil,
            error: nil,
            message_count: nil,
            request_id: nil,
            input_kind: :agent_id,
            resolved_at_ms: 0
end
