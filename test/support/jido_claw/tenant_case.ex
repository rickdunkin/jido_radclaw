defmodule JidoClaw.TenantCase do
  @moduledoc """
  Shared test helpers for the v0.6.4 multitenancy contract.

  Every tenant-scoped resource uses Ash `:attribute` multitenancy with
  `global? false`. That means three rules apply at every call site:

    1. `JidoClaw.Tenants.Tenant.ensure(tenant_id)` must run first so the
       FK parent row exists.
    2. The tenant id is threaded via the `tenant:` opt on the action
       call, never embedded in the attrs map.
    3. `tenant_id` is dropped from attrs.

  The seed helpers below encode that contract once. Tests should
  `use JidoClaw.TenantCase` (or `import` it from inside another case
  template) and call the helpers instead of hand-rolling each fixture.

  Sandbox setup mirrors `JidoClaw.SolutionsCase` — shared mode is the
  default so spawned workers (BackfillWorker, Matcher, etc.) can see
  seeded rows. Tag the test with `async: true` to opt out.
  """

  use ExUnit.CaseTemplate

  alias JidoClaw.Conversations.Session
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  using do
    quote do
      import JidoClaw.TenantCase

      alias JidoClaw.Conversations.Session
      alias JidoClaw.Tenants.Tenant
      alias JidoClaw.Workspaces.Workspace
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: not tags[:async])

    on_exit(fn ->
      JidoClaw.Audit.AsyncWriter.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  @doc """
  Return a unique tenant id string for a test fixture.
  """
  @spec unique_tenant_id() :: String.t()
  def unique_tenant_id, do: "tenant-#{System.unique_integer([:positive])}"

  @doc """
  Return a unique tenant id string with a label prefix so the row is
  easy to spot in DB dumps when a test wedges.
  """
  @spec unique_tenant_id(String.t() | atom()) :: String.t()
  def unique_tenant_id(label) do
    "tenant-#{label}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Insert (or no-op on existing) a `Tenants.Tenant` row and return its id.
  Pass an optional label that is woven into the generated id to make the
  row easy to spot.
  """
  @spec seed_tenant() :: String.t()
  @spec seed_tenant(String.t() | atom() | nil) :: String.t()
  def seed_tenant(label \\ nil) do
    tenant_id = if label, do: unique_tenant_id(label), else: unique_tenant_id()
    {:ok, _} = Tenant.ensure(tenant_id)
    tenant_id
  end

  @doc """
  Build a tenant-bound actor map matching the production user→tenant
  rule (`tenant_id == to_string(user.id)`). Defaults to a shape that
  satisfies the standard `tenant_id == ^actor(:tenant_id)` policy.
  """
  @spec actor_for(String.t()) :: %{user_id: String.t(), tenant_id: String.t()}
  def actor_for(tenant_id) when is_binary(tenant_id) do
    %{user_id: tenant_id, tenant_id: tenant_id}
  end

  @doc """
  Register a workspace under `tenant_id` via `Workspace.register/2`.
  Threads the tenant via the `tenant:` opt; `path` and `name` default
  to unique values when not supplied. The `:actor` opt, when supplied,
  is forwarded so policy-enabled tests pass tenant-actor checks; when
  absent, defaults to `actor_for(tenant_id)`.
  """
  @spec seed_workspace(String.t(), keyword()) :: {:ok, Workspace.t()} | {:error, term()}
  def seed_workspace(tenant_id, opts \\ []) do
    name = Keyword.get(opts, :name, "ws-#{System.unique_integer([:positive])}")
    path = Keyword.get(opts, :path, "/tmp/#{name}")
    actor = Keyword.get(opts, :actor, actor_for(tenant_id))

    attrs =
      opts
      |> Keyword.drop([:name, :path, :actor])
      |> Map.new()
      |> Map.put(:name, name)
      |> Map.put(:path, path)

    Workspace.register(attrs, tenant: tenant_id, actor: actor)
  end

  @doc """
  Start a session under `tenant_id` for the supplied `workspace_id`.
  `kind`, `external_id`, and `started_at` default to sensible test
  values; pass `opts` to override. Threads `:actor` like
  `seed_workspace/2`.
  """
  @spec seed_session(String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def seed_session(tenant_id, workspace_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, actor_for(tenant_id))

    attrs =
      opts
      |> Keyword.drop([:actor])
      |> Map.new()
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put_new(:kind, :api)
      |> Map.put_new(
        :external_id,
        "ext-#{System.unique_integer([:positive])}"
      )
      |> Map.put_new(:started_at, DateTime.utc_now())

    Session.start(attrs, tenant: tenant_id, actor: actor)
  end

  @doc """
  Convenience builder that seeds a tenant, workspace, and session in one
  call. Returns `%{tenant_id, workspace, session}`.

  Options:

    * `:tenant_label` — label for the generated tenant id (default
      `"full"`).
    * `:workspace` — keyword opts forwarded to `seed_workspace/2`.
    * `:session` — keyword opts forwarded to `seed_session/3`.
  """
  @spec seed_full(keyword()) :: %{
          tenant_id: String.t(),
          workspace: Workspace.t(),
          session: Session.t()
        }
  def seed_full(opts \\ []) do
    label = Keyword.get(opts, :tenant_label, "full")
    workspace_opts = Keyword.get(opts, :workspace, [])
    session_opts = Keyword.get(opts, :session, [])

    tenant_id = seed_tenant(label)
    {:ok, workspace} = seed_workspace(tenant_id, workspace_opts)
    {:ok, session} = seed_session(tenant_id, workspace.id, session_opts)

    %{tenant_id: tenant_id, workspace: workspace, session: session}
  end
end
