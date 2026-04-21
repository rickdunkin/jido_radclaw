defmodule JidoClaw.Shell.ProfileManagerDeadlockTest do
  # async: false — both ProfileManager and SessionManager are named
  # singletons; this test suspends PM mid-test so parallel cases would
  # see a frozen PM and fail unrelated assertions.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.{ProfileManager, SessionManager}
  alias JidoClaw.VFS.Workspace

  @fixture_profiles %{
    "default" => %{"JIDO_DEADLOCK" => "base"},
    "staging" => %{"JIDO_DEADLOCK" => "staging-value"}
  }

  setup do
    :ok = ProfileManager.replace_profiles_for_test(@fixture_profiles)

    workspace_id = "deadlock-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_deadlock_#{System.unique_integer([:positive])}"
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

  describe "SessionManager does not call ProfileManager on session bootstrap" do
    # Before the fix: SessionManager.start_new_session → profile_env/1
    # did a GenServer.call to ProfileManager. If PM was busy in its own
    # handle_call (e.g., applying a switch that re-enters SM), the two
    # would cross-lock and time out at ~35 s.
    #
    # After the fix: profile_env/1 reads the ETS mirror. Suspending PM
    # is a proxy for "PM's GenServer queue is blocked" — if the old
    # code path reappears, this test will hang on the SM.run call.
    test "SessionManager.run completes quickly while PM is suspended", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Pre-switch so the mirror has a row for this workspace_id.
      # Bootstrap a session first so the switch has a live env to
      # update (otherwise update_env is a no-op on missing session).
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      pm = Process.whereis(ProfileManager) || flunk("ProfileManager singleton not running")

      # :sys.suspend blocks the target's message loop — any GenServer
      # call into PM from this moment until :sys.resume will sit in
      # the mailbox without reply.
      :sys.suspend(pm)

      try do
        fresh_ws = "deadlock-fresh-#{System.unique_integer([:positive])}"

        # Use Task.yield to bound the wait. If profile_env/1 regressed
        # to a PM.call, it'd sit here for the full default_timeout +
        # 5_000 (35 s). We cap at 2 s — orders of magnitude below that
        # and still a comfortable margin over real VFS/host bootstrap.
        task =
          Task.async(fn ->
            SessionManager.run(fresh_ws, "true", 5_000, project_dir: tmp, force: :host)
          end)

        case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, %{exit_code: 0}}} ->
            :ok

          {:ok, other} ->
            flunk("SessionManager.run returned unexpected result: #{inspect(other)}")

          nil ->
            flunk(
              "SessionManager.run did not complete within 2s while ProfileManager was suspended — " <>
                "profile_env/1 is blocking on PM (deadlock regression)"
            )
        end

        _ = SessionManager.stop_session(fresh_ws)
        _ = Workspace.teardown(fresh_ws)
      after
        :sys.resume(pm)
      end
    end

    # The inner-loop variant of the same cycle: `jido status` runs
    # through `ShellSessionServer` while `SessionManager.handle_call({:run, ...})`
    # is still waiting in `collect_output/2`. If `ProfileManager.current/1`
    # did a GenServer.call to PM, a concurrent `/profile switch` (which
    # holds PM and waits on SM.update_env) would cross-lock with this
    # run — SM blocked on collect_output, PM blocked on SM.
    #
    # After the fix: `current/1` reads the ETS mirror. Suspending PM
    # again stands in for "PM's mailbox is not processing" — the run
    # must still complete within the command's timeout, and the
    # rendered status must include the *real* active profile name
    # (proving the mirror-read path delivered it, not a "default"
    # fallback from the GenServer path we removed).
    test "SessionManager.run(ws, \"jido status\", ...) completes while PM is suspended", %{
      workspace_id: ws,
      tmp: tmp
    } do
      # Bootstrap sessions then switch so the mirror has a real row.
      assert {:ok, _} =
               SessionManager.run(ws, "true", 5_000, project_dir: tmp, force: :host)

      assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")

      pm = Process.whereis(ProfileManager) || flunk("ProfileManager singleton not running")
      :sys.suspend(pm)

      try do
        task =
          Task.async(fn ->
            SessionManager.run(ws, "jido status", 5_000, project_dir: tmp, force: :vfs)
          end)

        case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, %{output: out, exit_code: 0}}} ->
            assert out =~ "profile     staging"

          {:ok, other} ->
            flunk("jido status run returned unexpected result: #{inspect(other)}")

          nil ->
            flunk(
              "SessionManager.run(\"jido status\") did not complete within 3s while " <>
                "ProfileManager was suspended — ProfileManager.current/1 is blocking on PM " <>
                "(deadlock regression)"
            )
        end
      after
        :sys.resume(pm)
      end
    end
  end
end
