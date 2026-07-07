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
