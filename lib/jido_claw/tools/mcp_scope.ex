defmodule JidoClaw.Tools.MCPScope do
  @moduledoc """
  Inject a default `tool_context` into the three Solutions tools when
  invoked over MCP stdio, and (via `wrap/4`) record per-tool-call
  Message rows when the tool runs under MCP serve mode.

  MCP invocations from external clients (Claude Code, Cursor) hand
  tools a JSON arg map and **no** `tool_context` — without explicit
  handling, every MCP solutions call would fail loudly with the
  "missing scope" error path from `StoreSolution`/`FindSolution`/
  `VerifyCertificate`.

  The MCP server resolves a single workspace at startup from its
  `cwd` (single-user, no auth, by definition), stores the
  `(tenant_id, workspace_uuid, session_uuid, session_id)` tuple
  under `:jido_claw_mcp_default_scope` in the application env, and
  these tools call `with_default/2` to inject those defaults when
  the caller doesn't supply a tool_context.

  Multi-tenant MCP is out of scope — the protocol has no mechanism
  to distinguish callers.
  """

  # MCP boundary: wrap/append/fetch/reresolve all use deliberate catch-alls —
  # one path reraises after recording an error envelope; the rest swallow to
  # `:error`/`:ok` so an Ash/DB fault on the durable transcript never crashes
  # the wrapped tool's `run/2`.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.{Message, ToolTranscript}
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.MCPScope.Initializer
  alias JidoClaw.Security.SensitiveScrub

  @wrapped_key :__jidoclaw_mcp_scope_wrapped__

  @doc """
  Returns the `context` map with `:tool_context` populated from the
  MCP-mode default scope when missing.

  When called outside MCP mode (no default scope registered),
  passes `context` through unchanged.
  """
  @spec with_default(map() | nil) :: map()
  def with_default(context) when is_map(context) do
    case Map.get(context, :tool_context) do
      tc when is_map(tc) and map_size(tc) > 0 ->
        # Caller already supplied scope — respect it.
        context

      _ ->
        case mcp_default_scope() do
          nil -> context
          scope -> Map.put(context, :tool_context, scope)
        end
    end
  end

  def with_default(nil), do: %{tool_context: mcp_default_scope() || %{}}

  @doc """
  Wrap a tool's `run/2` body. Outside MCP serve mode, this is a
  pass-through: it enriches the context (so tools never have to call
  `with_default/1` themselves) and invokes `fun.(enriched_context)`.

  Under MCP serve mode AND with a resolved `session_uuid`, it also
  appends a `:tool_call` Message row before invoking `fun/1`, then a
  `:tool_result` row after — both tied to a per-call
  `request_id`/`tool_call_id` pair. Exceptions are reraised after
  recording an error envelope.

  Per-call IDs default to fresh UUIDs. Callers that need stable IDs
  (retries, recovery) can pass `context[:mcp_request_id]` and
  `context[:mcp_tool_call_id]` overrides; the wrapper's append
  helper mirrors `Recorder.attempt_append/1` on the
  `unique_live_tool_row` partial identity, returning the existing
  row idempotently when the same `(request_id, tool_call_id, role)`
  triple is hit twice.
  """
  @spec wrap(atom() | String.t(), map(), map() | nil, (map() -> any())) :: any()
  def wrap(tool_name, params, context, fun) when is_function(fun, 1) do
    enriched = with_default(context || %{})
    tc = Map.get(enriched, :tool_context) || %{}

    if Map.get(enriched, @wrapped_key) do
      fun.(enriched)
    else
      # `@wrapped_key` is a constant marker flag on the rich tool-context map
      # (not set membership tracking), so MapSet does not apply here.
      # reach:disable-next-line suboptimal
      wrapped = Map.put(enriched, @wrapped_key, true)

      if record?(tc) do
        do_wrap_recorded(tool_name, params, wrapped, tc, fun)
      else
        fun.(wrapped)
      end
    end
  end

  defp record?(tc) do
    Application.get_env(:jido_claw, :serve_mode) == :mcp and
      is_binary(tc[:session_uuid]) and tc[:session_uuid] != ""
  end

  defp do_wrap_recorded(tool_name, params, enriched_ctx, tc, fun) do
    request_id = enriched_ctx[:mcp_request_id] || Ecto.UUID.generate()
    tool_call_id = enriched_ctx[:mcp_tool_call_id] || Ecto.UUID.generate()

    # AR-2 Phase 2b sink (viii): MCPScope appends to `messages` directly
    # (bypassing the Recorder), so it sanitizes a marked composer subagent's
    # content/metadata here too (belt-and-suspenders for a future MCP-exposed
    # composer route).
    {call_content, call_metadata} =
      scrub_message(
        tc,
        ToolTranscript.summarize_args(tool_name, params),
        %{tool_name: to_string(tool_name), arguments: ToolTranscript.envelope(params)}
      )

    call_attrs =
      Map.merge(
        %{
          session_id: tc.session_uuid,
          request_id: request_id,
          role: :tool_call,
          content: call_content,
          metadata: call_metadata,
          tool_call_id: tool_call_id
        },
        identity_attrs(tc)
      )

    actor = actor_for(tc)

    parent_id =
      case attempt_append(call_attrs, tc[:tenant_id], actor) do
        {:ok, %{id: id}} -> id
        _ -> nil
      end

    try do
      result = fun.(enriched_ctx)

      {result_content, result_metadata} =
        scrub_message(
          tc,
          ToolTranscript.result_summary(tool_name, result),
          %{tool_name: to_string(tool_name), result: ToolTranscript.envelope(result)}
        )

      result_attrs =
        Map.merge(
          %{
            session_id: tc.session_uuid,
            request_id: request_id,
            role: :tool_result,
            content: result_content,
            metadata: result_metadata,
            tool_call_id: tool_call_id,
            parent_message_id: parent_id
          },
          identity_attrs(tc)
        )

      _ = attempt_append(result_attrs, tc[:tenant_id], actor)
      result
    rescue
      err ->
        stacktrace = __STACKTRACE__
        err_msg = Exception.message(err)

        {err_content, err_metadata} =
          scrub_message(
            tc,
            "#{tool_name} → exception: #{err_msg}",
            %{tool_name: to_string(tool_name), result: %{error: err_msg}}
          )

        result_attrs =
          Map.merge(
            %{
              session_id: tc.session_uuid,
              request_id: request_id,
              role: :tool_result,
              content: err_content,
              metadata: err_metadata,
              tool_call_id: tool_call_id,
              parent_message_id: parent_id
            },
            identity_attrs(tc)
          )

        _ = attempt_append(result_attrs, tc[:tenant_id], actor)
        reraise(err, stacktrace)
    end
  end

  # Stamp the durable compaction identity from the tool_context. MCP serve
  # mode is single-user main-agent only, so these are normally absent and
  # the message resource's `"main"` / `false` defaults apply; we still
  # forward them in case a future MCP path threads a sub-agent scope.
  defp scrub_message(tc, content, metadata) do
    if Map.get(tc, :sanitize_sensitive_context, false),
      do: {SensitiveScrub.redacted_text(), SensitiveScrub.redacted_map()},
      else: {content, metadata}
  end

  defp identity_attrs(tc) do
    %{}
    |> put_present(:agent_id, Map.get(tc, :agent_id))
    |> put_present(:subagent, Map.get(tc, :subagent))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Build the Ash actor from the tool_context. Prefer the canonical
  # `:actor` slot; otherwise synthesize a tenant-bound system actor so
  # MCP-side appends still pass tenant-actor policies.
  defp actor_for(tc) do
    case Map.get(tc, :actor) do
      %{} = actor ->
        actor

      _ ->
        case Map.get(tc, :tenant_id) do
          tenant_id when is_binary(tenant_id) -> Actor.system(tenant_id)
          _ -> nil
        end
    end
  end

  defp attempt_append(attrs, tenant_id, actor) when is_binary(tenant_id) do
    opts = [tenant: tenant_id]
    opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts

    case Message.append(attrs, opts) do
      {:ok, msg} ->
        {:ok, msg}

      {:error, %Ash.Error.Invalid{} = err} ->
        if duplicate_key?(err) do
          fetch_existing_live_row(attrs, tenant_id, actor)
        else
          Logger.warning("[MCPScope.wrap] append failed: #{inspect(err)}")
          :error
        end

      {:error, reason} ->
        Logger.warning("[MCPScope.wrap] append failed: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("[MCPScope.wrap] append raised: #{Exception.message(e)}")
      :error
  end

  defp attempt_append(_attrs, _, _), do: :error

  defp fetch_existing_live_row(
         %{
           session_id: session_id,
           request_id: request_id,
           tool_call_id: tool_call_id,
           role: role
         },
         tenant_id,
         actor
       )
       when is_binary(request_id) and is_binary(tool_call_id) and is_binary(tenant_id) do
    opts = [tenant: tenant_id]
    opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts

    case Message.by_live_tool_row(session_id, request_id, tool_call_id, role, opts) do
      {:ok, msg} when is_map(msg) -> {:ok, msg}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp fetch_existing_live_row(_, _, _), do: :error

  defp duplicate_key?(err), do: AshErrors.unique_violation?(err, ["unique_live_tool_row"])

  defp mcp_default_scope do
    case Application.get_env(:jido_claw, :jido_claw_mcp_default_scope) do
      scope when is_map(scope) ->
        if is_binary(Map.get(scope, :session_uuid)) and Map.get(scope, :session_uuid) != "" do
          scope
        else
          # Boot-time resolution failed silently — re-resolve via the
          # initializer's helper. Only fires under MCP serve mode so
          # ad-hoc tests under `:mcp` without a configured scope
          # don't trigger DB writes for nothing.
          maybe_reresolve()
          Application.get_env(:jido_claw, :jido_claw_mcp_default_scope) || scope
        end

      nil ->
        maybe_reresolve()
        Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)
    end
  end

  defp maybe_reresolve do
    if Application.get_env(:jido_claw, :serve_mode) == :mcp do
      try do
        Initializer.ensure_default_scope()
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    else
      :ok
    end
  end
end
