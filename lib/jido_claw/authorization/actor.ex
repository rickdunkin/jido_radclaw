defmodule JidoClaw.Authorization.Actor do
  @moduledoc """
  Builds the canonical actor map for Ash authorization.

  Three shapes:

    * `build/1` from a `JidoClaw.Accounts.User` — derives `tenant_id`
      via `to_string(user.id)`. This rule is consolidated here so every
      surface (web plugs, sockets, REPL, tests, fixtures) uses the same
      derivation.
    * `build(nil)` returns `nil` — used by paths that haven't resolved
      a user yet (auth-failure path, public reads).
    * `system/1` builds a tenant-bound system actor — used by internal
      infrastructure (Cron.Worker, sweepers, MCP default-scope
      initializer, REPL, channel adapters). The standard policy is
      `tenant_id == ^actor(:tenant_id)`, so the actor MUST carry a
      `tenant_id` matching the row being acted on. A `tenant_id: nil`
      system actor is denied by every standard policy — never use it.
  """

  @type actor :: %{user_id: String.t() | nil, tenant_id: String.t()} | nil

  @spec build(map() | nil) :: actor()
  def build(%JidoClaw.Accounts.User{} = user) do
    %{user_id: user.id, tenant_id: to_string(user.id)}
  end

  def build(nil), do: nil

  @spec system(String.t()) :: actor()
  def system(tenant_id) when is_binary(tenant_id) do
    %{kind: :system, user_id: nil, tenant_id: tenant_id}
  end
end
