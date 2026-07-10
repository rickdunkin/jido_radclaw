defmodule JidoClaw.Audit.AshTracer do
  @moduledoc """
  `Ash.Tracer` implementation that emits a `:policy_denied` audit row
  whenever an Ash action is rejected by the policy authorizer.

  Wiring: `config :ash, :tracer, [JidoClaw.Audit.AshTracer, ...]`. The
  tracer captures per-span metadata (resource, action, actor, tenant)
  via `set_metadata/2` and stashes it in the process dictionary. When
  Ash signals a handled error through `set_handled_error/2` and the
  error class is `Ash.Error.Forbidden`, it emits an `Audit.Event` via
  `AsyncWriter.enqueue/1` so the denial is captured without adding
  write latency to the rejected request.

  Only `:action` span metadata is captured — sub-spans (`:changeset`,
  `:query`, `:change`, etc.) flow through the same callbacks but are
  ignored so a denial inside an action surfaces once at the action
  boundary rather than once per nested span.

  ## Propagation fence (no double-emit)

  Ash re-dispatches the SAME handled denial at every enclosing action
  boundary as it unwinds — each frame re-wrapped with fresh
  bread_crumbs/stacktraces, so term equality can never fence it. Every
  `:action` span push therefore records a monotonic per-process
  **generation**, and the generation that last emitted a denial is
  remembered: a frame at the same or an OLDER generation is the
  already-audited denial travelling upward (suppressed), while a NEWER
  frame is genuinely new work (a second caught sibling child may emit).
  A successful cleanup action in between bumps the counter but never
  the marker, so the parent's eventual observation of the ORIGINAL
  denial stays suppressed. Only a successful writer-task spawn
  (`:emitted` — "task spawned", not "audit persisted") sets the marker;
  a skipped nil-tenant child or a failed spawn leaves the enclosing
  frame free to attempt its own audit.
  """

  @behaviour Ash.Tracer

  alias JidoClaw.Audit.ActorClassifier
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Audit.EventAttrs
  alias JidoClaw.Core.MapKeys

  @process_key :jido_claw_audit_tracer_metadata
  @generation_key :jido_claw_audit_tracer_generation
  @emitted_error_key :jido_claw_audit_tracer_emitted_generation
  # Frame-internal key carrying the span's generation; Ash action metadata
  # never uses this name, so `Map.merge/2` in set_metadata preserves it.
  @generation_field :__span_generation__
  @resource_target_kinds %{
    JidoClaw.Workspaces.Workspace => :workspace,
    JidoClaw.Conversations.Session => :session,
    JidoClaw.Conversations.Message => :message,
    JidoClaw.Solutions.Solution => :solution,
    JidoClaw.Solutions.Reputation => :reputation,
    JidoClaw.Memory.Block => :memory_block,
    JidoClaw.Memory.Fact => :memory_fact,
    JidoClaw.Memory.Episode => :memory_episode,
    JidoClaw.Memory.Link => :memory_link,
    JidoClaw.Memory.ConsolidationRun => :memory_consolidation_run,
    JidoClaw.Cron.Job => :cron_job
  }

  @impl Ash.Tracer
  def start_span(_type, _name) do
    # Only :action spans reach this callback (trace_type?/1), so every push
    # is one action-span generation. The frame records the generation it was
    # opened under — the propagation fence set_handled_error keys on.
    generation = Process.get(@generation_key, 0) + 1
    Process.put(@generation_key, generation)
    Process.put(@process_key, [%{@generation_field => generation} | metadata_stack()])
    :ok
  end

  @impl Ash.Tracer
  def stop_span do
    case metadata_stack() do
      [_current] -> delete_process_state()
      [_current | parent_spans] -> Process.put(@process_key, parent_spans)
      [] -> delete_process_state()
    end

    :ok
  end

  # Cross-request isolation for pooled processes: when the span stack
  # empties, the generation counter and emitted marker go with it.
  defp delete_process_state do
    Process.delete(@process_key)
    Process.delete(@generation_key)
    Process.delete(@emitted_error_key)
  end

  @impl Ash.Tracer
  def get_span_context, do: nil

  @impl Ash.Tracer
  def set_span_context(_context), do: :ok

  # Ash dispatches `set_metadata(tracer, :action, meta)` from inside
  # calculation/aggregate spans too (deps/ash/lib/ash/actions/read/
  # calculations.ex:627, deps/ash/lib/ash/actions/aggregate.ex:82),
  # where the metadata carries a `:calculation` / `:aggregates` key
  # but **no** `:action` key. Storing those payloads would clobber
  # the real action metadata captured by the outer action span and
  # leave the next `set_handled_error` with no action to attribute
  # the denial to. Require the action key to discriminate.
  @impl Ash.Tracer
  def set_metadata(:action, %{action: _} = metadata) do
    case metadata_stack() do
      [current | parent_spans] when is_map(current) ->
        Process.put(@process_key, [Map.merge(current, metadata) | parent_spans])

      [_current | parent_spans] ->
        Process.put(@process_key, [metadata | parent_spans])

      [] ->
        # Defensive fallback for a direct callback invocation outside an
        # `Ash.Tracer.span/4` wrapper.
        Process.put(@process_key, [metadata])
    end

    :ok
  end

  def set_metadata(_type, _metadata), do: :ok

  @impl Ash.Tracer
  def set_error(_error), do: :ok

  @impl Ash.Tracer
  def trace_type?(:action), do: true
  def trace_type?(_), do: false

  @impl Ash.Tracer
  def set_handled_error(error, _opts) when is_exception(error) do
    if forbidden?(error) do
      maybe_emit_denial(error)
    else
      :ok
    end

    # tracer callback must never raise back into Ash's action pipeline
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  end

  def set_handled_error(_error, _opts), do: :ok

  # The propagation fence (see moduledoc): a frame at the same or an older
  # generation than the last-emitting one is an already-audited denial
  # unwinding through its enclosing spans — suppressed without touching the
  # frame's metadata, so a genuinely new denial under this frame (a second
  # caught sibling child, at a newer generation) can still emit. Only
  # `:emitted` (writer task spawned) sets the marker; a skipped or failed
  # emit leaves the enclosing frames free to attempt their own audit.
  defp maybe_emit_denial(error) do
    case current_metadata() do
      nil -> :ok
      metadata -> emit_with_fence(metadata, error, Map.get(metadata, @generation_field))
    end
  end

  defp emit_with_fence(metadata, error, generation) when is_integer(generation) do
    emitted = Process.get(@emitted_error_key)

    if is_integer(emitted) and generation <= emitted do
      :ok
    else
      case emit_denial(metadata, error) do
        :emitted -> Process.put(@emitted_error_key, generation)
        _skipped_or_failed -> :ok
      end

      :ok
    end
  end

  defp emit_with_fence(metadata, error, _no_generation) do
    # Generation-less frame (direct set_metadata outside a span wrapper):
    # keep the legacy clear-once suppression.
    case emit_denial(metadata, error) do
      :emitted -> clear_current_metadata()
      _skipped_or_failed -> :ok
    end

    :ok
  end

  defp metadata_stack do
    case Process.get(@process_key, []) do
      stack when is_list(stack) -> stack
      metadata when is_map(metadata) -> [metadata]
      _other -> []
    end
  end

  # Real action metadata always carries `:action` (the set_metadata guard);
  # a frame holding only its generation means no metadata was captured yet.
  defp current_metadata do
    case metadata_stack() do
      [%{action: _} = metadata | _parent_spans] -> metadata
      _other -> nil
    end
  end

  defp clear_current_metadata do
    case metadata_stack() do
      [_metadata | parent_spans] -> Process.put(@process_key, [nil | parent_spans])
      [] -> Process.delete(@process_key)
    end
  end

  # Ash dispatches `set_handled_error/2` after running the error through
  # `Ash.Error.to_error_class/1`, so a policy denial always arrives as
  # `Ash.Error.Forbidden`. Match on the class struct.
  defp forbidden?(%Ash.Error.Forbidden{}), do: true
  defp forbidden?(_), do: false

  # `:emitted` means the writer task was SPAWNED — not that the audit row
  # persisted (the async write can still fail downstream).
  defp emit_denial(metadata, error) do
    tenant_id = extract_tenant(metadata)

    case tenant_id do
      nil ->
        # Without a tenant we cannot persist the row (multitenancy is
        # strict). Drop with telemetry so the gap is observable.
        :telemetry.execute(
          [:jido_claw, :audit, :policy_denied, :skipped],
          %{},
          %{
            reason: :no_tenant,
            resource: metadata[:resource],
            action: metadata[:action]
          }
        )

        :skipped

      tenant_id ->
        {actor_kind, actor_id} = ActorClassifier.classify(metadata[:actor])

        attrs =
          EventAttrs.new(
            tenant_id: tenant_id,
            event_kind: :policy_denied,
            actor_kind: actor_kind,
            actor_id: actor_id,
            target_kind: target_kind_for(metadata[:resource]),
            target_id: nil,
            payload: build_payload(metadata, error)
          )

        case AsyncWriter.enqueue(attrs) do
          {:ok, _pid} -> :emitted
          {:error, _reason} -> :failed
        end
    end
  end

  # Prefer the actor's tenant over the action tenant: a cross-tenant
  # denial — "user from T1 tried to touch T2's data" — belongs in T1's
  # audit log (the attempt was theirs), not T2's. If the actor has no
  # tenant_id, fall back to the action tenant so non-cross-tenant
  # denials are still captured.
  defp extract_tenant(metadata) do
    case tenant_from_actor(Map.get(metadata, :actor)) do
      nil ->
        case Map.get(metadata, :tenant) do
          tenant when is_binary(tenant) and tenant != "" -> tenant
          _ -> nil
        end

      tenant ->
        tenant
    end
  end

  # A bare `%JidoClaw.Accounts.User{}` (passed directly as `:actor`,
  # rather than via `Authorization.Actor.build/1`) has no `:tenant_id`
  # field. The canonical user→tenant rule (`Authorization.Actor`) is
  # `tenant_id == to_string(user.id)` — derive it the same way here so
  # the row lands in the actor's tenant, not the action target's.
  defp tenant_from_actor(%JidoClaw.Accounts.User{id: id}) when not is_nil(id) do
    to_string(id)
  end

  defp tenant_from_actor(actor) when is_map(actor) do
    case MapKeys.coalesce_field(actor, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" -> tenant
      _ -> nil
    end
  end

  defp tenant_from_actor(_), do: nil

  defp target_kind_for(nil), do: nil
  defp target_kind_for(resource), do: Map.get(@resource_target_kinds, resource)

  defp build_payload(metadata, error) do
    %{
      resource: inspect(metadata[:resource]),
      action: stringify(metadata[:action]),
      authorize: metadata[:authorize?],
      reason: reason_summary(error)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify(nil), do: nil
  defp stringify(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify(bin) when is_binary(bin), do: bin
  defp stringify(other), do: inspect(other)

  defp reason_summary(%Ash.Error.Forbidden{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&error_summary/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "forbidden"
      list -> Enum.join(list, "; ")
    end
  end

  defp reason_summary(%{__struct__: _} = error) do
    if function_exported?(Exception, :message, 1) do
      try do
        Exception.message(error)
      rescue
        _ in [Protocol.UndefinedError, FunctionClauseError, ArgumentError] -> "forbidden"
      end
    else
      "forbidden"
    end
  end

  defp reason_summary(_), do: "forbidden"

  defp error_summary(%{__struct__: struct} = err) do
    msg =
      try do
        Exception.message(err)
      rescue
        _ in [Protocol.UndefinedError, FunctionClauseError, ArgumentError] -> nil
      end

    "#{inspect(struct)}#{if msg, do: ": " <> String.slice(msg, 0, 200), else: ""}"
  end

  defp error_summary(_), do: nil
end
