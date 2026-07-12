defmodule JidoClaw.Forge.RunLoopTest.OptsCaptureRunner do
  @moduledoc false
  # Continue-then-done runner: reports each iteration's opts through the
  # :run_loop_opts_capture app-env fun (async: false suite).
  @behaviour JidoClaw.Forge.Runner

  alias JidoClaw.Forge.Runner

  @impl JidoClaw.Forge.Runner
  def init(_client, _config), do: {:ok, %{iteration: 0}}

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, opts) do
    iteration = state.iteration + 1

    case Application.get_env(:jido_claw, :run_loop_opts_capture) do
      fun when is_function(fun, 2) -> fun.(iteration, opts)
      _ -> :ok
    end

    result = if iteration == 1, do: Runner.continue("more"), else: Runner.done("done")
    {:ok, %{result | metadata: Map.put(result.metadata, :state, %{state | iteration: iteration})}}
  end

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok
end

defmodule JidoClaw.Forge.RunLoopTest do
  @moduledoc """
  `Forge.run_loop/2` continuation-opts hygiene: iteration ≥ 2 carries
  NEITHER `:prompt` nor `:guidance` — the caller's task is never resent
  (SY3-3) and caller guidance never rides every continuation indefinitely
  (run_loop invents no guidance of its own).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.RunLoopTest.OptsCaptureRunner
  alias JidoClaw.Test.StubSandbox

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
      Application.delete_env(:jido_claw, :run_loop_opts_capture)
    end)

    :ok
  end

  test "iteration ≥ 2 opts contain neither :prompt nor :guidance" do
    sid = "run_loop_opts_#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    Application.put_env(:jido_claw, :run_loop_opts_capture, fn iteration, opts ->
      send(test_pid, {:iteration_opts, iteration, opts})
    end)

    ForgePubSub.subscribe(sid)
    {:ok, _} = Forge.start_session(sid, %{runner: OptsCaptureRunner, sandbox: StubSandbox})
    assert_receive {:ready, ^sid}, 10_000
    on_exit(fn -> _ = Forge.stop_session(sid) end)

    assert {:ok, %{status: :done}} =
             Forge.run_loop(sid, prompt: "the task", guidance: "caller guidance", timeout: 5_000)

    assert_receive {:iteration_opts, 1, opts1}, 10_000
    assert Keyword.get(opts1, :prompt) == "the task"
    assert Keyword.get(opts1, :guidance) == "caller guidance"

    assert_receive {:iteration_opts, 2, opts2}, 10_000
    refute Keyword.has_key?(opts2, :prompt)
    refute Keyword.has_key?(opts2, :guidance)
  end
end
