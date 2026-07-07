defmodule JidoClaw.Skills.Steps.ForgeExecutorNeedsInputTest do
  @moduledoc """
  Item 7 PR-4 (camus C1-1 sketch (e)) — the `:needs_input` → gate-case
  answer-loop at the executor seam: a runner's `:needs_input` iteration
  raises a durable pending `AgentCase` (kind `:needs_input`) and the step
  still errors (existing failure lanes — no composer park); an
  operator-approved answer is claimed single-use by the stage's NEXT attempt
  and injected into the vendor prompt (after the task, before the deposit
  instruction); reject/pending never inject, and the session arm raises
  without ever claiming.

  TenantCase (non-async): case rows hit the DB under the shared sandbox;
  Forge persistence disabled (the hermetic pattern); the vendor arm runs the
  ScriptedDepositRunner.
  """
  use JidoClaw.TenantCase, async: false

  @moduletag :capture_log

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Skills.Steps.ForgeExecutor
  alias JidoClaw.Workflows.StepResult

  @coder JidoClaw.Agent.Workers.Coder

  setup do
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)

    Application.put_env(:jido_claw, :executor_vendor_runners, %{
      codex: JidoClaw.Test.ScriptedDepositRunner
    })

    on_exit(fn ->
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
      Application.delete_env(:jido_claw, :executor_vendor_runners)
      Application.delete_env(:jido_claw, :scripted_deposit_runner)
      Application.delete_env(:jido_claw, :executor_fake_outputs)
    end)

    project_dir = Path.join(System.tmp_dir!(), "ni_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf(project_dir) end)

    %{tenant_id: tenant, session: session} = seed_full(tenant_label: "needsinput")
    actor = actor_for(tenant)

    context = %{
      tenant: tenant,
      actor: actor,
      session_uuid: session.id,
      session_id: session.external_id,
      project_dir: project_dir
    }

    {:ok, tenant: tenant, actor: actor, session: session, context: context}
  end

  defp vendor_template,
    do: %{module: @coder, executor: {:forge, :codex}, executor_config: %{workspace: :repo}}

  defp fake_template, do: %{module: @coder, executor: {:forge, :fake}, executor_config: %{}}

  defp pending_needs_input_cases(ctx) do
    {:ok, cases} = AgentCase.pending_for_tenant(tenant: ctx.tenant, actor: ctx.actor)
    Enum.filter(cases, &(&1.kind == :needs_input))
  end

  test "(1) a vendor needs_input raises the case + a gate-id step error, question redacted in BOTH sinks",
       ctx do
    secret = "sk-ant-" <> String.duplicate("a", 24)

    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      needs_input: "Which env should I target? My key is #{secret}"
    })

    assert {:error, msg} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert [agent_case] = pending_needs_input_cases(ctx)

    # The step error names the gate id and carries the REDACTED question.
    assert msg =~ "needs operator input"
    assert msg =~ agent_case.id
    refute msg =~ secret
    assert msg =~ "[REDACTED:ANTHROPIC_KEY]"

    # The durable case: provenance + the redacted question in details.
    assert agent_case.kind == :needs_input
    assert agent_case.step_name == "v-step"
    assert agent_case.workflow_run_id == nil
    assert agent_case.session_id == ctx.session.id
    assert agent_case.details["template"] == "coder"
    assert agent_case.details["injectable"] == true
    assert is_binary(agent_case.details["resume_hint"])
    refute agent_case.details["question"] =~ secret
    assert agent_case.details["question"] =~ "[REDACTED:ANTHROPIC_KEY]"
  end

  test "(2) a retry while pending reuses the case — no duplicate, first question wins", ctx do
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{needs_input: "First question?"})

    assert {:error, _} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert [first] = pending_needs_input_cases(ctx)

    # The retry rephrases the ask — the identity is question-agnostic, so the
    # pending case is reused and keeps its ORIGINAL question.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{
      needs_input: "Second phrasing of the same question?"
    })

    assert {:error, msg} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert msg =~ first.id
    assert [reused] = pending_needs_input_cases(ctx)
    assert reused.id == first.id
    assert reused.details["question"] == "First question?"
  end

  test "(3) an approved answer injects on the NEXT attempt (after task, before deposit) and consumes",
       ctx do
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{needs_input: "Which database?"})

    assert {:error, _} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert [agent_case] = pending_needs_input_cases(ctx)

    assert {:ok, %AgentCase{}} =
             Cases.decide(agent_case.id, :approve, %{decision_comment: "Use postgres"},
               tenant: ctx.tenant,
               actor: ctx.actor
             )

    # Attempt 2: the runner completes; the prompt carries the injected answer.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

    assert {:ok, %StepResult{}} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert_receive {:scripted_deposit_runner, :prompt, prompt}
    assert prompt =~ "An operator answered an earlier request"
    assert prompt =~ "Use postgres"

    # Position: after the task, before the deposit instruction (deposit LAST).
    assert [pre, post] = String.split(prompt, "An operator answered", parts: 2)
    assert pre =~ "do it"
    assert post =~ "submit_structured_output"

    # Consumed single-use.
    {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant, actor: ctx.actor)
    assert reloaded.consumed_at != nil

    # Attempt 3: nothing left to claim — a fresh ask opens a FRESH case.
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{needs_input: "Which database?"})

    assert {:error, _} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert [fresh] = pending_needs_input_cases(ctx)
    refute fresh.id == agent_case.id
  end

  test "(4) a rejected case never injects — the next ask opens a fresh case", ctx do
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{needs_input: "May I proceed?"})

    assert {:error, _} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert [agent_case] = pending_needs_input_cases(ctx)

    assert {:ok, %AgentCase{}} =
             Cases.decide(agent_case.id, :reject, %{}, tenant: ctx.tenant, actor: ctx.actor)

    # Attempt 2: no injection block in the prompt (rejected is never consumed).
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{deposits: [], notify: self()})

    assert {:ok, %StepResult{}} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", ctx.context)

    assert_receive {:scripted_deposit_runner, :prompt, prompt}
    refute prompt =~ "An operator answered"

    {:ok, reloaded} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant, actor: ctx.actor)
    assert reloaded.consumed_at == nil
  end

  test "(5) the session arm (:fake) raises with injectable: false and never claims", ctx do
    Application.put_env(:jido_claw, :executor_fake_outputs, %{
      "coder" => %{status: :needs_input, question: "Session-arm question?"}
    })

    assert {:error, msg} =
             ForgeExecutor.run("coder", fake_template(), "do it", "s-step", ctx.context)

    assert msg =~ "needs operator input"
    assert [agent_case] = pending_needs_input_cases(ctx)
    assert agent_case.details["injectable"] == false

    # Approve, then re-run the session arm: the approval is NEVER claimed
    # (claim lives in the vendor clause only) — a fresh pending case opens.
    assert {:ok, %AgentCase{}} =
             Cases.decide(agent_case.id, :approve, %{decision_comment: "an answer"},
               tenant: ctx.tenant,
               actor: ctx.actor
             )

    assert {:error, _} =
             ForgeExecutor.run("coder", fake_template(), "do it", "s-step", ctx.context)

    {:ok, approved} = AgentCase.by_id(agent_case.id, tenant: ctx.tenant, actor: ctx.actor)
    assert approved.consumed_at == nil

    assert [fresh] = pending_needs_input_cases(ctx)
    refute fresh.id == agent_case.id
  end

  test "(6) :blocked / :continue stay plain single-shot step errors — no case raised", ctx do
    for status <- [:blocked, :continue] do
      Application.put_env(:jido_claw, :executor_fake_outputs, %{
        "coder" => %{status: status, output: nil}
      })

      assert {:error, msg} =
               ForgeExecutor.run("coder", fake_template(), "do it", "s-step", ctx.context)

      assert msg =~ "single-shot"
    end

    assert pending_needs_input_cases(ctx) == []
  end

  test "(7) a no-tenant context still returns the step error — no case, fail-open", ctx do
    Application.put_env(:jido_claw, :scripted_deposit_runner, %{needs_input: "Anyone there?"})

    assert {:error, msg} =
             ForgeExecutor.run("coder", vendor_template(), "do it", "v-step", %{
               project_dir: ctx.context.project_dir
             })

    assert msg =~ "needs operator input"
    assert pending_needs_input_cases(ctx) == []
  end
end
