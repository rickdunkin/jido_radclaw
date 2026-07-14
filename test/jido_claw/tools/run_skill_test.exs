defmodule JidoClaw.Tools.RunSkillTest do
  @moduledoc """
  Pure-function unit tests for the canonical `scope_context/1` helper —
  the chokepoint that decides which `tool_context` keys propagate from
  the parent agent into workflow drivers (and from there into child
  agents). The Phase 0 attribution chain breaks if `:user_id` is dropped
  here.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.LoopGuard
  alias JidoClaw.TestSupport.HostileInspect
  alias JidoClaw.Tools.RunSkill

  describe "scope_context/1" do
    test "carries :user_id through to the workflow scope" do
      ctx = %{
        tenant_id: "t",
        session_id: "s",
        session_uuid: "u-session",
        workspace_id: "ws",
        workspace_uuid: "u-ws",
        project_dir: "/tmp",
        user_id: "u-user",
        agent_id: "should-be-stripped",
        forge_session_key: "should-be-stripped",
        random_extra_key: "should-be-stripped"
      }

      out = RunSkill.scope_context(ctx)

      assert out == %{
               tenant_id: "t",
               session_id: "s",
               session_uuid: "u-session",
               workspace_id: "ws",
               workspace_uuid: "u-ws",
               project_dir: "/tmp",
               user_id: "u-user"
             }
    end

    test "missing keys produce a smaller map (no nil padding)" do
      out = RunSkill.scope_context(%{tenant_id: "t", user_id: "u"})

      assert out == %{tenant_id: "t", user_id: "u"}
    end

    test "empty input produces an empty scope" do
      assert RunSkill.scope_context(%{}) == %{}
    end
  end

  describe "unknown_skill_envelope/1 (PD1-2 producer)" do
    test "typed code + bounded requested name + retry: false + available hint" do
      envelope = RunSkill.unknown_skill_envelope("no_such_skill")

      assert envelope.code == :unknown_skill
      assert envelope.message == "Skill 'no_such_skill' not found."
      assert envelope.details.retry == false
      assert envelope.details.skill == "no_such_skill"
      assert is_list(envelope.details.available)
      # Canonicalized: the hint list arrives sorted.
      assert envelope.details.available == Enum.sort(envelope.details.available)
    end

    test "an overlong requested name is bounded UTF-8-safely in message and details" do
      # 300 two-byte characters: the 256-byte cut lands mid-character.
      long = String.duplicate("é", 300)
      envelope = RunSkill.unknown_skill_envelope(long)

      assert byte_size(envelope.details.skill) <= 256
      assert String.valid?(envelope.details.skill)
      assert String.valid?(envelope.message)
    end

    test "the full run/2 path maps a registry miss to the typed envelope" do
      assert {:error, envelope} =
               RunSkill.run(%{skill: "definitely_not_a_registered_skill"}, %{})

      assert envelope.code == :unknown_skill
      assert envelope.details.retry == false
      assert envelope.details.skill == "definitely_not_a_registered_skill"
    end
  end

  describe "runner_failure_envelope/2 (PD1-2 §2 normalization)" do
    test ":cancelled maps to :skill_cancelled with retry: false + discriminators" do
      envelope = RunSkill.runner_failure_envelope("my_skill", :cancelled)

      assert envelope.code == :skill_cancelled
      assert envelope.message =~ "my_skill"
      assert envelope.details.retry == false
      assert envelope.details.skill == "my_skill"
      assert envelope.details.reason_head == "cancelled"
    end

    test "every other reason maps to :skill_run_failed with the bounded reason preserved" do
      envelope = RunSkill.runner_failure_envelope("my_skill", {:exit, :timeout})

      assert envelope.code == :skill_run_failed
      assert envelope.message =~ "my_skill"
      assert envelope.message =~ "exit.timeout"
      assert envelope.details.retry == false
      assert envelope.details.skill == "my_skill"
      assert envelope.details.reason_head == "exit.timeout"
      assert envelope.details.reason == ["exit", "timeout"]
    end

    test "an aggregate-huge reason is budget-bounded, never carried whole" do
      huge = Map.new(1..100_000, fn i -> {"k#{i}", String.duplicate("v", 10)} end)
      envelope = RunSkill.runner_failure_envelope("my_skill", {:step_failed, huge})

      assert envelope.code == :skill_run_failed
      assert envelope.details.retry == false
      assert byte_size(inspect(envelope.details)) < 64 * 1024
    end

    test "atom, improper-list, and hostile-struct reasons stay total" do
      for reason <- [
            :fenced,
            [1 | 2],
            %HostileInspect.Throwing{x: 1}
          ] do
        envelope = RunSkill.runner_failure_envelope("my_skill", reason)

        assert envelope.code == :skill_run_failed
        assert envelope.details.retry == false
        assert is_binary(envelope.details.reason_head)
      end
    end

    test "distinct reasons/skills produce distinct LoopGuard identities; repeats stay identical" do
      sig = fn envelope ->
        {:failure, sig} = LoopGuard.classify_result({:error, envelope}, %{})
        sig
      end

      timeout_a = sig.(RunSkill.runner_failure_envelope("alpha", {:exit, :timeout}))
      timeout_a2 = sig.(RunSkill.runner_failure_envelope("alpha", {:exit, :timeout}))
      killed_a = sig.(RunSkill.runner_failure_envelope("alpha", {:exit, :killed}))
      timeout_b = sig.(RunSkill.runner_failure_envelope("bravo", {:exit, :timeout}))

      # Same failure twice → same identity (determinism).
      assert timeout_a.identity == timeout_a2.identity
      # Same-head/different-tail reasons split via reason_head.
      refute timeout_a.identity == killed_a.identity
      # Equal-length skill names split via the exact-kept skill value.
      refute timeout_a.identity == timeout_b.identity
    end
  end
end
