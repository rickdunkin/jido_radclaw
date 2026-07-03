defmodule JidoClaw.Agent.LoopGuard.StoreTest do
  @moduledoc """
  Store-level tests: key isolation on the app singleton (reset in setup —
  hence async: false), sweep TTL semantics on dedicated instances with
  tiny TTLs, facade fail-open against a nonexistent server, and the
  synchronous reset contract.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.LoopGuard
  alias JidoClaw.Agent.LoopGuard.Store

  @opts [
    repeat_threshold: 4,
    repeat_window: 8,
    failure_threshold: 3,
    failure_window: 20,
    max_calls: 100,
    warn_pct: 0.80,
    max_recoveries: 2
  ]

  setup do
    :ok = Store.reset()
    on_exit(fn -> Store.reset() end)
  end

  defp key(suffix), do: {"tenant-#{suffix}", "session-#{suffix}", "main"}

  defp halt_key!(key) do
    for _i <- 1..3 do
      assert Store.check_attempt(key, {"read_file", "d"}, @opts) == :ok
    end

    assert {:halt, _message, %{trigger: :identical_repeat}} =
             Store.check_attempt(key, {"read_file", "d"}, @opts)
  end

  test "keys are isolated: a halt on one key never blocks another" do
    halt_key!(key("a"))

    assert {:halt, _message, _details} = Store.check_attempt(key("a"), {"read_file", "d"}, @opts)
    assert Store.check_attempt(key("b"), {"read_file", "d"}, @opts) == :ok
  end

  test "check_result verdicts pass through the store (nudge then halt render)" do
    k = key("sig")

    assert Store.check_result(k, {"edit_file", true, "boom"}, @opts) == :ok
    assert Store.check_result(k, {"edit_file", true, "boom"}, @opts) == :ok
    assert {:nudge, directive} = Store.check_result(k, {"edit_file", true, "boom"}, @opts)
    assert directive =~ "[DOOM LOOP RECOVERY:"
  end

  test "reset/0 is synchronous and drops all key state" do
    halt_key!(key("reset"))
    assert :ok = Store.reset()
    assert Store.check_attempt(key("reset"), {"read_file", "d"}, @opts) == :ok
  end

  describe "sweep" do
    # Dedicated instances (opts[:server]) with an effectively-off timer and a
    # per-test LITERAL name (no runtime atom creation); sweeps are driven via
    # send/2 and observed through the behavioral barrier of the next
    # GenServer.call (FIFO mailbox).
    defp start_store!(name, overrides) do
      opts = Keyword.merge([name: name, sweep_interval_ms: 3_600_000], overrides)
      pid = start_supervised!({Store, opts})
      {name, pid}
    end

    test "evicts idle keys after idle_ttl_ms; the post-expiry key starts fresh" do
      {name, pid} =
        start_store!(:loop_guard_sweep_idle_store, idle_ttl_ms: 20, halt_ttl_ms: 3_600_000)

      opts = Keyword.put(@opts, :server, name)
      k = key("idle")

      for _i <- 1..3 do
        assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok
      end

      Process.sleep(30)
      send(pid, :sweep)

      # A 4th identical call would halt if the window survived; a fresh key
      # accepts it.
      assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok
    end

    test "keeps idle keys before idle_ttl_ms" do
      {name, pid} =
        start_store!(:loop_guard_sweep_warm_store, idle_ttl_ms: 3_600_000, halt_ttl_ms: 3_600_000)

      opts = Keyword.put(@opts, :server, name)
      k = key("warm")

      for _i <- 1..3 do
        assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok
      end

      send(pid, :sweep)

      assert {:halt, _message, %{trigger: :identical_repeat}} =
               Store.check_attempt(k, {"read_file", "d"}, opts)
    end

    test "evicts halted keys after halt_ttl_ms (sticky until then); fresh key after expiry" do
      {name, pid} =
        start_store!(:loop_guard_sweep_halted_store, idle_ttl_ms: 3_600_000, halt_ttl_ms: 40)

      opts = Keyword.put(@opts, :server, name)
      k = key("halted")

      for _i <- 1..3 do
        assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok
      end

      assert {:halt, _message, _details} = Store.check_attempt(k, {"read_file", "d"}, opts)

      # Before the TTL: sweep keeps the halted key; attempts stay blocked
      # and (per the sticky contract) do not extend the halt.
      send(pid, :sweep)
      assert {:halt, _message, _details} = Store.check_attempt(k, {"other", "x"}, opts)

      Process.sleep(50)
      send(pid, :sweep)

      assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok,
             "an expired halt must reset the whole key"
    end

    test "idle TTL does not evict a halted key (halt_ttl governs)" do
      {name, pid} =
        start_store!(:loop_guard_sweep_halted_idle_store, idle_ttl_ms: 1, halt_ttl_ms: 3_600_000)

      opts = Keyword.put(@opts, :server, name)
      k = key("halted-idle")

      for _i <- 1..3 do
        assert Store.check_attempt(k, {"read_file", "d"}, opts) == :ok
      end

      assert {:halt, _message, _details} = Store.check_attempt(k, {"read_file", "d"}, opts)

      Process.sleep(10)
      send(pid, :sweep)

      assert {:halt, _message, _details} = Store.check_attempt(k, {"read_file", "d"}, opts)
    end
  end

  describe "facade fail-open" do
    # The Store client never rescues; the FACADE does. A nonexistent server
    # name makes GenServer.call exit — check/observe must pass through.
    # capture_log: the fail-open warning itself is the expected behavior.
    @describetag capture_log: true

    test "check/4 returns :ok when the store is unreachable" do
      context = %{tool_context: %{tenant_id: "t", session_uuid: "s", session_id: "s"}}

      assert LoopGuard.check("read_file", %{path: "x"}, context,
               enabled?: true,
               server: :loop_guard_nonexistent_store
             ) == :ok
    end

    test "observe_result/5 returns the result unchanged when the store is unreachable" do
      context = %{tool_context: %{tenant_id: "t", session_uuid: "s", session_id: "s"}}
      result = {:error, %{code: :execution_error, message: "boom", details: %{}}}

      assert LoopGuard.observe_result(result, "read_file", %{path: "x"}, context,
               enabled?: true,
               server: :loop_guard_nonexistent_store
             ) == result
    end
  end

  describe "facade scope pass-through" do
    test "missing tenant or session passes through unguarded (no store mutation)" do
      no_tenant = %{tool_context: %{session_uuid: "s", session_id: "s"}}
      no_session = %{tool_context: %{tenant_id: "t"}}
      present_nil = %{tool_context: %{tenant_id: nil, session_uuid: nil, session_id: nil}}

      for context <- [no_tenant, no_session, present_nil, %{}] do
        for _i <- 1..5 do
          assert LoopGuard.check("read_file", %{path: "x"}, context, enabled?: true) == :ok
        end
      end
    end
  end
end
