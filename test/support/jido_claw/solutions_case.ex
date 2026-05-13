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

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.UUID
  alias JidoClaw.Audit.AsyncWriter
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
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: not tags[:async])

    on_exit(fn ->
      AsyncWriter.flush()
      Sandbox.stop_owner(pid)
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

  @doc """
  Insert `count` rows directly into `solutions` via `Repo.insert_all`,
  bypassing the Ash pipeline. Used by tests that need a large fixture
  table to give the Postgres planner a real choice between index and
  sequential scan.

  The `builder` callback receives the 1-based row index and must return
  a map of column values. Required keys: `:solution_content`,
  `:problem_signature`. Optional keys mirror the table's defaults
  (`:language`, `:framework`, `:sharing`, `:embedding_status`,
  `:trust_score`, `:tags`).

  Notes:

    * UUIDs are dumped to binaries via `Ecto.UUID.dump!/1` because
      `Repo.insert_all` doesn't run Ecto's type casters the way
      `Repo.insert` does.
    * Enums (`sharing`, `embedding_status`) are written as the text
      representation that Postgres expects.
    * `inserted_at` / `updated_at` are supplied as `%DateTime{}` —
      `insert_all` does not auto-populate them.
  """
  def bulk_insert_solutions(tenant_id, workspace_id, count, builder)
      when is_binary(tenant_id) and is_integer(count) and is_function(builder, 1) do
    workspace_uuid = UUID.dump!(workspace_id)
    now = DateTime.utc_now()

    # 15 params per row * 4000 rows = 60_000 params, under the 65_535
    # Postgres protocol limit for parameter count.
    chunk_size = 4_000

    1..count
    |> Stream.chunk_every(chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      rows =
        Enum.map(chunk, fn i ->
          attrs = builder.(i)

          %{
            id: UUID.dump!(UUID.generate()),
            problem_signature: Map.fetch!(attrs, :problem_signature),
            solution_content: Map.fetch!(attrs, :solution_content),
            language: Map.get(attrs, :language, "elixir"),
            framework: Map.get(attrs, :framework),
            tags: Map.get(attrs, :tags, []),
            verification: Map.get(attrs, :verification, %{}),
            trust_score: Map.get(attrs, :trust_score, 0.0),
            sharing: Map.get(attrs, :sharing, "local"),
            workspace_id: workspace_uuid,
            tenant_id: tenant_id,
            embedding_status: Map.get(attrs, :embedding_status, "disabled"),
            embedding_attempt_count: 0,
            inserted_at: now,
            updated_at: now
          }
        end)

      {inserted, _} = JidoClaw.Repo.insert_all("solutions", rows)
      acc + inserted
    end)
  end
end
