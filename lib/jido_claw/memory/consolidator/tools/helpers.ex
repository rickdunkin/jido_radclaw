defmodule JidoClaw.Memory.Consolidator.Tools.Helpers do
  @moduledoc """
  Shared dispatch helpers for the consolidator MCP tools.

  Each tool reads `:consolidator_run_id` from the MCP frame's
  assigns (passed through to the action context as `ctx.assigns`),
  looks up the matching RunServer via `RunRegistry`, and
  `GenServer.call`s it with the proposal envelope.
  """

  @registry JidoClaw.Memory.Consolidator.RunRegistry

  @doc """
  Dispatch a request envelope to the run server, treating the reply
  as the tool's `{:ok, _}` / `{:error, _}` result.
  """
  @spec dispatch(map(), term()) :: {:ok, term()} | {:error, term()}
  def dispatch(ctx, msg) do
    case call_run_server(ctx, msg) do
      {:ok, _} = ok -> ok
      :ok -> {:ok, %{ok: true}}
      {:error, _} = err -> err
      other -> {:ok, other}
    end
  end

  @doc """
  Send a `GenServer.call` to the RunServer for this run, returning
  whatever the server replies with (so tools that need to inspect
  custom error tuples — e.g. `{:char_limit_exceeded, ...}` — can
  do so).
  """
  @spec call_run_server(map(), term()) :: term()
  def call_run_server(ctx, msg) do
    run_id = run_id_from(ctx)

    case run_id && Registry.lookup(@registry, run_id) do
      [{pid, _}] -> GenServer.call(pid, msg, 30_000)
      _ -> {:error, "no active run for #{inspect(run_id)}"}
    end
  end

  defp run_id_from(%{assigns: %{consolidator_run_id: id}}) when is_binary(id), do: id

  defp run_id_from(%{assigns: assigns}) when is_map(assigns),
    do: Map.get(assigns, "consolidator_run_id")

  defp run_id_from(_), do: nil
end
