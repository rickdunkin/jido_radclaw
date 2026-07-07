defmodule JidoClaw.ClusterCase do
  @moduledoc """
  Case template for the WS6 multi-node cluster suite (`@moduletag :cluster`,
  excluded by default — `scripts/test-cluster.sh` is the entry point).

  `setup_all` boots two real `:peer` BEAM nodes running the full app against
  the shared `jido_claw_cluster_test` DB on a REGULAR pool — the Ecto SQL
  sandbox cannot span BEAMs — so it refuses to run unless
  `JIDOCLAW_CLUSTER_TEST=1`. The flag and `--only cluster` must travel
  together (the script pairs them): the flag alone breaks every sandbox test,
  the tag alone would race peers against a sandbox pool.

  Peers live for the whole module; each test starts from a truncated DB plus a
  fresh tenant/actor (`ctx` carries the `%{tenant:, actor:}` shape the
  `LeaseHelpers` seeders take). Cross-node assertions poll the shared DB or
  `:erpc` into a peer (`call/4`/`call/5`, `await/2`) — telemetry and PubSub
  are node-local and never cross BEAMs.
  """

  use ExUnit.CaseTemplate

  alias JidoClaw.Cluster.PeerHarness
  alias JidoClaw.Repo
  alias JidoClaw.TenantCase

  using opts do
    # Captured at expansion so the use-site's `peer_overrides:` reaches the
    # module-lifetime peer boot; the CaseTemplate proxy forwards only
    # `ExUnit.Case.__keys__` to ExUnit.Case, so the custom key is warning-free.
    overrides = Keyword.get(opts, :peer_overrides, [])

    quote do
      import JidoClaw.Cluster.PeerHarness, only: [await: 2, call: 4, call: 5]

      import JidoClaw.Orchestration.LeaseHelpers,
        only: [backdate_inserted!: 2, kinds: 2, reload_global: 1, seed_run: 1, seed_run: 2]

      alias JidoClaw.Orchestration.ReclaimPooler
      alias JidoClaw.Orchestration.WorkflowLease
      alias JidoClaw.Orchestration.WorkflowRun

      @moduletag :cluster
      @moduletag timeout: 120_000

      setup_all do
        JidoClaw.ClusterCase.boot_peers!(unquote(Macro.escape(overrides)))
      end
    end
  end

  @doc """
  The module-lifetime peer boot behind every cluster module's `setup_all` —
  in the `using` quote (not the template body) so use-site `peer_overrides:`
  reach `PeerHarness.start_peers/2`. Overrides are per-peer `:jido_claw`
  app-env replacements, WHOLE-KEY (e.g. a `workflow_lease:` override must set
  all three lease keys). Returns the `%{peers:, nodes:, node_a:, node_b:}`
  context; registers the peer teardown via `on_exit`.
  """
  @spec boot_peers!(keyword()) :: map()
  def boot_peers!(overrides) do
    ensure_cluster_env!()
    PeerHarness.ensure_distribution!()
    peers = PeerHarness.start_peers(2, overrides: overrides)
    on_exit(fn -> PeerHarness.stop_peers(peers) end)

    [node_a, node_b] = nodes = Enum.map(peers, & &1.node)
    %{peers: peers, nodes: nodes, node_a: node_a, node_b: node_b}
  end

  setup do
    truncate_all!()
    tenant = TenantCase.seed_tenant("cluster")
    actor = TenantCase.actor_for(tenant)
    %{tenant: tenant, actor: actor, ctx: %{tenant: tenant, actor: actor}}
  end

  @doc """
  TRUNCATE every public table except `schema_migrations` (RESTART IDENTITY
  CASCADE) — the per-test clean slate, run BEFORE each test so state is clean
  even after a crashed predecessor. One statement on the test node's Repo
  clears the shared DB for every node. Boot-created system/default tenant rows
  die at the first truncation — inert for the lease proofs (the claim path is
  tenant-bypassed DB work, and each test seeds its own tenant).
  """
  @spec truncate_all!() :: :ok
  def truncate_all! do
    %{rows: rows} =
      Repo.query!(
        "SELECT tablename FROM pg_tables " <>
          "WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      )

    case Enum.map(rows, fn [table] -> ~s("public"."#{table}") end) do
      [] ->
        :ok

      tables ->
        # TRUNCATE takes identifiers, which Postgres cannot parameterize; the
        # names come from pg_tables on our own DB and are quoted above.
        # reach:disable-next-line ecto_interpolated_repo_query
        Repo.query!("TRUNCATE #{Enum.join(tables, ", ")} RESTART IDENTITY CASCADE")
        :ok
    end
  end

  defp ensure_cluster_env! do
    if System.get_env("JIDOCLAW_CLUSTER_TEST") == "1" do
      :ok
    else
      raise """
      The :cluster suite needs JIDOCLAW_CLUSTER_TEST=1 — run it via
      scripts/test-cluster.sh (it exports the flag and passes --only cluster).

      Without the flag the Repo is on the Ecto SQL sandbox pool, which cannot
      be shared across BEAMs — the peers would race sandbox ownership.
      """
    end
  end
end
