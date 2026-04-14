defmodule JidoClaw.Web.DashboardLiveTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Web.DashboardLive

  @stale_summary %{active_count: 999, active_runs: [:stale], recent_completions: [:stale]}

  defp build_socket do
    assigns = %{
      __changed__: %{},
      forge_sessions: 999,
      workflow_summary: @stale_summary,
      uptime: "2h 15m",
      page_title: "Dashboard",
      flash: %{}
    }

    %Phoenix.LiveView.Socket{assigns: assigns}
  end

  describe "handle_info/2 — catch-all is a no-op" do
    test "unknown atom" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info(:totally_unknown, socket)
      assert returned.assigns.forge_sessions == 999
      assert returned.assigns.workflow_summary == @stale_summary
    end

    test "unknown tuple" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info({:nope, "x"}, socket)
      assert returned.assigns.forge_sessions == 999
      assert returned.assigns.workflow_summary == @stale_summary
    end
  end

  describe "handle_info/2 — forge events update only forge_sessions" do
    test "session_started refreshes forge_sessions, not workflow_summary" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info({:session_started, "s1"}, socket)
      assert returned.assigns.forge_sessions != 999
      assert returned.assigns.workflow_summary == @stale_summary
    end

    test "session_recovering refreshes forge_sessions, not workflow_summary" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_recovering, "s1"}, socket)

      assert returned.assigns.workflow_summary == @stale_summary
    end

    test "session_recovery_exhausted refreshes forge_sessions, not workflow_summary" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_recovery_exhausted, "s1"}, socket)

      assert returned.assigns.workflow_summary == @stale_summary
    end

    test "session_stopped refreshes forge_sessions, not workflow_summary" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_stopped, "s1", :normal}, socket)

      assert returned.assigns.workflow_summary == @stale_summary
    end
  end

  describe "handle_info/2 — run events update only workflow_summary" do
    test "run_started refreshes workflow_summary, not forge_sessions" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info({:run_started, "r1", %{}}, socket)
      assert returned.assigns.forge_sessions == 999
      assert returned.assigns.workflow_summary != @stale_summary
    end

    test "run_completed refreshes workflow_summary, not forge_sessions" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_completed, "r1", %{}}, socket)

      assert returned.assigns.forge_sessions == 999
      assert returned.assigns.workflow_summary != @stale_summary
    end

    test "run_failed refreshes workflow_summary, not forge_sessions" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_failed, "r1", %{error: "boom"}}, socket)

      assert returned.assigns.forge_sessions == 999
      assert returned.assigns.workflow_summary != @stale_summary
    end
  end
end
