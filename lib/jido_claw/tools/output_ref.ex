defmodule JidoClaw.Tools.OutputRef do
  @moduledoc """
  Shared, scope-aware lookup for stored tool-output refs (`out_…`),
  extracted from `JidoClaw.Tools.FetchOutput` so every ref reader —
  `fetch_output` and the Lua `jido.output` binding — goes through the
  SAME security discriminator.

  The read is always tenant-scoped; on session-meaningful surfaces (a
  REPL / gateway turn carrying a resolved `session_uuid`) it is ALSO
  session-scoped (S-M2), so one session can't fetch another's stored
  output — while system/cron-minted (`session_id: nil`) refs stay
  reachable. Under `:mcp` serve-mode the boot scope stays tenant-wide
  (the documented REPL-minted-ref drill-in flow) even though the MCP
  scope carries its OWN `session_uuid`; the SURFACE (`serve_mode`), not
  "caller has a session", is the discriminator. Uses `session_uuid`
  (the DB uuid the store writes), NOT the human `session_id` string.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.ToolOutput

  @doc """
  Fetch the stored `ToolOutput` row behind `ref` under the caller's
  scope. `tool_context` supplies the optional `:actor` (defaulting to a
  tenant-bound system actor) and the `:session_uuid` the S-M2 scoping
  reads. Misses (unknown, expired, or out-of-scope refs) all collapse to
  one indistinguishable error message.
  """
  @spec lookup(String.t(), String.t(), map()) ::
          {:ok, ToolOutput.t()} | {:error, String.t()}
  def lookup(ref, tenant_id, tool_context)
      when is_binary(ref) and is_binary(tenant_id) and is_map(tool_context) do
    actor = Map.get(tool_context, :actor) || Actor.system(tenant_id)

    result =
      case scoped_session(tool_context) do
        {:ok, session_uuid} ->
          ToolOutput.by_ref_scoped(ref, session_uuid, tenant: tenant_id, actor: actor)

        :tenant_wide ->
          ToolOutput.by_ref(ref, tenant: tenant_id, actor: actor)
      end

    case result do
      {:ok, row} -> {:ok, row}
      {:error, _} -> {:error, "no stored output for ref #{ref} (expired or unknown)"}
    end
  end

  defp scoped_session(tool_context) do
    with false <- mcp_serve_mode?(),
         session_uuid when is_binary(session_uuid) <- Map.get(tool_context, :session_uuid) do
      {:ok, session_uuid}
    else
      _ -> :tenant_wide
    end
  end

  defp mcp_serve_mode?, do: Application.get_env(:jido_claw, :serve_mode) == :mcp
end
