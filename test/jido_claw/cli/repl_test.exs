defmodule JidoClaw.CLI.ReplTest do
  # resolve_strategy/1 calls StrategyRegistry.valid?/1, which talks to the
  # supervised StrategyStore GenServer — not safe to run async.
  use ExUnit.Case, async: false

  alias JidoClaw.CLI.Repl

  describe "resolve_strategy/1" do
    test "passes \"auto\" through unchanged (selector, not a registry entry)" do
      assert Repl.resolve_strategy("auto") == "auto"
    end

    test "passes a known built-in through unchanged" do
      assert Repl.resolve_strategy("cot") == "cot"
      assert Repl.resolve_strategy("tot") == "tot"
      assert Repl.resolve_strategy("react") == "react"
    end

    test "falls back to \"auto\" for an unknown strategy string" do
      assert Repl.resolve_strategy("totally_made_up_strategy") == "auto"
    end

    test "falls back to \"auto\" for a non-binary value (defensive)" do
      assert Repl.resolve_strategy(nil) == "auto"
      assert Repl.resolve_strategy(:cot) == "auto"
    end
  end

  describe "resolve_profile/1" do
    test "returns 'default' when ProfileManager has no recorded switch" do
      assert Repl.resolve_profile("unknown-workspace-#{System.unique_integer([:positive])}") ==
               "default"
    end

    test "returns 'default' for a non-binary input (defensive)" do
      assert Repl.resolve_profile(nil) == "default"
      assert Repl.resolve_profile(:atom) == "default"
    end

    test "reflects the ProfileManager-tracked active name after a switch" do
      ws = "repl-resolve-profile-#{System.unique_integer([:positive])}"

      :ok =
        JidoClaw.Shell.ProfileManager.replace_profiles_for_test(%{
          "default" => %{},
          "staging" => %{"K" => "v"}
        })

      try do
        assert Repl.resolve_profile(ws) == "default"
        assert {:ok, "staging"} = JidoClaw.Shell.ProfileManager.switch(ws, "staging")
        assert Repl.resolve_profile(ws) == "staging"
      after
        :ok = JidoClaw.Shell.ProfileManager.replace_profiles_for_test(%{})
        :ok = JidoClaw.Shell.ProfileManager.clear_active_for_test()
      end
    end
  end

  describe "prepare_user_message/2" do
    test "react returns the message unchanged (react is the agent's native loop)" do
      assert Repl.prepare_user_message("Explain GenServer", "react") == "Explain GenServer"
    end

    test "auto prepends the auto-specific hint naming reason(strategy: \"auto\")" do
      prepared = Repl.prepare_user_message("Explain GenServer", "auto")

      assert String.starts_with?(
               prepared,
               "[Reasoning preference: auto — invoke reason(strategy: \"auto\")"
             )

      assert String.ends_with?(prepared, "\n\nExplain GenServer")
    end

    test "a concrete strategy prepends a hint naming reason(strategy: \"<name>\")" do
      prepared = Repl.prepare_user_message("Explain GenServer", "cot")

      assert String.starts_with?(
               prepared,
               "[Reasoning preference: cot — invoke reason(strategy: \"cot\")"
             )

      assert String.ends_with?(prepared, "\n\nExplain GenServer")
    end

    test "tot also takes the concrete-strategy branch" do
      prepared = Repl.prepare_user_message("Plan a migration", "tot")

      assert prepared =~ "reason(strategy: \"tot\")"
      assert String.ends_with?(prepared, "Plan a migration")
    end
  end
end
