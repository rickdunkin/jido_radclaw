defmodule JidoClaw.Memory.Consolidator.Tools.Helpers do
  @moduledoc """
  Shared dispatch helpers for the consolidator MCP tools.

  Each tool reads `:consolidator_run_id` from the MCP frame's
  assigns (passed through to the action context as `ctx.assigns`),
  looks up the matching RunServer via `RunRegistry`, and
  `GenServer.call`s it with the proposal envelope.
  """

  alias JidoClaw.MCP.ScopedForward

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

  Every envelope is wrapped with the caller's attempt token (from the
  tokenized endpoint path) — enforcement is centralized in the RunServer's
  `{:mcp_tool, token, msg}` handler for EVERY tool, readers included, so a
  stale CLI holding a closed attempt's URL is refused with a typed error
  and a future mutating tool can't be forgotten.
  """
  @spec call_run_server(map(), term()) :: term()
  def call_run_server(ctx, msg) do
    run_id = run_id_from(ctx)

    case run_id && Registry.lookup(@registry, run_id) do
      [{pid, _}] -> GenServer.call(pid, {:mcp_tool, attempt_token_from(ctx), msg}, 30_000)
      _ -> {:error, "no active run for #{inspect(run_id)}"}
    end
  end

  # Partial application of the shared both-key-shapes assigns reader (the
  # atom key ScopedForward stamps, or the string key jido_mcp's context
  # marshalling can downgrade it to).
  defp run_id_from(ctx), do: ScopedForward.scope_id(ctx, :consolidator_run_id)

  defp attempt_token_from(ctx), do: ScopedForward.scope_id(ctx, :consolidator_attempt_token)
end
