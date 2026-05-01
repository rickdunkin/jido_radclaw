defmodule JidoClaw.Embeddings.RatePacerTest do
  @moduledoc """
  Regression coverage for the v0.6.1 RatePacer impl fixes (Decision 4).

  The application supervisor already starts a `RatePacer` registered
  under the module name. To avoid `:already_started` collisions and
  rest_for_one cascades, we test the `acquire/2` GenServer behavior
  via **unnamed** GenServer instances — `GenServer.start_link(RatePacer,
  [])` — and call into them with raw `GenServer.call/3`. The
  `try_admit/2` API is a static SQL function that doesn't depend on
  the GenServer at all, so those tests just exercise the function
  with mutated `Application.put_env/3` config (restored on exit).

  Locks in:

    * `acquire/2` actually blocks and is released on the next refill
      tick (pre-fix: returned `{:error, :timeout}` immediately).
    * `acquire/2` honors the configured `:acquire_timeout_ms` and
      returns `{:error, :timeout}` when no refill arrives in time.
    * `try_admit/2` derives an effective window large enough to make
      the configured RPM expressible. `:rpm: 1, :cluster_window: 1`
      upgrades to a 60-second window so the per-window cap stays at
      1 instead of being silently rounded up.
  """

  use JidoClaw.SolutionsCase, async: false

  alias JidoClaw.Embeddings.RatePacer

  setup do
    prev = Application.get_env(:jido_claw, RatePacer)

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:jido_claw, RatePacer)
      else
        Application.put_env(:jido_claw, RatePacer, prev)
      end
    end)

    :ok
  end

  describe "try_admit/2 — effective-window derivation (D4 #2)" do
    test "low RPM (1) widens the effective window so the cap stays at 1" do
      Application.put_env(:jido_claw, RatePacer,
        rpm: 1,
        tpm: 1000,
        cluster_window_seconds: 1
      )

      model = "voyage-test-#{System.unique_integer([:positive])}"
      # rpm=1 should mean exactly 1 admit per 60s window, regardless
      # of the configured 1s window. Pre-fix this admitted >1 per
      # second because the cap clamped to max(1, _) and per-second
      # bucketing reset every wall-clock second.
      assert :ok = RatePacer.try_admit(model, 1)
      assert {:error, :budget_exhausted} = RatePacer.try_admit(model, 1)
    end

    test "rpm large enough for the window keeps the configured value" do
      Application.put_env(:jido_claw, RatePacer,
        rpm: 60,
        tpm: 60_000,
        cluster_window_seconds: 1
      )

      model = "voyage-test-#{System.unique_integer([:positive])}"
      assert :ok = RatePacer.try_admit(model, 1)
      assert {:error, :budget_exhausted} = RatePacer.try_admit(model, 1)
    end
  end

  describe "acquire/2 — blocking + refill (D4 #1)" do
    test "first acquire admits immediately" do
      Application.put_env(:jido_claw, RatePacer,
        rpm: 60_000,
        tpm: 10_000,
        cluster_window_seconds: 60,
        acquire_timeout_ms: 1_500,
        refill_interval_ms: 20
      )

      pid = start_unnamed_pacer()
      assert GenServer.call(pid, {:acquire, :voyage, 1}) == :ok
    end

    test "an acquire against a drained bucket blocks (does NOT return :timeout immediately)" do
      Application.put_env(:jido_claw, RatePacer,
        rpm: 60_000,
        tpm: 10_000,
        cluster_window_seconds: 60,
        acquire_timeout_ms: 1_500,
        refill_interval_ms: 20
      )

      pid = start_unnamed_pacer()

      # Drain TPM exhaustively in a single bulk-token call so the
      # next acquire(:voyage, 1) has tokens_remaining = 0 and must
      # wait for the refill tick.
      assert GenServer.call(pid, {:acquire, :voyage, 10_000}) == :ok

      task = Task.async(fn -> GenServer.call(pid, {:acquire, :voyage, 1}, :infinity) end)

      # Pre-fix: would have returned {:error, :timeout} immediately
      # (in well under 50ms). Post-fix: must block on the waiter
      # queue. We allow up to 5ms because the test scheduler can
      # schedule both ends quickly.
      assert Task.yield(task, 5) == nil

      # Refill tick fires every 20ms; at tpm=10_000 each tick adds
      # ~3.3 tokens. The waiter should be drained shortly after the
      # first tick and eventually reply with :ok.
      assert {:ok, :ok} = Task.yield(task, 1_000) || {:error, Task.shutdown(task)}
    end

    test "acquire returns :timeout when refill is starved past the configured timeout" do
      Application.put_env(:jido_claw, RatePacer,
        rpm: 1,
        tpm: 1,
        cluster_window_seconds: 60,
        acquire_timeout_ms: 150,
        refill_interval_ms: 25
      )

      pid = start_unnamed_pacer()

      # Drain initial capacity (rpm=1, tpm=1).
      assert GenServer.call(pid, {:acquire, :voyage, 1}, :infinity) == :ok

      # Second acquire — bucket is empty, refill is glacial (1 unit
      # per 60s). 150ms timeout fires first.
      assert GenServer.call(pid, {:acquire, :voyage, 1}, :infinity) == {:error, :timeout}
    end
  end

  defp start_unnamed_pacer do
    {:ok, pid} = GenServer.start_link(RatePacer, [])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end
end
