defmodule JidoClaw.Orchestration.Verify.Evidence.Reader do
  @moduledoc """
  The default `Evidence.reader/0` seam implementation: read one request's
  durable transcript rows via `Conversations.Message.by_request` and hand them
  to the pure decode as plain `%{role, tool_call_id, metadata}` maps. Tests
  point the seam at a stub (`config :jido_claw, :evidence, reader: module`)
  so classification runs against canned rows — the engine-minted request_id
  is why a raw row-seed would race.
  """

  alias JidoClaw.Conversations.Message

  @doc """
  The request's transcript rows, reduced to the fields the evidence decode
  reads. `{:error, reason}` on any read failure — the caller degrades to a
  skip, never raises.
  """
  @spec tool_rows(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def tool_rows(session_id, request_id, opts) do
    case Message.by_request(session_id, request_id,
           tenant: opts[:tenant],
           actor: opts[:actor]
         ) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           # Wire-shaped row projection (reader seam contract — stubs build
           # the same maps).
           # reach:disable-next-line fixed_shape_map
           %{role: row.role, tool_call_id: row.tool_call_id, metadata: row.metadata}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
