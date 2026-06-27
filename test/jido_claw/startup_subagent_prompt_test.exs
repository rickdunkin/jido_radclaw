defmodule JidoClaw.StartupSubagentPromptTest do
  @moduledoc """
  Isolates `JidoClaw.Startup.inject_subagent_prompt/3`'s own branches (AR-5):
  the flag gate, the `:doctrine` telemetry emission, and the best-effort
  dead-pid path. Flips `config :jido_claw, :doctrine` per test (read-original /
  put_env / on_exit restore) so it never leaks the flag into the broad suite.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Workers
  alias JidoClaw.Startup

  setup do
    original_doctrine = Application.get_env(:jido_claw, :doctrine)
    original_psychology = Application.get_env(:jido_claw, :psychology)
    handler_id = "ar5-startup-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_claw, :agent, :prompt_injected],
      fn _event, measurements, metadata, %{target: target} ->
        send(target, {:prompt_injected, measurements, metadata})
      end,
      %{target: self()}
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(:doctrine, original_doctrine)
      restore_env(:psychology, original_psychology)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, val), do: Application.put_env(:jido_claw, key, val)

  @tag :capture_log
  test "flag ON: injects, returns :ok, and fires the :doctrine telemetry event" do
    Application.put_env(:jido_claw, :doctrine, enabled?: true)
    pid = start_worker()

    assert :ok = Startup.inject_subagent_prompt(pid, "coder", %{project_dir: File.cwd!()})

    assert_receive {:prompt_injected, %{bytes: bytes}, metadata}, 5_000
    assert metadata.source == :doctrine
    assert metadata.template == "coder"
    assert metadata.pid == pid
    assert is_integer(bytes) and bytes > 0
  end

  test "flag OFF: returns :ok and fires NO event (kill switch)" do
    Application.put_env(:jido_claw, :doctrine, enabled?: false)
    # Disabled short-circuits before touching the pid, so any alive pid works.
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert :ok = Startup.inject_subagent_prompt(pid, "coder", %{project_dir: File.cwd!()})
    refute_receive {:prompt_injected, _, _}, 300
  end

  @tag :capture_log
  test "AR-6: the 4-arg call rides the catalog stage through to telemetry as metadata.stage" do
    Application.put_env(:jido_claw, :doctrine, enabled?: true)
    Application.put_env(:jido_claw, :psychology, enabled?: true)
    pid = start_worker()

    assert :ok =
             Startup.inject_subagent_prompt(
               pid,
               "reviewer",
               %{project_dir: File.cwd!()},
               "security-reviewer"
             )

    assert_receive {:prompt_injected, _measurements, metadata}, 5_000
    assert metadata.source == :doctrine
    assert metadata.template == "reviewer"
    assert metadata.stage == "security-reviewer"
  end

  @tag :capture_log
  test "AR-6: the 3-arg call yields metadata.stage == nil (direct spawn / follow-up)" do
    Application.put_env(:jido_claw, :doctrine, enabled?: true)
    pid = start_worker()

    assert :ok = Startup.inject_subagent_prompt(pid, "coder", %{project_dir: File.cwd!()})

    assert_receive {:prompt_injected, _measurements, metadata}, 5_000
    assert metadata.template == "coder"
    assert metadata.stage == nil
  end

  @tag :capture_log
  test "a dead pid returns :ok (best-effort; never blocks the spawn)" do
    Application.put_env(:jido_claw, :doctrine, enabled?: true)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

    assert :ok = Startup.inject_subagent_prompt(dead, "coder", %{project_dir: File.cwd!()})
    refute_receive {:prompt_injected, _, _}, 300
  end

  # Start a real Coder worker on the default runtime: only a pid that actually
  # handles the ReAct `ai.react.set_system_prompt` signal proves the seam end to
  # end. Stopped in on_exit so a failing assertion never leaks the process.
  defp start_worker do
    tag = "ar5-startup-worker-#{System.unique_integer([:positive])}"
    {:ok, pid} = JidoClaw.Jido.start_subagent(Workers.Coder, id: tag)
    on_exit(fn -> JidoClaw.Jido.stop_agent(pid) end)
    pid
  end
end
