defmodule JidoClaw.MCP.ScopedForward do
  @moduledoc """
  Plug shim that stamps a scope id from a path param into `conn.assigns`
  before delegating to Anubis's streamable-HTTP plug. Anubis copies
  `conn.assigns` onto the MCP frame, where tool handlers read the scope back
  via `scope_id/2`.

  Init is lazy — Anubis's plug looks up the server's session config via
  `:persistent_term` at init time, which only works after the server has
  started. We defer the init to request time (the original consolidator
  `RunForward` property, preserved for every consumer).

  Executor-seam PR-2 (decision 5): generalized from the consolidator's
  `Plug.RunForward`, which this module replaces. Consumers pass the scope
  wiring per call: `call(conn, server:, assign_key:, path_param:)`.
  """

  @behaviour Plug

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: AnubisPlug

  @impl Plug
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @doc """
  Stamp `conn.path_params[path_param]` into `conn.assigns[assign_key]`, then
  delegate to Anubis's plug with the remaining opts (`server:` et al.).
  """
  @impl Plug
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    {assign_key, rest} = Keyword.pop!(opts, :assign_key)
    {path_param, anubis_opts} = Keyword.pop!(rest, :path_param)

    conn = Plug.Conn.assign(conn, assign_key, conn.path_params[path_param])
    AnubisPlug.call(conn, AnubisPlug.init(anubis_opts))
  end

  @doc """
  Read the stamped scope id back from a tool handler's context (the MCP
  frame's assigns, passed through as `ctx.assigns`). Tolerates both key
  shapes — the atom key this module stamps and the string key jido_mcp's
  context marshalling can downgrade it to — and returns `nil` for anything
  else (no assigns, unknown key).
  """
  @spec scope_id(term(), atom()) :: term() | nil
  def scope_id(%{assigns: assigns}, key) when is_map(assigns) and is_atom(key) do
    case assigns do
      %{^key => id} when is_binary(id) -> id
      _ -> Map.get(assigns, Atom.to_string(key))
    end
  end

  def scope_id(_ctx, _key), do: nil
end
