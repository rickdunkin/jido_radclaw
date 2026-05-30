defmodule JidoClaw.Reasoning.Compactor.SummarizerTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Error.ExecutionError
  alias JidoClaw.Reasoning.Compactor.{Config, Summarizer}

  defmodule SuccessBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(prompt, _opts), do: {:ok, "summary for: #{String.slice(prompt, 0, 16)}"}
  end

  defmodule SlowBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, _opts) do
      Process.sleep(10_000)
      {:ok, "should never reach here"}
    end
  end

  defmodule RaisingBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, _opts), do: raise(ArgumentError, "boom")
  end

  defmodule ExitingBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, _opts), do: exit(:bye)
  end

  defmodule ErrorBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, _opts), do: {:error, :provider_unavailable}
  end

  # Counts attempts via the Agent in opts[:counter]; returns a transient
  # backend error for the first `opts[:fail_until]` attempts, then succeeds.
  defmodule FlakyBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, opts) do
      n = Agent.get_and_update(Keyword.fetch!(opts, :counter), &{&1 + 1, &1 + 1})

      if n <= Keyword.get(opts, :fail_until, 0) do
        {:error, :transient}
      else
        {:ok, "ok-after-#{n}"}
      end
    end
  end

  # Always raises, counting attempts — used to prove exceptions never retry.
  defmodule RaisingCountingBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, opts) do
      Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))
      raise ArgumentError, "boom"
    end
  end

  # Sleeps for opts[:sleep_ms] then returns opts[:output] — used to probe the
  # late-`Task.shutdown` result branch at the timeout boundary.
  defmodule BoundaryBackend do
    @behaviour Summarizer

    @impl Summarizer
    def summarize(_prompt, opts) do
      Process.sleep(Keyword.fetch!(opts, :sleep_ms))
      {:ok, Keyword.fetch!(opts, :output)}
    end
  end

  setup do
    original = Application.get_env(:jido_claw, :compaction_summarizer)
    on_exit(fn -> Application.put_env(:jido_claw, :compaction_summarizer, original) end)
    :ok
  end

  # Default to a single attempt (no retries) so the single-shot error tests
  # below stay fast and focused; retry tests pass explicit retry counts.
  defp config(timeout_ms \\ 250, opts \\ []) do
    base = [
      mode: :auto,
      summarizer_timeout_ms: timeout_ms,
      summarizer_max_retries: 0,
      summarizer_retry_backoff_ms: 1
    ]

    Config.new!(Keyword.merge(base, opts))
  end

  describe "summarize/3" do
    test "returns {:ok, summary} when backend succeeds" do
      Application.put_env(:jido_claw, :compaction_summarizer, SuccessBackend)

      assert {:ok, "summary for: hello world. hi"} =
               Summarizer.summarize("hello world. hi", config())
    end

    test "truncates summary to max_summary_chars" do
      Application.put_env(:jido_claw, :compaction_summarizer, SuccessBackend)
      cfg = config(250, max_summary_chars: 12)
      assert {:ok, summary} = Summarizer.summarize("hello world test", cfg)
      assert byte_size(summary) == 12
    end

    test "returns timeout error when backend exceeds timeout" do
      Application.put_env(:jido_claw, :compaction_summarizer, SlowBackend)
      cfg = config(80)
      assert {:error, %ExecutionError{} = err} = Summarizer.summarize("prompt", cfg)
      assert err.phase == :summarizer_timeout
      assert is_map(err.details)
      assert err.details.timeout == 80
    end

    test "returns exception error when backend raises" do
      Application.put_env(:jido_claw, :compaction_summarizer, RaisingBackend)
      assert {:error, %ExecutionError{} = err} = Summarizer.summarize("prompt", config())
      assert err.phase == :summarizer_exception
    end

    test "returns exit error when backend exits" do
      Application.put_env(:jido_claw, :compaction_summarizer, ExitingBackend)
      assert {:error, %ExecutionError{} = err} = Summarizer.summarize("prompt", config())
      assert err.phase == :summarizer_exit
    end

    test "returns backend error when backend returns {:error, _}" do
      Application.put_env(:jido_claw, :compaction_summarizer, ErrorBackend)
      assert {:error, %ExecutionError{} = err} = Summarizer.summarize("prompt", config())
      assert err.phase == :summarizer_backend
    end
  end

  describe "summarize/3 — retries" do
    test "retries a transient backend failure then succeeds" do
      Application.put_env(:jido_claw, :compaction_summarizer, FlakyBackend)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      cfg = config(200, summarizer_max_retries: 1, summarizer_retry_backoff_ms: 1)

      assert {:ok, "ok-after-2"} =
               Summarizer.summarize("p", cfg, counter: counter, fail_until: 1)

      assert Agent.get(counter, & &1) == 2
    end

    test "returns the backend error after exhausting retries" do
      Application.put_env(:jido_claw, :compaction_summarizer, FlakyBackend)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      cfg = config(200, summarizer_max_retries: 2, summarizer_retry_backoff_ms: 1)

      assert {:error, %ExecutionError{phase: :summarizer_backend}} =
               Summarizer.summarize("p", cfg, counter: counter, fail_until: 99)

      # 1 initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "never retries a backend exception" do
      Application.put_env(:jido_claw, :compaction_summarizer, RaisingCountingBackend)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      cfg = config(200, summarizer_max_retries: 3, summarizer_retry_backoff_ms: 1)

      assert {:error, %ExecutionError{phase: :summarizer_exception}} =
               Summarizer.summarize("p", cfg, counter: counter)

      assert Agent.get(counter, & &1) == 1
    end

    test "sleeps summarizer_retry_backoff_ms between retries" do
      Application.put_env(:jido_claw, :compaction_summarizer, FlakyBackend)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      cfg = config(200, summarizer_max_retries: 2, summarizer_retry_backoff_ms: 60)

      {elapsed_us, {:ok, _}} =
        :timer.tc(fn ->
          Summarizer.summarize("p", cfg, counter: counter, fail_until: 2)
        end)

      # 2 retries × 60ms backoff (backend errors return ~instantly)
      assert elapsed_us >= 120_000
    end

    test "emits a :retry trace breadcrumb before each retry" do
      Application.put_env(:jido_claw, :compaction_summarizer, FlakyBackend)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      test_pid = self()
      handler_id = "summarizer-retry-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido_claw, :compaction, :event],
          fn _event, _measurements, metadata, _ ->
            if metadata[:event] == :retry, do: send(test_pid, {:retry, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cfg = config(200, summarizer_max_retries: 2, summarizer_retry_backoff_ms: 1)
      assert {:ok, _} = Summarizer.summarize("p", cfg, counter: counter, fail_until: 1)

      assert_receive {:retry, md}
      assert md.reason == :summarizer_backend
      assert md.retry_attempt == 1
      assert md.max_retries == 2
      # Only one retry was needed (fail_until: 1)
      refute_receive {:retry, _}
    end
  end

  describe "summarize/3 — late shutdown result" do
    test "caps a late shutdown result at max_summary_chars (not the timeout)" do
      Application.put_env(:jido_claw, :compaction_summarizer, BoundaryBackend)
      # timeout (ms) deliberately exceeds max_summary_chars, so the old bug
      # (trimming the late result to timeout_ms) would overrun the cap.
      cfg = config(30, max_summary_chars: 10, summarizer_max_retries: 0)
      output = String.duplicate("x", 100)

      # The late-`Task.shutdown` branch is a micro-race at the timeout
      # boundary; loop to provoke it. Whichever branch wins, the cap holds.
      for _ <- 1..20 do
        case Summarizer.summarize("p", cfg, sleep_ms: 30, output: output) do
          {:ok, summary} -> assert byte_size(summary) <= 10
          {:error, %ExecutionError{phase: :summarizer_timeout}} -> :ok
        end
      end
    end
  end
end
