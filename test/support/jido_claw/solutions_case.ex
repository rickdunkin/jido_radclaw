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
  """

  use ExUnit.CaseTemplate

  alias JidoClaw.Solutions.Solution
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
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Return a unique tenant id (string) for this test run.
  """
  def unique_tenant_id, do: "tenant-#{System.unique_integer([:positive])}"

  @doc """
  Insert a workspace under `tenant_id` with the given `embedding_policy`.
  Returns the persisted struct.
  """
  def workspace_fixture(tenant_id, opts \\ []) do
    name = Keyword.get(opts, :name, "ws-#{System.unique_integer([:positive])}")
    path = Keyword.get(opts, :path, "/tmp/#{name}")
    policy = Keyword.get(opts, :embedding_policy, :disabled)

    {:ok, ws} =
      Workspace.register(%{
        tenant_id: tenant_id,
        path: path,
        name: name,
        embedding_policy: policy
      })

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
    * `:embedding_model`, `:embedding` — inject pre-computed vectors
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
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      embedding_status: Keyword.get(opts, :embedding_status, :disabled),
      embedding_model: Keyword.get(opts, :embedding_model),
      tags: Keyword.get(opts, :tags, []),
      verification: Keyword.get(opts, :verification, %{}),
      trust_score: Keyword.get(opts, :trust_score, 0.0)
    }

    {:ok, sol} = Solution.store(attrs)
    sol
  end
end
