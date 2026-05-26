# Patch for anubis_mcp 1.6.1 — Anubis.Server.Handlers.Tools
#
# Port of upstream 1.6.1's handler — including check_task_policy/3 (MCP spec
# 2025-11-25 task-augmentation semantics) and check_scopes/2 + visible?/2
# (OAuth 2.1 authorization, added in 1.6.0 #158) — with two surgical changes
# layered in:
#   1. validate_params/3 has a `rescue` clause that returns {:ok, params} on
#      any Peri crash. jido_mcp registers tool input_schemas as JSON Schema
#      via `Jido.Action.Schema.to_json_schema/2`
#      (deps/jido_mcp/lib/jido_mcp/server/runtime.ex), but the upstream
#      handler routes them through Peri before dispatch. Peri crashes with
#      FunctionClauseError on JSON-Schema-shaped descriptors. Jido.Exec.run
#      validates arguments internally, so skipping Peri validation is safe.
#   2. atomize_known_keys/1 converts known string keys to atoms before
#      calling server.handle_tool_call/3. MCP JSON arrives with string keys
#      but Jido actions pattern-match on atom keys. Unknown keys stay as
#      strings (String.to_existing_atom/1, so no user-controlled atom
#      creation).
#
# The scope filter in `handle_list/3`, the `check_scopes` step in both
# `handle_call/3` clauses, and the `check_scopes/2` + `visible?/2` helpers
# are ported verbatim from 1.6.0's OAuth 2.1 feature so the patch preserves
# upstream's authorization enforcement. Today every JidoClaw tool registers
# with the struct default `scopes: []`, which short-circuits both helpers,
# but porting them keeps the patch byte-equivalent in behavior to 1.6.1 for
# any future call site that does declare scopes.
#
# Strict compile relies on `elixirc_options: [ignore_module_conflict: true]`
# in mix.exs to suppress the "redefining module" warning this intentionally
# triggers. Remove once jido_mcp either emits Peri-compatible schemas or no
# longer registers JSON-Schema-shaped descriptors on Anubis's pre-dispatch
# Peri validation path.
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
    tools =
      server_module
      |> Handlers.get_server_tools(frame)
      |> Enum.filter(&visible?(&1, frame))

    limit = frame.pagination_limit
    {tools, cursor} = Handlers.maybe_paginate(request, tools, limit)

    {:reply,
     then(
       %{"tools" => tools},
       &if(cursor, do: Map.put(&1, "nextCursor", cursor), else: &1)
     ), frame}
  end

  @spec handle_call(map(), Frame.t(), module()) ::
          {:reply, map(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_call(
        %{"params" => %{"name" => tool_name, "arguments" => params}} = request,
        frame,
        server
      ) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with :ok <- check_scopes(tool, frame),
           :ok <- check_task_policy(tool, request, frame),
           {:ok, params} <- validate_params(params, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  def handle_call(%{"params" => %{"name" => tool_name}} = request, frame, server) do
    registered_tools = Handlers.get_server_tools(server, frame)

    if tool = find_tool_module(registered_tools, tool_name) do
      with :ok <- check_scopes(tool, frame),
           :ok <- check_task_policy(tool, request, frame),
           {:ok, params} <- validate_params(%{}, tool, frame),
           do: forward_to(server, tool, params, frame)
    else
      payload = %{message: "Tool not found: #{tool_name}"}
      {:error, Error.protocol(:invalid_params, payload), frame}
    end
  end

  # Private functions

  defp check_scopes(%Tool{scopes: []}, _frame), do: :ok

  defp check_scopes(%Tool{scopes: required}, frame) do
    granted = Frame.scopes(frame)
    missing = Enum.reject(required, &(&1 in granted))

    if missing == [] do
      :ok
    else
      {:error, Error.execution("insufficient_scope", %{required: required, granted: granted}),
       frame}
    end
  end

  defp visible?(%Tool{scopes: []}, _frame), do: true
  defp visible?(%Tool{scopes: required}, frame), do: Frame.has_all_scopes?(frame, required)

  defp find_tool_module(tools, name), do: Enum.find(tools, &(&1.name == name))

  # Spec 2025-11-25: tool with execution.taskSupport == "required" MUST be
  # invoked as a task. Direct (non-augmented) calls return -32601. Augmented
  # calls reach this handler only via the task worker path, where
  # `Frame.task_id` is set, so we use that as the discriminator.
  defp check_task_policy(%Tool{task_support: :required}, _request, %Frame{task_id: nil} = frame) do
    {:error,
     Error.protocol(:method_not_found, %{
       message: "Tool requires task augmentation (execution.taskSupport == \"required\")"
     }), frame}
  end

  defp check_task_policy(%Tool{task_support: :forbidden}, %{"params" => %{"task" => _}}, frame) do
    {:error,
     Error.protocol(:method_not_found, %{
       message: "Tool does not support task augmentation (execution.taskSupport == \"forbidden\")"
     }), frame}
  end

  defp check_task_policy(_tool, _request, _frame), do: :ok

  defp validate_params(_, %Tool{validate_input: nil}, _), do: {:ok, %{}}

  # FIX: Rescue Peri crashes from JSON Schema / Peri format mismatch.
  # Pass arguments through unvalidated — Jido.Exec.run validates internally.
  defp validate_params(params, %Tool{} = tool, frame) do
    with {:error, errors} <- tool.validate_input.(params) do
      message = Schema.format_errors(errors)
      {:error, Error.protocol(:invalid_params, %{message: message}), frame}
    end
  rescue
    _ -> {:ok, params}
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
