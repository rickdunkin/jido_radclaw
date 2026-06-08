defmodule JidoClaw.Audit.AshTracer do
  @moduledoc """
  `Ash.Tracer` implementation that emits a `:policy_denied` audit row
  whenever an Ash action is rejected by the policy authorizer.

  Wiring: `config :ash, :tracer, [JidoClaw.Audit.AshTracer, ...]`. The
  tracer captures per-span metadata (resource, action, actor, tenant)
  via `set_metadata/2` and stashes it in the process dictionary. When
  Ash signals a handled error through `set_handled_error/2` and the
  error class is `Ash.Error.Forbidden`, it emits an `Audit.Event` via
  `AsyncWriter.cast/1` so the denial is captured without adding write
  latency to the rejected request.

  Only `:action` span metadata is captured — sub-spans (`:changeset`,
  `:query`, `:change`, etc.) flow through the same callbacks but are
  ignored so a denial inside an action surfaces once at the action
  boundary rather than once per nested span.
  """

  @behaviour Ash.Tracer

  alias JidoClaw.Audit.ActorClassifier
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Audit.EventAttrs
  alias JidoClaw.Core.MapKeys

  @process_key :jido_claw_audit_tracer_metadata
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

  @impl true
  def start_span(_type, _name), do: :ok

  @impl true
  def stop_span do
    Process.delete(@process_key)
    :ok
  end

  @impl true
  def get_span_context, do: nil

  @impl true
  def set_span_context(_context), do: :ok

  # Ash dispatches `set_metadata(tracer, :action, meta)` from inside
  # calculation/aggregate spans too (deps/ash/lib/ash/actions/read/
  # calculations.ex:627, deps/ash/lib/ash/actions/aggregate.ex:82),
  # where the metadata carries a `:calculation` / `:aggregates` key
  # but **no** `:action` key. Storing those payloads would clobber
  # the real action metadata captured by the outer action span and
  # leave the next `set_handled_error` with no action to attribute
  # the denial to. Require the action key to discriminate.
  @impl true
  def set_metadata(:action, %{action: _} = metadata) do
    Process.put(@process_key, metadata)
    :ok
  end

  def set_metadata(_type, _metadata), do: :ok

  @impl true
  def set_error(_error), do: :ok

  @impl true
  def trace_type?(:action), do: true
  def trace_type?(_), do: false

  @impl true
  def set_handled_error(error, _opts) when is_exception(error) do
    if forbidden?(error) do
      case Process.get(@process_key) do
        nil ->
          :ok

        metadata ->
          # An action can emit several handled errors (e.g., during retry
          # in a transaction). Clear the metadata once we've audited a
          # denial so we don't double-emit on follow-on errors.
          Process.delete(@process_key)
          emit_denial(metadata, error)
      end
    else
      :ok
    end

    # tracer callback must never raise back into Ash's action pipeline
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  end

  def set_handled_error(_error, _opts), do: :ok

  # Ash dispatches `set_handled_error/2` after running the error through
  # `Ash.Error.to_error_class/1`, so a policy denial always arrives as
  # `Ash.Error.Forbidden`. Match on the class struct.
  defp forbidden?(%Ash.Error.Forbidden{}), do: true
  defp forbidden?(_), do: false

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

        :ok

      tenant_id ->
        {actor_kind, actor_id} = ActorClassifier.classify(metadata[:actor])

        AsyncWriter.cast(
          EventAttrs.new(
            tenant_id: tenant_id,
            event_kind: :policy_denied,
            actor_kind: actor_kind,
            actor_id: actor_id,
            target_kind: target_kind_for(metadata[:resource]),
            target_id: nil,
            payload: build_payload(metadata, error)
          )
        )
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
