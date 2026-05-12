defmodule JidoClaw.Audit.ActorClassifier do
  @moduledoc """
  Maps an Ash actor (canonical map from `JidoClaw.Authorization.Actor`,
  a `%JidoClaw.Accounts.User{}`, or `nil`) to the `actor_kind` /
  `actor_id` pair stored on `JidoClaw.Audit.Event`.

  Rules, in priority order:
    1. `kind: :system` (or `"system"`) → `{:system, nil}`
    2. non-nil `agent_id` → `{:agent, agent_id}`
    3. non-nil `user_id`  → `{:user,  user_id}`
    4. `kind: :user`  (or `"user"`)  + non-nil `id` → `{:user,  id}`
       `kind: :agent` (or `"agent"`) + non-nil `id` → `{:agent, id}`
    5. otherwise → `{:system, nil}` (unidentifiable actor, e.g. nil
       or a bare `%{id: …}` map with no `kind`/`*_id` field)

  Rule 4 is **deliberately narrow**: it requires an explicit `kind`
  alongside the `id` field. A bare `%{id: "abc"}` falls through to
  rule 5 — we do not infer `:user` from `:id` alone, because some
  boundaries pass `%Some.Other.Struct{}` shapes where `id` is not a
  user/agent identifier.

  The "non-nil id required" rule prevents canonical system actors —
  `%{kind: :system, user_id: nil, tenant_id: …}` — from being
  misclassified as `:user` purely because the key is present.
  """

  alias JidoClaw.Core.MapKeys

  @type kind :: :user | :agent | :system

  @spec classify(map() | struct() | nil) :: {kind(), String.t() | nil}
  def classify(nil), do: {:system, nil}

  def classify(%JidoClaw.Accounts.User{id: id}) when not is_nil(id) do
    {:user, to_string(id)}
  end

  def classify(actor) when is_map(actor) do
    cond do
      system_kind?(actor) ->
        {:system, nil}

      id = non_nil_field(actor, :agent_id) ->
        {:agent, to_string(id)}

      id = non_nil_field(actor, :user_id) ->
        {:user, to_string(id)}

      true ->
        classify_by_kind(actor)
    end
  end

  def classify(_), do: {:system, nil}

  defp system_kind?(actor) do
    case MapKeys.coalesce_field(actor, :kind) do
      :system -> true
      "system" -> true
      _ -> false
    end
  end

  defp non_nil_field(actor, key) do
    case MapKeys.coalesce_field(actor, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp classify_by_kind(actor) do
    kind = MapKeys.coalesce_field(actor, :kind)
    id = non_nil_field(actor, :id)

    case {kind, id} do
      {:user, id} when not is_nil(id) -> {:user, to_string(id)}
      {"user", id} when not is_nil(id) -> {:user, to_string(id)}
      {:agent, id} when not is_nil(id) -> {:agent, to_string(id)}
      {"agent", id} when not is_nil(id) -> {:agent, to_string(id)}
      _ -> {:system, nil}
    end
  end
end
