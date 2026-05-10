defmodule JidoClaw.Audit.Producers do
  @moduledoc """
  Inline `Ash.Resource.Change` modules wired into producer actions
  via `change` blocks. Each producer fires
  `JidoClaw.Audit.AsyncWriter.sync/1` from the action's
  `after_action` hook so the audit row commits in the same
  transaction as the producer.

  Module organization mirrors the `event_kind` namespace:
  `MemoryWrite`, `MemoryConsolidation`, `SolutionShare`,
  `SessionStart`, `SessionEnd`. Each accepts an `event_kind`
  /`target_kind` opt where the producer can serve more than one
  event_kind at once.
  """

  alias JidoClaw.Audit.AsyncWriter

  defmodule MemoryWrite do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, opts, _context) do
      target_kind = Keyword.get(opts, :target_kind, :memory_fact)
      event_kind = Keyword.get(opts, :event_kind, :memory_write)

      Ash.Changeset.after_action(changeset, fn cs, result ->
        try do
          tenant_id = cs.tenant || Map.get(result, :tenant_id)

          actor_kind =
            if Map.get(result, :source) == :user_save, do: :user, else: :agent

          actor_id = field(result, :written_by) || field(result, :written_by_user_id)

          AsyncWriter.sync(%{
            tenant_id: tenant_id,
            event_kind: event_kind,
            actor_kind: actor_kind,
            actor_id: actor_id && to_string(actor_id),
            target_kind: target_kind,
            target_id: result.id && to_string(result.id),
            payload: build_payload(result)
          })
        rescue
          _ -> :ok
        end

        {:ok, result}
      end)
    end

    defp build_payload(result) do
      payload = %{}

      payload =
        if source = field(result, :source),
          do: Map.put(payload, :source, source),
          else: payload

      payload =
        if scope = field(result, :scope_kind),
          do: Map.put(payload, :scope_kind, scope),
          else: payload

      payload =
        if label = field(result, :label),
          do: Map.put(payload, :label, label),
          else: payload

      payload =
        if relation = field(result, :relation),
          do: Map.put(payload, :relation, relation),
          else: payload

      payload
    end

    defp field(map, key) when is_map(map), do: Map.get(map, key)
    defp field(_, _), do: nil
  end

  defmodule MemoryConsolidation do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_action(changeset, fn cs, result ->
        try do
          tenant_id = cs.tenant || Map.get(result, :tenant_id)

          if Map.get(result, :status) in [:succeeded, :failed, :skipped] do
            AsyncWriter.sync(%{
              tenant_id: tenant_id,
              event_kind: :memory_consolidation,
              actor_kind: :system,
              actor_id: "consolidator",
              target_kind: :memory_consolidation_run,
              target_id: result.id && to_string(result.id),
              payload: %{
                status: result.status,
                scope_kind: result.scope_kind,
                facts_added: result.facts_added,
                blocks_written: result.blocks_written,
                links_added: result.links_added
              }
            })
          end
        rescue
          _ -> :ok
        end

        {:ok, result}
      end)
    end
  end

  defmodule SolutionShare do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_action(changeset, fn cs, result ->
        try do
          if Map.get(result, :sharing) in [:shared, :public] do
            tenant_id = cs.tenant || Map.get(result, :tenant_id)

            AsyncWriter.sync(%{
              tenant_id: tenant_id,
              event_kind: :solution_share,
              actor_kind: :agent,
              actor_id: result.agent_id,
              target_kind: :solution,
              target_id: result.id && to_string(result.id),
              payload: %{
                problem_signature: result.problem_signature,
                sharing: result.sharing,
                language: result.language,
                framework: result.framework,
                workspace_id: result.workspace_id && to_string(result.workspace_id)
              }
            })
          end
        rescue
          _ -> :ok
        end

        {:ok, result}
      end)
    end
  end

  defmodule SessionStart do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_action(changeset, fn cs, result ->
        try do
          tenant_id = cs.tenant || Map.get(result, :tenant_id)

          AsyncWriter.sync(%{
            tenant_id: tenant_id,
            event_kind: :session_start,
            actor_kind: :system,
            actor_id: result.user_id && to_string(result.user_id),
            target_kind: :session,
            target_id: result.id && to_string(result.id),
            payload: %{
              kind: result.kind,
              workspace_id: result.workspace_id && to_string(result.workspace_id),
              external_id: result.external_id
            }
          })
        rescue
          _ -> :ok
        end

        {:ok, result}
      end)
    end
  end

  defmodule SessionEnd do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_action(changeset, fn cs, result ->
        try do
          tenant_id = cs.tenant || Map.get(result, :tenant_id)

          AsyncWriter.sync(%{
            tenant_id: tenant_id,
            event_kind: :session_end,
            actor_kind: :system,
            actor_id: result.user_id && to_string(result.user_id),
            target_kind: :session,
            target_id: result.id && to_string(result.id),
            payload: %{
              kind: result.kind,
              workspace_id: result.workspace_id && to_string(result.workspace_id)
            }
          })
        rescue
          _ -> :ok
        end

        {:ok, result}
      end)
    end
  end
end
