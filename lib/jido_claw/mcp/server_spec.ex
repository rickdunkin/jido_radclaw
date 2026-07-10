defmodule JidoClaw.MCP.ServerSpec do
  @moduledoc """
  A validated external MCP server declaration.

  The product of `JidoClaw.MCP.EndpointConfig.parse/1` for one config entry:

    * `name` — the operator-chosen server name (`^[a-z][a-z0-9_]*$`); the
      `mcp_<name>_` local-tool-name prefix root. Endpoint ids come from
      `EndpointConfig`'s fixed VM-stable atom pool, never from this binary.
    * `endpoint` — the translated `%Jido.MCP.Endpoint{}` ready for registration.
    * `require_approval` — per-server approval posture: `true` (gated),
      `false` (trusted), or `nil` (defer to the global `mcp_require_approval`).
    * `templates` — the **reach-allowlist** of agent templates that may register
      this server's tools. `[]`/absent ⇒ **all** templates (back-compat); a
      non-empty list ⇒ **only** those templates' agents get the tools, withheld
      from everyone else at *registration* (the LLM never sees them — stronger
      and simpler than gating the call). `"main"` is a nameable template: an
      allowlist must include it to keep the tools on the interactive REPL agent.
      Enforced in `JidoClaw.MCP.Consumer` (`modules_for_template/3`).

  A struct (not a bare map) so reach's `fixed_shape_map` stays satisfied.
  """

  @enforce_keys [:name, :endpoint]
  defstruct [:name, :endpoint, :require_approval, templates: []]

  @type t :: %__MODULE__{
          name: String.t(),
          endpoint: Jido.MCP.Endpoint.t(),
          require_approval: boolean() | nil,
          templates: [String.t()]
        }
end
