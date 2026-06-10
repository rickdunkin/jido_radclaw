defmodule JidoClaw.StatsTest do
  use ExUnit.Case, async: false

  # Not async: Stats is a singleton registered by JidoClaw.Application.
  # We cannot restart it safely between tests (hitting max_restarts limit),
  # so each test captures a baseline snapshot and asserts on *deltas* instead.

  setup do
    # Flush any pending casts from the app boot sequence by issuing a call
    baseline = JidoClaw.Stats.get()
    {:ok, baseline: baseline}
  end

  # Convenience: returns the delta of a field from baseline to current
  defp delta(field, %{} = baseline) do
    current = JidoClaw.Stats.get()
    Map.fetch!(current, field) - Map.fetch!(baseline, field)
  end

  describe "track_message/1" do
    test "increments message count for :user role", %{baseline: baseline} do
      JidoClaw.Stats.track_message(:user)
      # GenServer.call flushes preceding casts
      assert delta(:messages, baseline) == 1
    end

    test "increments message count for :assistant role", %{baseline: baseline} do
      JidoClaw.Stats.track_message(:assistant)
      assert delta(:messages, baseline) == 1
    end

    test "accumulates across multiple calls", %{baseline: baseline} do
      JidoClaw.Stats.track_message(:user)
      JidoClaw.Stats.track_message(:assistant)
      JidoClaw.Stats.track_message(:user)
      assert delta(:messages, baseline) == 3
    end
  end

  describe "track_tool_call/1" do
    test "increments tool_calls count", %{baseline: baseline} do
      JidoClaw.Stats.track_tool_call("read_file")
      assert delta(:tool_calls, baseline) == 1
    end

    test "accumulates across multiple different tool names", %{baseline: baseline} do
      JidoClaw.Stats.track_tool_call("read_file")
      JidoClaw.Stats.track_tool_call("write_file")
      JidoClaw.Stats.track_tool_call("git_status")
      assert delta(:tool_calls, baseline) == 3
    end

    test "accumulates when the same tool is called multiple times", %{baseline: baseline} do
      JidoClaw.Stats.track_tool_call("search_code")
      JidoClaw.Stats.track_tool_call("search_code")
      assert delta(:tool_calls, baseline) == 2
    end
  end

  describe "track_tokens/1" do
    test "adds token count to running total", %{baseline: baseline} do
      JidoClaw.Stats.track_tokens(100)
      assert delta(:tokens, baseline) == 100
    end

    test "accumulates token counts across multiple calls", %{baseline: baseline} do
      JidoClaw.Stats.track_tokens(500)
      JidoClaw.Stats.track_tokens(250)
      JidoClaw.Stats.track_tokens(750)
      assert delta(:tokens, baseline) == 1500
    end

    test "handles zero token count without error", %{baseline: baseline} do
      JidoClaw.Stats.track_tokens(0)
      assert delta(:tokens, baseline) == 0
    end
  end

  describe "track_agent_spawn/1" do
    test "increments agents_spawned count", %{baseline: baseline} do
      JidoClaw.Stats.track_agent_spawn(:coder)
      assert delta(:agents_spawned, baseline) == 1
    end

    test "accumulates across different templates", %{baseline: baseline} do
      JidoClaw.Stats.track_agent_spawn(:coder)
      JidoClaw.Stats.track_agent_spawn(:researcher)
      JidoClaw.Stats.track_agent_spawn(:reviewer)
      assert delta(:agents_spawned, baseline) == 3
    end
  end

  describe "get/0" do
    test "returns a map with all expected counter keys" do
      stats = JidoClaw.Stats.get()

      assert is_map(stats)
      assert Map.has_key?(stats, :messages)
      assert Map.has_key?(stats, :tokens)
      assert Map.has_key?(stats, :tool_calls)
      assert Map.has_key?(stats, :agents_spawned)
      assert Map.has_key?(stats, :uptime_seconds)
    end

    test "all counters are non-negative integers" do
      stats = JidoClaw.Stats.get()

      assert is_integer(stats.messages) and stats.messages >= 0
      assert is_integer(stats.tokens) and stats.tokens >= 0
      assert is_integer(stats.tool_calls) and stats.tool_calls >= 0
      assert is_integer(stats.agents_spawned) and stats.agents_spawned >= 0
    end

    test "includes uptime_seconds as a non-negative integer" do
      stats = JidoClaw.Stats.get()

      assert is_integer(stats.uptime_seconds)
      assert stats.uptime_seconds >= 0
    end

    test "reflects multiple accumulated counters correctly", %{baseline: baseline} do
      JidoClaw.Stats.track_message(:user)
      JidoClaw.Stats.track_tool_call("edit_file")
      JidoClaw.Stats.track_tokens(200)
      JidoClaw.Stats.track_agent_spawn(:docs_writer)
      # One call to get/0 synchronises all preceding casts
      stats = JidoClaw.Stats.get()

      assert stats.messages - baseline.messages == 1
      assert stats.tool_calls - baseline.tool_calls == 1
      assert stats.tokens - baseline.tokens == 200
      assert stats.agents_spawned - baseline.agents_spawned == 1
    end
  end
end
