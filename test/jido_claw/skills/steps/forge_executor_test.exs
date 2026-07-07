defmodule JidoClaw.Skills.Steps.ForgeExecutorTest do
  @moduledoc """
  Item 7 (camus C1-1) PR-1: the AgentRunner→Forge bridge, driven against REAL
  in-memory Forge sessions (persistence disabled — the `ready_start_test`
  hermetic pattern; `sandbox: :local` → HostShell per-run tmp dirs). Direct
  `ForgeExecutor.run/5` calls, so no correlation/transcript rows — the shared
  AgentRunner envelope is covered in `agent_runner_test.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Skills.Steps.ForgeExecutor
  alias JidoClaw.Workflows.StepResult

  @coder JidoClaw.Agent.Workers.Coder

  setup do
    prev = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
    end)

    %{pre_sessions: Forge.list_sessions()}
  end

  defp fake_template, do: %{module: @coder, executor: {:forge, :fake}, executor_config: %{}}

  defp shell_template(command),
    do: %{module: @coder, executor: {:forge, :shell}, executor_config: %{command: command}}

  defp coder_fixture(summary) do
    %{
      "summary" => summary,
      "status" => "completed",
      "files_changed" => ["lib/thing.ex"],
      "notes" => "n/a",
      "artifacts" => %{}
    }
  end

  defp assert_no_leaked_sessions(%{pre_sessions: pre}) do
    assert Forge.list_sessions() -- pre == [],
           "expected every bridge session torn down, got: #{inspect(Forge.list_sessions() -- pre)}"
  end

  describe "{:forge, :fake} through a real session" do
    test "serves the armed fixture, schema-validated, and tears the session down", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "coder" => coder_fixture("Implemented the thing.")
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", fake_template(), "do it", "step-1", %{})

      # Validated against the Coder's real coder_result schema: atom keys,
      # atom status enum — the live worker shape, not the raw fixture.
      assert result.typed_output.summary == "Implemented the thing."
      assert result.typed_output.status == :completed
      assert result.result == "Implemented the thing."
      assert result.name == "step-1"
      assert result.template == "coder"

      assert_no_leaked_sessions(ctx)
    end

    test "an invalid fixture yields typed_output nil (result still built) — never a fabricated shape",
         ctx do
      # Missing the required status/files_changed/notes → Zoi rejects it, and
      # the run still completes with the live-faithful validation-failed shape.
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "coder" => %{"summary" => "did stuff"}
      })

      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", fake_template(), "do it", "step-1", %{})

      assert result.typed_output == nil
      assert result.result == "did stuff"

      assert_no_leaked_sessions(ctx)
    end

    test "a missing fixture fails closed BEFORE any session starts", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{})

      assert {:error, msg} = ForgeExecutor.run("coder", fake_template(), "do it", "s", %{})
      assert msg =~ "no fake output armed for 'coder'"
      assert msg =~ ":executor_fake_outputs"

      assert_no_leaked_sessions(ctx)
    end
  end

  describe "fixture resolution ({:stage, _, _} > {:fragment, _, _} > plain)" do
    test "an exact stage key beats a matching fragment and the plain key" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        {:fragment, "coder", "frag"} => coder_fixture("fragment fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "stage fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "task with frag", "s1", %{})
    end

    test "a single matching fragment serves when no stage key matches" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        {:fragment, "coder", "frag"} => coder_fixture("fragment fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "fragment fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "task with frag", "s2", %{})
    end

    test "zero fragment matches fail closed — no arbitrary pick, no plain fallback, no session",
         ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:fragment, "coder", "frag-a"} => coder_fixture("a"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "task without markers", "s", %{})

      assert msg =~ "exactly one {:fragment"
      assert_no_leaked_sessions(ctx)
    end

    test "several fragment matches fail closed too", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:fragment, "coder", "frag-a"} => coder_fixture("a"),
        {:fragment, "coder", "frag-b"} => coder_fixture("b")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "task frag-a and frag-b", "s", %{})

      assert msg =~ "exactly one {:fragment"
      assert_no_leaked_sessions(ctx)
    end

    test "tuple keys disable the plain fallback for an unkeyed sibling stage", ctx do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "coder", "s1"} => coder_fixture("stage fixture"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "no fragments here", "s2", %{})

      assert msg =~ "tuple keys for 'coder' disable the plain"
      assert_no_leaked_sessions(ctx)
    end

    test "a template with no tuple keys uses the plain key; other templates' tuple keys don't interfere" do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        {:stage, "reviewer", "r1"} => coder_fixture("reviewer stage"),
        "coder" => coder_fixture("plain fixture")
      })

      assert {:ok, %StepResult{result: "plain fixture"}} =
               ForgeExecutor.run("coder", fake_template(), "any task", "s1", %{})
    end
  end

  describe "{:forge, :shell} through HostShell" do
    test "runs the template-declared command; stdout is the step result", ctx do
      assert {:ok, %StepResult{} = result} =
               ForgeExecutor.run("coder", shell_template("printf step-out"), "task", "s", %{})

      # Non-JSON stdout fails coder-schema validation softly → typed nil,
      # stdout verbatim as the result text.
      assert result.result == "step-out"
      assert result.typed_output == nil

      assert_no_leaked_sessions(ctx)
    end

    test "a nonzero exit maps to a step error (with the session still torn down)", ctx do
      assert {:error, msg} =
               ForgeExecutor.run("coder", shell_template("exit 3"), "task", "s", %{})

      assert msg =~ "exit code 3"
      assert_no_leaked_sessions(ctx)
    end
  end
end
