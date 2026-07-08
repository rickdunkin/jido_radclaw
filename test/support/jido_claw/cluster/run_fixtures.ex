defmodule JidoClaw.Cluster.RunFixtures do
  @moduledoc """
  Peer-side run launchers for the WS6 cluster proofs — invoked ON A PEER via
  `PeerHarness.call/5` as named MFAs (never ship anonymous funs across nodes).
  On the peer code path automatically: `elixirc_paths(:test)` includes
  `test/support`, and peers get the origin's code paths at boot.

  No ExUnit here (plain `receive`, tagged returns): peers run the app, not the
  test framework. Launchers use `spawn/1` UNLINKED so the launched run
  survives the transient `:erpc` server process that called us.
  """

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.BlockingTestReactor
  alias JidoClaw.Orchestration.Reactors.GatedTestReactor
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.TestFixtures

  @doc """
  Launch a forever-blocking leased run via the full runner path (lease
  stamped, sidecar renewing) and return once the mid-execution state is
  DURABLE: `BlockStep` signals `{:blocking_step_started, pid, run_id}` only
  after `ReactorMiddleware` synchronously appended `step_started`. The block
  never releases — every Phase 2 proof ends it via node death, fence-kill, or
  reclaim.
  """
  @spec launch_blocking(%{tenant: String.t(), actor: map()}) ::
          {:ok, String.t()} | {:error, :timeout}
  def launch_blocking(%{tenant: tenant, actor: actor}) do
    parent = self()

    spawn(fn ->
      ReactorRunner.run(BlockingTestReactor, %{},
        tenant: tenant,
        actor: actor,
        context: %{test_pid: parent}
      )
    end)

    receive do
      {:blocking_step_started, _executor, run_id} -> {:ok, run_id}
    after
      30_000 -> {:error, :timeout}
    end
  end

  @doc """
  Launch a SUPERVISED route composer on one of the WS6 cluster catalogs
  (Proofs 5/6). Synchronous DB genesis (`create_parent_run/1` — leased at
  genesis, catalog persisted in config so a reclaiming peer can rebuild it)
  then `ensure_started/2`, whose `:transient` child outlives this transient
  `:erpc` server process by construction — no spawn needed. The caller must
  have installed the stub env first (`TestFixtures.install_cluster_stub_env/1`
  on this peer). Returns `{:ok, parent_run_id}` once the composer is live;
  everything after (waves, park, kill) is awaited durably by the test node.

  Ctx-shape caveat: the cluster `ctx.ctx` is `%{tenant:, actor:}` only —
  opts are built here rather than through `TestFixtures.base_opts/1`, which
  expects a `ctx.context` key. An empty `context` is deliberate: the wave
  scope takes its documented `wf_<tag>` / `File.cwd!()` fallbacks, and
  nothing in these proofs asserts workspace/session threading.
  """
  @spec launch_composer(%{tenant: String.t(), actor: map()}, :gate_fixture | :linear_worker) ::
          {:ok, String.t()} | {:error, term()}
  def launch_composer(%{tenant: tenant, actor: actor}, catalog_key) do
    {catalog, live, artifacts} = launch_ingredients(catalog_key)

    opts = [
      catalog: catalog,
      live: live,
      artifacts: artifacts,
      tenant: tenant,
      actor: actor,
      context: %{},
      max_waves: 10
    ]

    with {:ok, parent} <- RouteComposer.create_parent_run(opts),
         {:ok, _pid} <- RouteComposer.ensure_started(opts, parent) do
      {:ok, parent.id}
    end
  end

  defp launch_ingredients(:gate_fixture) do
    {TestFixtures.gate_fixture_catalog(), TestFixtures.gate_fixture_seed_live(),
     TestFixtures.gate_fixture_seed_artifacts()}
  end

  defp launch_ingredients(:linear_worker) do
    {TestFixtures.linear_worker_fixture_catalog(), TestFixtures.self_heal_seed_live(),
     TestFixtures.self_heal_seed_artifacts()}
  end

  @doc """
  Run `GatedTestReactor` to its durable gate park (synchronous — the park
  returns promptly) and return the ids Proof C needs later. A map, not a
  tuple, so callers never drift on element order; `workspace_path` is the
  post-gate Ash create's identity, asserted after the cross-BEAM resume.
  """
  @spec launch_gated(%{tenant: String.t(), actor: map()}) ::
          {:ok,
           %{
             run_id: String.t(),
             case_id: String.t(),
             workspace_name: String.t(),
             workspace_path: String.t()
           }}
          | {:error, term()}
  def launch_gated(%{tenant: tenant, actor: actor}) do
    name = "gated-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), name)

    case ReactorRunner.run(GatedTestReactor, %{workspace_name: name, workspace_path: path},
           tenant: tenant,
           actor: actor
         ) do
      {:ok, {:paused, case_id}, run} ->
        {:ok, %{run_id: run.id, case_id: case_id, workspace_name: name, workspace_path: path}}

      other ->
        {:error, other}
    end
  end
end
