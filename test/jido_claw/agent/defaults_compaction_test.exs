defmodule JidoClaw.Agent.DefaultsCompactionTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.Config

  defmodule TestAgentAuto do
    use JidoClaw.Agent.Defaults,
      name: "test_agent_auto",
      description: "test",
      tools: [],
      model: :fast,
      max_iterations: 1,
      streaming: false,
      tool_timeout_ms: 10_000,
      compaction: [
        mode: :auto,
        max_messages: 80,
        recompact_delta_threshold: 40,
        keep_last_turns: 4,
        protect_first_n_turns: 1
      ]
  end

  defmodule TestAgentOff do
    use JidoClaw.Agent.Defaults,
      name: "test_agent_off",
      description: "test",
      tools: [],
      model: :fast,
      max_iterations: 1,
      streaming: false,
      tool_timeout_ms: 10_000,
      compaction: [mode: :off]
  end

  defmodule TestAgentDefault do
    use JidoClaw.Agent.Defaults,
      name: "test_agent_default",
      description: "test",
      tools: [],
      model: :fast,
      max_iterations: 1,
      streaming: false,
      tool_timeout_ms: 10_000
  end

  describe "__compaction_config__/0" do
    test "round-trips an explicit auto config" do
      cfg = TestAgentAuto.__compaction_config__()
      assert %Config{} = cfg
      assert cfg.mode == :auto
      assert cfg.max_messages == 80
      assert cfg.keep_last_turns == 4
    end

    test "round-trips an explicit off config" do
      cfg = TestAgentOff.__compaction_config__()
      assert %Config{mode: :off} = cfg
    end

    test "defaults to off when no :compaction opt is supplied" do
      cfg = TestAgentDefault.__compaction_config__()
      assert %Config{mode: :off} = cfg
    end
  end

  describe "wired workers" do
    test "all worker templates compact on :auto (per-agent keying landed in T1-2)" do
      workers = [
        JidoClaw.Agent.Workers.Coder,
        JidoClaw.Agent.Workers.Reviewer,
        JidoClaw.Agent.Workers.Researcher,
        JidoClaw.Agent.Workers.TestRunner,
        JidoClaw.Agent.Workers.DocsWriter,
        JidoClaw.Agent.Workers.Refactorer,
        JidoClaw.Agent.Workers.Verifier
      ]

      for mod <- workers do
        cfg = mod.__compaction_config__()
        assert %Config{mode: :auto} = cfg, "expected #{inspect(mod)} to compact on :auto"
      end
    end

    test "main JidoClaw.Agent has :auto compaction" do
      cfg = JidoClaw.Agent.__compaction_config__()
      assert %Config{mode: :auto} = cfg
    end
  end
end
