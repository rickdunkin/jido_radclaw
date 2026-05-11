defmodule JidoClaw.SolutionsCase do
  @moduledoc """
  Test case helper for tests that drive the Solutions resource +
  hybrid retrieval + embedding policy paths.

  Wraps `Ecto.Adapters.SQL.Sandbox` checkout (with shared mode so the
  BackfillWorker / Matcher / NetworkFacade can see seeded rows from
  spawned processes) and exposes seeding helpers for the tenant +
  workspace + solution fixtures every test in Patch 1 needs.

  Tests that require Postgres-side `pgvector` and `pg_trgm` need both
  extensions installed (`CREATE EXTENSION` is run by the `ash.setup`
  alias) — see AGENTS.md for the prerequisite Homebrew step.

  ## v0.6.4 multitenancy contract

  Workspace and Solution rows scope by `:attribute` multitenancy with
  `global? false`. Fixtures here:

    1. call `Tenants.Tenant.ensure/1` first so the FK parent row exists,
    2. thread `tenant: tenant_id` via the action opt rather than embed
       it in attrs, and
    3. omit `tenant_id` from the attrs map.
  """

  use ExUnit.CaseTemplate

  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  using do
    quote do
      import JidoClaw.SolutionsCase

      alias JidoClaw.Solutions.Solution
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
  Return a unique tenant id (string) for this test run.
  """
  def unique_tenant_id, do: "tenant-#{System.unique_integer([:positive])}"

  @doc """
  Build a tenant-bound actor map matching the production user→tenant
  rule (`tenant_id == to_string(user.id)`). Mirrors
  `JidoClaw.TenantCase.actor_for/1`.
  """
  @spec actor_for(String.t()) :: %{user_id: String.t(), tenant_id: String.t()}
  def actor_for(tenant_id) when is_binary(tenant_id) do
    %{user_id: tenant_id, tenant_id: tenant_id}
  end

  @doc """
  Insert a workspace under `tenant_id` with the given `embedding_policy`.
  Threads tenant via opt; ensures the parent `Tenant` row exists first.
  Returns the persisted struct. The `:actor` opt defaults to
  `actor_for(tenant_id)` so policy-enabled tests pass tenant-actor
  checks.
  """
  def workspace_fixture(tenant_id, opts \\ []) do
    {:ok, _} = Tenant.ensure(tenant_id)

    name = Keyword.get(opts, :name, "ws-#{System.unique_integer([:positive])}")
    path = Keyword.get(opts, :path, "/tmp/#{name}")
    policy = Keyword.get(opts, :embedding_policy, :disabled)
    actor = Keyword.get(opts, :actor, actor_for(tenant_id))

    {:ok, ws} =
      Workspace.register(
        %{
          path: path,
          name: name,
          embedding_policy: policy
        },
        tenant: tenant_id,
        actor: actor
      )

    ws
  end

  @doc """
  Insert a solution row directly under `tenant_id` + `workspace_id`,
  bypassing redaction so the lexical_text generated column receives the
  exact content under test. The `:problem_signature` defaults to a
  unique value so callers don't collide on the by_signature uniqueness
  rule.

  Optional keys:

    * `:problem_signature` — bypass the unique-default
    * `:sharing` — `:local | :shared | :public`, default `:local`
    * `:language` / `:framework` — default `"elixir"` / `nil`
    * `:embedding_status` — default `:disabled` (no Voyage egress
      needed in regression tests; matcher tests explicitly opt in)
    * `:embedding` — inject a pre-computed vector
  """
  def solution_fixture(tenant_id, workspace_id, content, opts \\ []) do
    sig =
      Keyword.get(
        opts,
        :problem_signature,
        :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}-#{content}")
        |> Base.encode16(case: :lower)
      )

    attrs = %{
      problem_signature: sig,
      solution_content: content,
      language: Keyword.get(opts, :language, "elixir"),
      framework: Keyword.get(opts, :framework),
      sharing: Keyword.get(opts, :sharing, :local),
      workspace_id: workspace_id,
      embedding_status: Keyword.get(opts, :embedding_status, :disabled),
      tags: Keyword.get(opts, :tags, []),
      verification: Keyword.get(opts, :verification, %{}),
      trust_score: Keyword.get(opts, :trust_score, 0.0)
    }

    attrs =
      case Keyword.get(opts, :embedding) do
        nil -> attrs
        emb -> Map.put(attrs, :embedding, emb)
      end

    actor = Keyword.get(opts, :actor, actor_for(tenant_id))

    {:ok, sol} = Solution.store(attrs, tenant: tenant_id, actor: actor)
    sol
  end
end
