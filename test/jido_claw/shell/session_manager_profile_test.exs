defmodule JidoClaw.Shell.SessionManagerProfileTest do
  # Integration: exercises the full profile switch path — ProfileManager
  # (singleton) computes drop+merge, SessionManager.update_env/3 applies
  # to host + VFS, and the next shell command reads the new env.
  #
  # async: false — ProfileManager + SessionManager are both named
  # singletons. Tests share the supervised instances; parallel cases
  # would trample each other's active-by-workspace state.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.{ProfileManager, SessionManager}
  alias JidoClaw.VFS.Workspace

  @fixture_profiles %{
    "default" => %{"JIDO_SMOKE" => "base"},
    "staging" => %{"JIDO_SMOKE" => "staging-value"}
  }

  setup do
    :ok = ProfileManager.replace_profiles_for_test(@fixture_profiles)

    workspace_id = "sm-profile-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_sm_profile_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn ->
      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
      :ok = ProfileManager.replace_profiles_for_test(%{})
      :ok = ProfileManager.clear_active_for_test()
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  describe "host-side env" do
    test "host session picks up `default` env before any switch", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, %{output: out, exit_code: 0}} =
               SessionManager.run(ws, "echo $JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :host
               )

      assert String.trim(out) == "base"
    end

    test "`/profile switch staging` updates live host session env", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Bootstrap host session before switching so live-update path runs.
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      assert {:ok, %{output: out}} =
               SessionManager.run(ws, "echo $JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :host
               )

      assert String.trim(out) == "staging-value"
    end
  end

  describe "VFS-side env" do
    test "VFS session picks up `default` env before any switch", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # `env JIDO_SMOKE` (no pipe, no grep) routes VFS and reads state.env
      assert {:ok, %{output: out, exit_code: 0}} =
               SessionManager.run(ws, "env JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert out =~ "JIDO_SMOKE=base"
    end

    test "switch updates VFS session env", %{workspace_id: ws, tmp: tmp} do
      # Prime the VFS session
      assert {:ok, _} =
               SessionManager.run(ws, "env JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      assert {:ok, %{output: out}} =
               SessionManager.run(ws, "env JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert out =~ "JIDO_SMOKE=staging-value"
    end
  end

  describe "ad hoc preservation across switches" do
    test "ad hoc `env ADHOC=kept` mutation survives a profile switch", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Set an ad hoc env var via the built-in env command
      assert {:ok, %{exit_code: 0}} =
               SessionManager.run(ws, "env ADHOC=kept", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      assert {:ok, %{output: out}} =
               SessionManager.run(ws, "env ADHOC", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert out =~ "ADHOC=kept"

      # …and the switch still applied the profile env
      assert {:ok, %{output: smoke_out}} =
               SessionManager.run(ws, "env JIDO_SMOKE", 5_000,
                 project_dir: tmp,
                 force: :vfs
               )

      assert smoke_out =~ "JIDO_SMOKE=staging-value"
    end
  end

  describe "update_env/3 rollback" do
    test "VFS write failure rolls host back to pre-call env", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Bootstrap sessions first
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      # Snapshot host env before update
      {:ok, pre_host} = SessionManager.__host_env_for_test__(ws)
      assert pre_host["JIDO_SMOKE"] == "base"

      # Induce VFS failure AFTER host has succeeded.
      # `real_writer` succeeds for host, `fail_writer` fails for VFS —
      # rollback path kicks in.
      real_writer = &Jido.Shell.ShellSession.update_env/2
      fail_writer = fn _id, _env -> {:error, :induced} end

      assert {:error, :vfs_update_failed, :ok, :induced} =
               SessionManager.do_update_env(
                 ws,
                 ["JIDO_SMOKE"],
                 %{"JIDO_SMOKE" => "would-have-been-staging"},
                 host_writer: real_writer,
                 vfs_writer: fail_writer
               )

      # Host should be back to pre-call state
      {:ok, post_host} = SessionManager.__host_env_for_test__(ws)
      assert post_host == pre_host
    end
  end

  describe "ETS mirror (deadlock fix)" do
    test "switch publishes {workspace_id, profile_name, overlay} row", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Bootstrap sessions so switch runs the live-update path.
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      table = ProfileManager.ets_table()
      assert :ets.whereis(table) != :undefined

      assert [{^ws, "staging", %{"JIDO_SMOKE" => "staging-value"}}] = :ets.lookup(table, ws)
    end

    test "clear_active_for_test drops workspace rows but preserves :__default__", %{
      workspace_id: ws,
      tmp: tmp
    } do
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      table = ProfileManager.ets_table()
      assert [{^ws, "staging", _}] = :ets.lookup(table, ws)

      :ok = ProfileManager.clear_active_for_test()

      assert :ets.lookup(table, ws) == []

      assert [{:__default__, "default", %{"JIDO_SMOKE" => "base"}}] =
               :ets.lookup(table, :__default__)
    end
  end
end
