defmodule JidoClaw.MCP.ServerSpec do
  @moduledoc """
  A validated external MCP server declaration.

  The product of `JidoClaw.MCP.EndpointConfig.parse/1` for one config entry:

    * `name` — the operator-chosen server name (`^[a-z][a-z0-9_]*$`); also the
      atomized endpoint id and the `mcp_<name>_` local-tool-name prefix root.
    * `endpoint` — the translated `%Jido.MCP.Endpoint{}` ready for registration.
    * `require_approval` — per-server approval posture: `true` (gated),
      `false` (trusted), or `nil` (defer to the global `mcp_require_approval`).
    * `templates` — declared template allowlist; **parsed only** in phase 1
      (per-template enforcement is out of scope — `child/2` clears
      `:agent_template`), retained so the surface is forward-compatible.

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
