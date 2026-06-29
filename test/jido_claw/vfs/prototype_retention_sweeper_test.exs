defmodule JidoClaw.VFS.PrototypeRetentionSweeperTest do
  @moduledoc """
  AR-8b-2 C3 sweeper: opt-in TTL GC of `.prototypes/<uuid>/` dirs. Drives the
  app's singleton with `send(pid, :sweep)` + a `:sys.get_state` barrier (per
  `retention_sweeper_test.exs`), pointing the single root at a temp project dir.

  Non-async (`TenantCase`, shared sandbox): the sweeper's reference check queries
  `WorkflowRun` from its own process — shared mode lets it see the test's rows.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.VFS.PrototypeRetentionSweeper
  alias JidoClaw.VFS.Sandbox

  setup do
    base = Path.join(System.tmp_dir!(), "sweeper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    %{tenant_id: tenant_id} = seed_full(tenant_label: "sweeper")

    saved_project = Application.fetch_env(:jido_claw, :project_dir)
    saved_ret = Application.fetch_env(:jido_claw, :prototype_retention)
    Application.put_env(:jido_claw, :project_dir, base)

    on_exit(fn ->
      restore(:project_dir, saved_project)
      restore(:prototype_retention, saved_ret)
      File.rm_rf!(base)
    end)

    {:ok, base: base, tenant_id: tenant_id, actor: actor_for(tenant_id)}
  end

  # --- helpers ---

  defp restore(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)

  defp enable!(days),
    do: Application.put_env(:jido_claw, :prototype_retention, max_age_days: days)

  defp disable!, do: Application.put_env(:jido_claw, :prototype_retention, max_age_days: nil)

  defp make_prototype!(base) do
    {:ok, %{dir: dir, id: id}} = Sandbox.create_prototype_dir(base)
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\nend\n")
    {dir, id}
  end

  defp backdate!(dir, days) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-days, :day)
      |> DateTime.to_unix()

    for path <- [dir | Path.wildcard(Path.join(dir, "**"))], do: File.touch!(path, ts)
  end

  defp reference!(prototype_id, ctx) do
    {:ok, run} =
      WorkflowRun.create(
        %{
          name: "sweeper-ref",
          workflow_type: "composer",
          config: %{"premises" => %{"prototype_id" => prototype_id}}
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    run
  end

  defp tick! do
    pid = Process.whereis(PrototypeRetentionSweeper)
    assert is_pid(pid)
    send(pid, :sweep)
    :sys.get_state(pid)
    :ok
  end

  # --- tests ---

  test "disabled (nil) makes the tick a no-op even on a stale, unreferenced dir", %{base: base} do
    disable!()
    {dir, _id} = make_prototype!(base)
    backdate!(dir, 60)

    tick!()

    assert File.dir?(dir)
  end

  test "a stale, unreferenced prototype is swept", %{base: base} do
    enable!(30)
    {dir, _id} = make_prototype!(base)
    backdate!(dir, 60)

    tick!()

    refute File.dir?(dir)
  end

  test "a stale but referenced prototype is kept (fail-safe)", %{base: base} = ctx do
    enable!(30)
    {dir, id} = make_prototype!(base)
    backdate!(dir, 60)
    reference!(id, ctx)

    tick!()

    assert File.dir?(dir)
  end

  test "an edited prototype is kept (effective mtime across files)", %{base: base} do
    enable!(30)
    {dir, _id} = make_prototype!(base)
    backdate!(dir, 60)
    # An edit refreshes a file's mtime even though the dir mtime stays old.
    File.touch!(Path.join(dir, "a.ex"))

    tick!()

    assert File.dir?(dir)
  end

  test "a non-UUID child under .prototypes is never considered", %{base: base} do
    enable!(30)
    scratch = Path.join([base, ".prototypes", "scratch-notes"])
    File.mkdir_p!(scratch)
    backdate!(scratch, 60)

    tick!()

    assert File.dir?(scratch)
  end

  describe "leader gate (WS4)" do
    setup do
      saved = Application.fetch_env(:jido_claw, :cluster_leader_module)
      Application.put_env(:jido_claw, :cluster_leader_module, JidoClaw.ClusterLeaderStub)

      on_exit(fn ->
        restore(:cluster_leader_module, saved)
        Application.delete_env(:jido_claw, :cluster_leader_stub_result)
      end)

      :ok
    end

    test "off-leader: a stale, unreferenced prototype is kept (the sweep is gated)",
         %{base: base} do
      Application.put_env(:jido_claw, :cluster_leader_stub_result, false)
      enable!(30)
      {dir, _id} = make_prototype!(base)
      backdate!(dir, 60)

      tick!()

      assert File.dir?(dir)
    end

    test "on-leader: a stale, unreferenced prototype is swept", %{base: base} do
      Application.put_env(:jido_claw, :cluster_leader_stub_result, true)
      enable!(30)
      {dir, _id} = make_prototype!(base)
      backdate!(dir, 60)

      tick!()

      refute File.dir?(dir)
    end
  end
end
