defmodule JidoClaw.Web.DashboardLiveTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Web.DashboardLive

  @stale_overview %JidoClaw.RuntimeOverview{
    tenant_id: nil,
    forge: %JidoClaw.ForgeView{active_count: 999},
    workflows: %JidoClaw.WorkflowView{
      active_count: 999,
      active_runs: [:stale],
      recent_completions: [:stale]
    },
    uptime: %{seconds: 999}
  }

  defp build_socket do
    assigns = %{
      __changed__: %{},
      overview: @stale_overview,
      overview_refresh_pending: false,
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
      assert returned.assigns.overview == @stale_overview
      refute returned.assigns.overview_refresh_pending
    end

    test "unknown tuple" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info({:nope, "x"}, socket)
      assert returned.assigns.overview == @stale_overview
      refute returned.assigns.overview_refresh_pending
    end
  end

  describe "handle_info/2 — forge events arm a coalesced refresh" do
    test "session_started schedules a deferred refresh (overview unchanged until it fires)" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_started, "s1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "session_recovering schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_recovering, "s1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "session_recovery_exhausted schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_recovery_exhausted, "s1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "session_stopped schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:session_stopped, "s1", :normal, %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "a second event while a refresh is pending coalesces (still pending, unchanged)" do
      socket = build_socket()

      assert {:noreply, once} =
               DashboardLive.handle_info({:session_started, "s1", %{}}, socket)

      assert {:noreply, twice} =
               DashboardLive.handle_info({:run_started, "r1", %{}}, once)

      assert twice.assigns.overview_refresh_pending
      assert twice.assigns.overview == @stale_overview
    end
  end

  describe "handle_info/2 — run events arm a coalesced refresh" do
    test "run_started schedules a deferred refresh" do
      socket = build_socket()
      assert {:noreply, returned} = DashboardLive.handle_info({:run_started, "r1", %{}}, socket)
      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "run_completed schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_completed, "r1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "run_failed schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_failed, "r1", %{error: "boom"}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "run_cancelled schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_cancelled, "r1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end

    test "run_abandoned schedules a deferred refresh" do
      socket = build_socket()

      assert {:noreply, returned} =
               DashboardLive.handle_info({:run_abandoned, "r1", %{}}, socket)

      assert returned.assigns.overview_refresh_pending
      assert returned.assigns.overview == @stale_overview
    end
  end

  describe "handle_info/2 — :refresh_overview rebuilds once" do
    test "rebuilds the overview and clears the pending flag" do
      socket = build_socket()

      assert {:noreply, returned} = DashboardLive.handle_info(:refresh_overview, socket)

      assert returned.assigns.overview != @stale_overview
      refute returned.assigns.overview_refresh_pending
    end
  end
end
