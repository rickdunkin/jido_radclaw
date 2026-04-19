# Patch for anubis_mcp 0.17.1 — Anubis.Server.Handlers.Tools
#
# jido_mcp registers tool schemas as JSON Schema, but anubis_mcp 0.17.1
# converts them to Peri format incorrectly. Peri.validate/2 crashes with
# FunctionClauseError when tool arguments are present.
#
# This patch wraps validate_params to rescue the crash and pass arguments
# through unvalidated. Jido.Exec.run validates arguments internally, so
# skipping Peri validation is safe.
#
# Strict compile relies on `elixirc_options: [ignore_module_conflict: true]`
# in mix.exs to suppress the "redefining module" warning this intentionally
# triggers. Remove both that flag and this file once jido_mcp upgrades to
# anubis_mcp ~> 1.0.
defmodule Anubis.Server.Handlers.Tools do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Component.Schema
  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers
  alias Anubis.Server.Response

  @spec handle_list(map, Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_list(request, frame, server_module) do
    tools = Handlers.get_server_tools(server_module, frame)
    limit = frame.private[:pagination_limit]
    {tools, cursor} = Handlers.maybe_paginate(request, tools, limit)

    {:reply,
     then(
       %{"tools" => tools},
       &if(cursor, do: Map.put(&1, "nextCursor", cursor), else: &1)
     ), frame}
  end

  @spec handle_call(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_call(%{"params" => %{"name" => tool_name, "arguments" => params}}, frame, server) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with {:ok, params} <- validate_params(params, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  def handle_call(%{"params" => %{"name" => tool_name}}, frame, server) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with {:ok, params} <- validate_params(%{}, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  # Private functions

  defp find_tool_module(tools, name), do: Enum.find(tools, &(&1.name == name))

  defp validate_params(_, %Tool{validate_input: nil}, _), do: {:ok, %{}}

  # FIX: Rescue Peri crashes from JSON Schema / Peri format mismatch.
  # Pass arguments through unvalidated — Jido.Exec.run validates internally.
  defp validate_params(params, %Tool{} = tool, frame) do
    case tool.validate_input.(params) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        message = Schema.format_errors(errors)
        {:error, Error.protocol(:invalid_params, %{message: message}), frame}
    end
  rescue
    _error -> {:ok, params}
  end

  defp forward_to(server, %Tool{handler: nil} = tool, params, frame) do
    # FIX: MCP JSON arguments arrive with string keys, but Jido actions expect
    # atom keys. Atomize known keys; unknown keys stay as strings (safe because
    # tool schemas are fixed at compile time — no user-controlled atom creation).
    params = atomize_known_keys(params)

    case server.handle_tool_call(tool.name, params, frame) do
      {:reply, %Response{} = response, frame} ->
        maybe_validate_output_schema(tool, response, frame)

      {:noreply, frame} ->
        {:reply, %{"content" => [], "isError" => false}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end

  defp forward_to(_server, %Tool{handler: handler} = tool, params, frame) do
    case handler.execute(params, frame) do
      {:reply, %Response{} = response, frame} ->
        maybe_validate_output_schema(tool, response, frame)

      {:noreply, frame} ->
        {:reply, %{"content" => [], "isError" => false}, frame}

      {:error, %Error{} = error, frame} ->
        {:error, error, frame}
    end
  end

  defp atomize_known_keys(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_binary(key) ->
        case safe_to_existing_atom(key) do
          {:ok, atom_key} -> {atom_key, value}
          :error -> {key, value}
        end

      pair ->
        pair
    end)
  end

  defp safe_to_existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  @output_schema_err "Tool doesnt conform for it output schema"

  defp maybe_validate_output_schema(%Tool{output_schema: nil}, resp, frame) do
    {:reply, Response.to_protocol(resp), frame}
  end

  defp maybe_validate_output_schema(_tool, %Response{isError: true} = resp, frame) do
    {:reply, Response.to_protocol(resp), frame}
  end

  defp maybe_validate_output_schema(%Tool{} = tool, %Response{structured_content: nil}, frame) do
    metadata = %{tool_name: tool.name}
    {:error, Error.execution(@output_schema_err, metadata), frame}
  end

  defp maybe_validate_output_schema(%Tool{} = tool, %Response{} = resp, frame) do
    case tool.validate_output.(resp.structured_content) do
      {:ok, _} -> {:reply, Response.to_protocol(resp), frame}
      {:error, errors} -> {:error, Error.execution(@output_schema_err, %{errors: errors}), frame}
    end
  end
end
