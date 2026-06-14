defmodule JidoClaw.CLI.ReplTest do
  # resolve_strategy/1 calls StrategyRegistry.valid?/1, which talks to the
  # supervised StrategyStore GenServer — not safe to run async.
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry
  alias JidoClaw.Agent.Templates
  alias JidoClaw.CLI.Repl
  alias JidoClaw.Config
  alias JidoClaw.Shell.ProfileManager

  # Stub runtime for the handoff-routed seam test: the worker doesn't exist yet
  # (whereis → nil) so the router starts it, and start_subagent hands back the
  # parked pid the test stashed in app env. Mirrors FakeJido in
  # send_to_agent_test — this is the `ensure_worker_pid/2` seam, so no real
  # agent process boots.
  defmodule FakeRuntime do
    @moduledoc false

    @spec whereis(String.t()) :: nil
    def whereis(_agent_id), do: nil

    @spec start_subagent(module(), keyword()) :: {:ok, pid()}
    def start_subagent(_module, _opts) do
      {:ok, Application.fetch_env!(:jido_claw, :repl_test_worker_pid)}
    end
  end

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
        ProfileManager.replace_profiles_for_test(%{
          "default" => %{},
          "staging" => %{"K" => "v"}
        })

      try do
        assert Repl.resolve_profile(ws) == "default"
        assert {:ok, "staging"} = ProfileManager.switch(ws, "staging")
        assert Repl.resolve_profile(ws) == "staging"
      after
        :ok = ProfileManager.replace_profiles_for_test(%{})
        :ok = ProfileManager.clear_active_for_test()
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

  # Regression for the §5 dialyzer fix: the REPL's display-config path
  # destructures `%{limits: %{context: cw}}`, and the custom Ollama
  # registry in `config/config.exs` declares its limits with the
  # canonical `:context`/`:output` keys (not the LLMDB-stripped
  # `:context_window`/`:max_output_tokens` legacy keys). Verifying the
  # round-trip here keeps the two surfaces from drifting again.
  describe "Config.model_info/1 on custom Ollama models" do
    test "qwen3:32b resolves with limits.context populated" do
      assert {:ok, %{limits: %{context: 131_072}}} =
               Config.model_info(%{"model" => "ollama:qwen3:32b"})
    end

    test "nemotron-3-super:cloud resolves with the 262K context" do
      assert {:ok, %{limits: %{context: 262_144}}} =
               Config.model_info(%{"model" => "ollama:nemotron-3-super:cloud"})
    end
  end

  # Parity for the §P2 fix: the REPL dispatch path must eagerly attach the
  # *routed* worker's template-allowlisted external MCP tools before the turn
  # (the programmatic chat/4 path already does — see
  # handoff_dispatcher_integration_test.exs). Both tests drive the seam through
  # the MCPFacadeCapture double and stay DB-free (session_uuid: nil →
  # the router never reads Postgres).
  describe "resolve_owner_and_attach/1 attaches the routed worker's MCP tools" do
    setup do
      prev_facade = Application.get_env(:jido_claw, :mcp_facade)
      prev_target = Application.get_env(:jido_claw, :mcp_facade_capture_target)

      Application.put_env(:jido_claw, :mcp_facade, JidoClaw.Test.MCPFacadeCapture)
      Application.put_env(:jido_claw, :mcp_facade_capture_target, self())

      on_exit(fn ->
        restore_env(:mcp_facade, prev_facade)
        restore_env(:mcp_facade_capture_target, prev_target)
      end)

      :ok
    end

    test "no-handoff turn attaches the routed (main) pid/template — the first-turn race fix" do
      main_pid = parked_pid()

      state = %Repl{
        agent_pid: main_pid,
        agent_id: "main",
        tenant_id: "default",
        session_id: "repl-no-handoff-#{System.unique_integer([:positive])}",
        session_uuid: nil,
        cwd: nil
      }

      # No owner + session_uuid: nil ⇒ router returns the default tuple without
      # touching Postgres; the bounded attach threads the routed (main) pid.
      assert {^main_pid, "main", "main", false, nil} = Repl.resolve_owner_and_attach(state)
      assert_receive {:mcp_ensure_attached, ^main_pid, "main", 8_000}
    end

    test "handoff-routed turn attaches the worker pid under its template — the headline P2" do
      prev_runtime = Application.get_env(:jido_claw, :jido_runtime)

      main_pid = parked_pid()
      worker_pid = parked_pid()

      Application.put_env(:jido_claw, :jido_runtime, FakeRuntime)
      Application.put_env(:jido_claw, :repl_test_worker_pid, worker_pid)

      on_exit(fn ->
        restore_env(:jido_runtime, prev_runtime)
        Application.delete_env(:jido_claw, :repl_test_worker_pid)
      end)

      tenant = "default"
      session = "repl-handoff-#{System.unique_integer([:positive])}"

      {:ok, reviewer_tpl} = Templates.get("reviewer")

      # Seed the in-memory registry with a routed "reviewer" owner. The non-nil
      # handoff.session_uuid is what effective_uuid falls back to (keeps routing
      # on the owner path, DB-free); preamble_consumed?: true ⇒ first_post_handoff?
      # is false. cwd: nil ⇒ project_dir: nil short-circuits prompt injection.
      handoff =
        Handoff.new(%{
          tenant_id: tenant,
          runtime_session_id: session,
          session_uuid: Ecto.UUID.generate(),
          to_template: "reviewer",
          to_module: reviewer_tpl.module,
          message: Handoff.rehydrated_marker()
        })

      :ok = HandoffRegistry.put_owner(tenant, session, handoff, preamble_consumed?: true)
      on_exit(fn -> HandoffRegistry.clear(tenant, session) end)

      state = %Repl{
        agent_pid: main_pid,
        agent_id: "main",
        tenant_id: tenant,
        session_id: session,
        session_uuid: nil,
        cwd: nil
      }

      assert {^worker_pid, "reviewer", _agent_id, false, _owner} =
               Repl.resolve_owner_and_attach(state)

      refute worker_pid == main_pid
      assert_receive {:mcp_ensure_attached, ^worker_pid, "reviewer", 8_000}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)

  # A parked, alive pid that satisfies the router's `is_pid/1` guards and the
  # facade double's pid plumbing without booting a real agent. Killed on exit.
  defp parked_pid do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
