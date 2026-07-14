# Patch for jido_mcp — Jido.MCP.Server.Runtime
#
# Verbatim port of upstream jido_mcp's server runtime
# (deps/jido_mcp/lib/jido_mcp/server/runtime.ex) with TWO surgical changes
# layered in:
#   1. The two `{:error, ...}` arms of `handle_tool_call/5` route through
#      `JidoClaw.MCPServer.ErrorBoundary.error_response(reason, server_module,
#      token)` instead of the flat `Response.tool() |> Response.error(inspect(reason))`.
#      For the PUBLIC server (JidoClaw.MCPServer) the boundary emits the
#      additive dual-content shape — content[0] the byte-identical legacy
#      inspect text, content[1] the canonical registry-enforced JSON envelope
#      (pad PD1-2, served-surface v1.3). Every OTHER server riding this
#      runtime (memory consolidator, Forge deposit server) keeps the
#      byte-identical legacy single-item arm inside the boundary.
#   2. Wrap-provenance threading: `handle_tool_call/5` mints a per-call
#      token via `ErrorBoundary.mint_wrap_token(server_module)` (a ref for
#      the PUBLIC server only — unconditional minting would put marker keys
#      into the consolidator/deposit servers' byte-pinned legacy arms; nil
#      everywhere else), passes it to the forked `Jido.Exec.run/4` as
#      `ErrorBoundary.exec_opts(token)` so exec's map-wrap arms can stamp a
#      canonical envelope's wrap, and threads the same token to the boundary
#      as the tier-1 witness (detached on exact ref identity there). Policy
#      lives in the boundary; this patch just threads. Port provenance:
#      docs/exploration/pms/pad/PORT-PD1-2-EXEC.md.
#
# Everything else — registration, resource/prompt handling, the outer
# rescue/catch protocol-error conversion, response/prompt helpers — is
# ported verbatim so the patch stays behavior-equivalent for all non-error
# paths.
#
# Strict compile relies on `elixirc_options: [ignore_module_conflict: true]`
# in mix.exs to suppress the "redefining module" warning this intentionally
# triggers; boot-time force-load + release BEAM relocation are driven by
# `JidoClaw.Core.DependencyPatches.patched_modules/0`. Remove once jido_mcp
# offers an error-rendering seam (e.g. a per-server error formatter callback)
# that lets the boundary hook in without redefining the runtime.
defmodule Jido.MCP.Server.Runtime do
  # Verbatim upstream port: the bare rescues, explicit try blocks, apply/2,
  # and single-function pipes below are jido_mcp's own idioms, kept
  # byte-equivalent so the patch diff stays exactly the header, the
  # ErrorBoundary alias, the token mint + exec-opts threading, and the two
  # error arms (the parity test reconstructs this file from upstream by
  # those transformations alone).
  # reach:disable-for-this-file bare_rescue
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  # credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry
  # credo:disable-for-this-file Credo.Check.Readability.SinglePipe
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Jido.Action.Schema
  alias JidoClaw.MCPServer.ErrorBoundary

  @spec register_tool(Frame.t(), module()) :: Frame.t()
  def register_tool(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_tool(frame, module.name(),
      description: maybe_description(module),
      input_schema: action_input_schema(module)
    )
  end

  @spec register_resource(Frame.t(), module()) :: Frame.t()
  def register_resource(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_resource(frame, module.uri(),
      name: module.name(),
      title: module.name(),
      description: module.description(),
      mime_type: module.mime_type()
    )
  end

  @spec register_prompt(Frame.t(), module()) :: Frame.t()
  def register_prompt(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_prompt(frame, module.name(),
      description: module.description(),
      arguments: module.arguments_schema()
    )
  end

  @spec handle_tool_call([module()], String.t(), map(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_tool_call(tool_modules, name, arguments, %Frame{} = frame, server_module)
      when is_list(tool_modules) and is_binary(name) and is_map(arguments) do
    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :tool_call, name: name, arguments: arguments},
               frame
             ),
           {:ok, module} <- find_tool(tool_modules, name) do
        # PATCH change 2: per-call wrap-provenance token (public server →
        # ref; every other server → nil, opts stay []).
        token = ErrorBoundary.mint_wrap_token(server_module)

        case Jido.Exec.run(
               module,
               arguments,
               build_action_context(frame),
               ErrorBoundary.exec_opts(token)
             ) do
          {:ok, output} ->
            {:reply, tool_response(output), frame}

          {:ok, output, _directives} ->
            {:reply, tool_response(output), frame}

          # PATCH change 1: error arms route through the served-MCP error
          # boundary (public server → dual-content structured shape; other
          # servers → byte-identical legacy arm).
          {:error, reason} ->
            {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}

          {:error, reason, _directives} ->
            {:reply, ErrorBoundary.error_response(reason, server_module, token), frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized tool call"}), frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Tool call execution failed", %{
           name: name,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Tool call execution failed", %{
           name: name,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  @spec handle_resource_read([module()], String.t(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_resource_read(resource_modules, uri, %Frame{} = frame, server_module)
      when is_list(resource_modules) and is_binary(uri) do
    try do
      with :ok <- authorize(server_module, %{type: :resource_read, uri: uri}, frame),
           {:ok, module} <- find_resource(resource_modules, uri) do
        case module.read(uri, frame) do
          {:ok, content} ->
            {:reply, resource_response(content), frame}

          {:error, reason} ->
            {:error, Error.resource(:not_found, %{message: inspect(reason), uri: uri}), frame}

          other ->
            {:error,
             Error.execution("Resource read returned invalid result", %{
               uri: uri,
               result: inspect(other)
             }), frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.resource(:not_found, %{message: "Resource not found: #{uri}", uri: uri}),
           frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized resource read"}),
           frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Resource read failed", %{
           uri: uri,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Resource read failed", %{
           uri: uri,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  @spec handle_prompt_get([module()], String.t(), map(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_prompt_get(prompt_modules, name, arguments, %Frame{} = frame, server_module)
      when is_list(prompt_modules) and is_binary(name) and is_map(arguments) do
    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :prompt_get, name: name, arguments: arguments},
               frame
             ),
           {:ok, module} <- find_prompt(prompt_modules, name) do
        case module.messages(arguments, frame) do
          {:ok, messages} when is_list(messages) ->
            {:reply, prompt_response(messages), frame}

          {:error, reason} ->
            {:error, Error.execution("Prompt rendering failed", %{reason: inspect(reason)}),
             frame}

          other ->
            {:error,
             Error.execution("Prompt rendering returned invalid result", %{
               name: name,
               result: inspect(other)
             }), frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.protocol(:invalid_params, %{message: "Prompt not found: #{name}"}),
           frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized prompt access"}),
           frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Prompt rendering failed", %{
           name: name,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Prompt rendering failed", %{
           name: name,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  defp find_tool(modules, name) do
    case Enum.find(modules, &(function_exported?(&1, :name, 0) and &1.name() == name)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp find_resource(modules, uri) do
    case Enum.find(modules, &(function_exported?(&1, :uri, 0) and &1.uri() == uri)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp find_prompt(modules, name) do
    case Enum.find(modules, &(function_exported?(&1, :name, 0) and &1.name() == name)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp tool_response(%{} = output), do: Response.tool() |> Response.structured(output)

  defp resource_response(%{} = output), do: Response.resource() |> Response.json(output)

  defp resource_response(output) when is_list(output),
    do: Response.resource() |> Response.text(Jason.encode!(output))

  defp resource_response(output) when is_binary(output),
    do: Response.resource() |> Response.text(output)

  defp resource_response(output), do: Response.resource() |> Response.text(inspect(output))

  defp prompt_response(messages) when is_list(messages) do
    prompt = Response.prompt()

    Enum.reduce(messages, prompt, fn message, acc ->
      case normalize_prompt_message(message) do
        {"user", content} -> Response.user_message(acc, content)
        {"assistant", content} -> Response.assistant_message(acc, content)
        {"system", content} -> Response.system_message(acc, content)
        {_role, content} -> Response.user_message(acc, content)
      end
    end)
  end

  defp normalize_prompt_message(%{"role" => role, "content" => content}),
    do: {to_string(role), content}

  defp normalize_prompt_message(%{role: role, content: content}), do: {to_string(role), content}
  defp normalize_prompt_message(content) when is_binary(content), do: {"user", content}
  defp normalize_prompt_message(other), do: {"user", inspect(other)}

  defp build_action_context(%Frame{assigns: assigns, context: context} = frame) do
    %{
      mcp_frame: frame,
      mcp_context: context,
      transport: %{},
      request: nil,
      assigns: assigns
    }
  end

  defp action_input_schema(module) do
    module
    |> apply(:schema, [])
    |> Schema.to_json_schema(strict: true)
  rescue
    _ -> %{"type" => "object", "properties" => %{}, "required" => []}
  end

  defp maybe_description(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: nil
  end

  defp authorize(server_module, request, frame) do
    try do
      if function_exported?(server_module, :authorize, 2) do
        case server_module.authorize(request, frame) do
          :ok -> :ok
          true -> :ok
          _ -> {:error, :unauthorized}
        end
      else
        :ok
      end
    rescue
      _ -> {:error, :unauthorized}
    catch
      _, _ -> {:error, :unauthorized}
    end
  end
end
