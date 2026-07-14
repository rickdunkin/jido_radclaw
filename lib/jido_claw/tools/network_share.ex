defmodule JidoClaw.Tools.NetworkShare do
  # The {code, message, details} map is the LLM-facing wire-error contract
  # (shared with JidoClaw.Tools.Error) — an explicit API surface, not
  # incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  Tool that shares a solution with the agent network for other agents to discover and use.
  """

  use JidoClaw.Tools.Action,
    name: "network_share",
    description: "Share a solution with the agent network for other agents to discover and use.",
    category: "solutions",
    tags: ["solutions", "write"],
    output_schema: [
      solution_id: [type: :string, required: true],
      status: [type: :string, required: true],
      reason: [type: :string]
    ],
    schema: [
      solution_id: [
        type: :string,
        required: true,
        doc: "ID of the solution to share"
      ]
    ]

  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.OutputLimit

  @impl Jido.Action
  def run(params, context) do
    MCPScope.wrap(:network_share, params, context, fn _enriched ->
      params.solution_id
      |> JidoClaw.Network.Node.broadcast_solution()
      |> normalize_share_result(params.solution_id)
    end)
  end

  @doc """
  Test seam: normalize one `Network.Node.broadcast_solution/1` result into
  the tool's wire shape. A missing solution is a NORMAL domain outcome —
  mapped at this producer to the registered `:not_found` (PD1-2's
  normalize-at-the-producer rule) rather than tripping the served-MCP
  boundary's drift fallback; the residual catch-all stays an open forwarder
  for genuinely unforeseen atoms (the boundary fallback + drift log cover
  those).
  """
  @spec normalize_share_result(:ok | {:error, term()}, String.t()) ::
          {:ok, map()} | {:error, term()}
  def normalize_share_result(:ok, solution_id) do
    {:ok, %{solution_id: solution_id, status: "shared"}}
  end

  def normalize_share_result({:error, :not_connected}, solution_id) do
    {:ok, %{solution_id: solution_id, status: "not_shared", reason: "network not connected"}}
  end

  def normalize_share_result({:error, :not_running}, solution_id) do
    {:ok, %{solution_id: solution_id, status: "not_shared", reason: "network not running"}}
  end

  def normalize_share_result({:error, :solution_not_found}, solution_id) do
    {:error,
     %{
       code: :not_found,
       message: "Solution '#{bound_solution_id(solution_id)}' not found.",
       details: %{retry: false, solution_id: solution_id, kind: "solution"}
     }}
  end

  def normalize_share_result({:error, reason}, _solution_id), do: {:error, reason}

  # 256-byte identifier bound for the request-input id in the message
  # (UTF-8-safe truncation; the exact id stays in details for lookups).
  @solution_id_message_bytes 256

  defp bound_solution_id(id) when is_binary(id) and byte_size(id) > @solution_id_message_bytes do
    id
    |> binary_part(0, @solution_id_message_bytes)
    |> OutputLimit.valid_utf8_prefix()
  end

  defp bound_solution_id(id) when is_binary(id), do: id
end
