defmodule JidoClaw.Skills.Steps.AgentRunnerReviewDispatchTest do
  @moduledoc """
  Item 7 PR-3/PR-4 — the dispatch seam: `AgentRunner.run/7` consults
  `ReviewIndependence.apply_executor/4` between template resolution and
  executor dispatch, so a `.jido/config.yaml` `review: executor:` binding
  routes a `"reviewer"` step (whose STATIC template is `:in_process`) to the
  scripted codex vendor — as does a per-stage `executor:` override threaded
  through the trailing `run/7` argument (PR-4); an
  `:agent_templates_override` reviewer beats the knob at this live seam; an
  invalid knob config is a step error, never a silent in-process
  fall-through. (The nil-context "no config read" proof lives at the
  resolver seam — `review_independence_test.exs`'s `apply_executor/4`
  describe — an in-process reviewer dispatch would spawn a real LLM worker
  here.)

  Non-async: mutates global app env; vendor steps run REAL in-memory Forge
  sessions (persistence disabled — the `forge_executor_test` hermetic
  pattern).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.StepResult

  setup do
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :executor_vendor_runners)
      Application.delete_env(:jido_claw, :scripted_deposit_runner)
    end)

    project_dir =
      Path.join(System.tmp_dir!(), "jido_ri_dispatch_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(project_dir, ".jido"))
    on_exit(fn -> File.rm_rf!(project_dir) end)

    {:ok, project_dir: project_dir, context: %{project_dir: project_dir}}
  end

  defp arm_knob!(project_dir, yaml) do
    File.write!(Path.join([project_dir, ".jido", "config.yaml"]), yaml)
  end

  defp arm_codex_runner!(script) do
    Application.put_env(:jido_claw, :executor_vendor_runners, %{
      codex: JidoClaw.Test.ScriptedDepositRunner
    })

    Application.put_env(:jido_claw, :scripted_deposit_runner, script)
  end

  test "the knob routes the STATIC in-process reviewer template to the vendor", ctx do
    arm_knob!(ctx.project_dir, "review:\n  executor: codex\n")

    arm_codex_runner!(%{
      deposits: [],
      output: "knob-dispatched reviewer output",
      notify: self()
    })

    assert {:ok, %StepResult{} = result} =
             AgentRunner.run("reviewer", "review the diff", "review-step", ctx.context)

    assert result.result == "knob-dispatched reviewer output"

    # The scripted vendor runner really ran: config carries the hardwired
    # read-only posture + the knob-hydrated :repo workspace grant.
    assert_received {:scripted_deposit_runner, :config, config}
    assert config.access == :read_only
    assert config.cwd == ctx.project_dir

    assert_received {:scripted_deposit_runner, :prompt, prompt}
    assert prompt =~ "review the diff"
  end

  test "an :agent_templates_override reviewer beats the knob at the live seam", ctx do
    # The knob names claude_code — for which NO scripted runner is armed — so
    # a knob win would fail on the real ClaudeCode runner's credential sync.
    # The codex-bound override dispatching through the codex-only scripted
    # runner proves the override is authoritative at run/6, not just in the
    # resolver unit.
    arm_knob!(ctx.project_dir, "review:\n  executor: claude_code\n")

    Application.put_env(:jido_claw, :agent_templates_override, %{
      "reviewer" => %{
        module: JidoClaw.Agent.Workers.Reviewer,
        description: "override-bound reviewer",
        model: :fast,
        executor: {:forge, :codex}
      }
    })

    arm_codex_runner!(%{
      deposits: [],
      output: "override-dispatched reviewer output",
      notify: self()
    })

    assert {:ok, %StepResult{result: "override-dispatched reviewer output"}} =
             AgentRunner.run("reviewer", "review the diff", "review-step", ctx.context)

    assert_received {:scripted_deposit_runner, :config, _config}
  end

  test "an invalid knob executor_config is a step error — never a silent in-process fall-through",
       ctx do
    arm_knob!(
      ctx.project_dir,
      "review:\n  executor: codex\n  executor_config:\n    sandbox: local\n"
    )

    assert {:error, msg} =
             AgentRunner.run("reviewer", "review the diff", "review-step", ctx.context)

    assert msg =~ "Step reviewer setup failed"
    assert msg =~ "sandbox"
  end

  test "PR-4: a stage-level executor override dispatches through run/7 at the live seam", ctx do
    # No knob at all; the REAL in-process coder template is routed to the
    # scripted codex vendor by the trailing executor_override arg alone.
    arm_codex_runner!(%{
      deposits: [],
      output: "stage-override-dispatched coder output",
      notify: self()
    })

    assert {:ok, %StepResult{result: "stage-override-dispatched coder output"}} =
             AgentRunner.run(
               "coder",
               "implement the thing",
               "impl-step",
               ctx.context,
               nil,
               [],
               {:forge, :codex}
             )

    assert_received {:scripted_deposit_runner, :config, config}
    assert config.access == :read_only
    assert config.cwd == ctx.project_dir
  end

  test "a non-reviewer template never consults the knob", ctx do
    # A NON-MAP review section would refuse loudly if read. `sketch_build`
    # fails FAST at its own sandbox-scope validation (the temp dir is no
    # `.prototypes/` root — a pre-spawn refusal, so no worker/MCP machinery
    # runs) — reaching THAT error proves run/6 passed the overlay cleanly
    # without ever consulting the broken section.
    arm_knob!(ctx.project_dir, "review: broken\n")

    assert {:error, msg} =
             AgentRunner.run("sketch_build", "sketch it", "sketch-step", ctx.context)

    assert msg =~ "Step sketch_build setup failed"
    refute msg =~ "invalid_review_config"
  end
end
