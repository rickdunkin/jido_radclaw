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

  setup do
    original = Application.get_env(:jido_claw, :compaction_summarizer)
    on_exit(fn -> Application.put_env(:jido_claw, :compaction_summarizer, original) end)
    :ok
  end

  defp config(timeout_ms \\ 250, opts \\ []) do
    Config.new!(Keyword.merge([mode: :auto, summarizer_timeout_ms: timeout_ms], opts))
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
end
