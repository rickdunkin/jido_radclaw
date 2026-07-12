defmodule JidoClaw.Memory.Consolidator.RunServerTest.ScriptedRunner do
  @moduledoc false
  # Per-turn scripted consolidator runner: the test injects a
  # `(state, opts) -> {:ok, iteration_result}` fun via the
  # `:consolidator_scripted_turn` app env (async: false suite). Unlike
  # `Runners.Fake`, it can span multiple turns, speak MCP against the
  # tokenized per-attempt URL from opts, and hang — the substrate for the
  # multi-iteration loop, closed-token, and watchdog tests.
  @behaviour JidoClaw.Forge.Runner

  @impl JidoClaw.Forge.Runner
  def init(_client, config), do: {:ok, %{prompt: Map.get(config, :prompt, "")}}

  @impl JidoClaw.Forge.Runner
  def run_iteration(_client, state, opts) do
    fun = Application.get_env(:jido_claw, :consolidator_scripted_turn)
    fun.(state, opts)
  end

  @impl JidoClaw.Forge.Runner
  def apply_input(_client, _input, _state), do: :ok
end

defmodule JidoClaw.Memory.Consolidator.RunServerTest do
  @moduledoc """
  End-to-end regression coverage for the per-run consolidator pipeline.

  Drives `Consolidator.run_now/2` against the `:fake` runner so the full
  bootstrap → MCP-roundtrip → publish path is exercised without standing
  up a frontier-model harness. The bootstrap-race fix and three of the
  same code review's 3b behaviours (link forwarding, propose_update +
  supersedes link, defer_cluster watermark) are pinned here so a future
  regression that re-introduces the race or drops a forwarded field
  fails fast.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Forge.Manager, as: ForgeManager
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Forge.Runner, as: ForgeRunner
  alias JidoClaw.MCP.LoopbackClient
  alias JidoClaw.Memory.{Block, ConsolidationRun, Fact, Link}
  alias JidoClaw.Memory.Consolidator
  alias JidoClaw.Memory.Consolidator.Clusterer
  alias JidoClaw.Memory.Consolidator.RunServerTest.ScriptedRunner
  alias JidoClaw.Memory.Consolidator.TestSupport.PromptCapture
  alias JidoClaw.Workspaces.Resolver

  @consolidator_key JidoClaw.Memory.Consolidator

  setup do
    # Shared sandbox so cross-process writes (RunServer, harness Task,
    # Bandit workers) are visible to every spawned process AND get
    # rolled back at test teardown. The advisory-lock bypass is
    # required because `LockOwner.hold/2` pins a Postgres connection
    # for the run's duration via `Repo.checkout/1` — that's
    # incompatible with shared mode's single routed connection. Lock
    # semantics are covered separately in `lock_owner_test.exs`.
    prev = Application.get_env(:jido_claw, @consolidator_key, [])
    prev_persist = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
    Application.put_env(:jido_claw, :consolidator_advisory_lock_disabled?, true)

    Application.put_env(:jido_claw, @consolidator_key,
      enabled: true,
      min_input_count: 0,
      write_skip_rows: true,
      harness: :fake,
      harness_options: [sandbox_mode: :local, timeout_ms: 30_000, max_turns: 60]
    )

    on_exit(fn ->
      Application.put_env(:jido_claw, @consolidator_key, prev)
      Application.put_env(:jido_claw, :consolidator_advisory_lock_disabled?, false)
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_persist)
    end)

    %{tenant_id: seed_tenant("run-server")}
  end

  describe "end-to-end fake-harness run" do
    test "succeeded run writes a block + fact when proposals stage cleanly", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"propose_block_update",
                    %{label: "core_facts", new_content: "shipping enabled"}},
                   {"propose_add",
                    %{
                      content: "We ship to Canada",
                      tags: ["geography"],
                      label: "geo"
                    }}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded, "run failed: #{inspect(run)}"
      assert run.harness == :fake
      assert run.blocks_written >= 1
      assert run.facts_added >= 1

      blocks =
        Block.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      assert Enum.any?(blocks, &(&1.label == "core_facts" and &1.value =~ "shipping"))

      facts =
        Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      assert Enum.any?(facts, &(&1.label == "geo" and &1.content =~ "Canada"))
    end

    test "revise of an active block counts blocks_revised, not blocks_written", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      # Seed an active block so the consolidator's propose_block_update for the
      # same (scope, label) takes the REVISE branch (an active prior exists),
      # not the write branch.
      seed_active_block!(scope, "core_facts", "shipping enabled")

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"propose_block_update",
                    %{label: "core_facts", new_content: "shipping enabled to Canada"}}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded, "run failed: #{inspect(run)}"

      # 1.5 fix: a revise increments blocks_revised (hardcoded 0 forever before
      # the fix) and does NOT count toward blocks_written — the writes-only
      # semantic. Exact counts (not >=) pin the split.
      assert run.blocks_revised == 1
      assert run.blocks_written == 0
    end

    test "propose_link forwards relation, reason, confidence to a Link row", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      # Distinct labels: Fact.record/1's InvalidatePriorActiveLabel hook
      # invalidates any active row at the same `(tenant, scope, label)`,
      # so reusing a label here would make one of the two seeds historical
      # and break the same-scope link assertion.
      fact_a = seed_fact_simple!(scope, "link_source")
      fact_b = seed_fact_simple!(scope, "link_target")

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"propose_link",
                    %{
                      from_fact_id: fact_a.id,
                      to_fact_id: fact_b.id,
                      relation: "supports",
                      reason: "consolidator_evidence",
                      confidence: 0.85
                    }}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded
      assert run.links_added >= 1

      links =
        Link.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      created = Enum.find(links, &(&1.from_fact_id == fact_a.id and &1.to_fact_id == fact_b.id))

      refute is_nil(created)
      assert created.relation == :supports
      assert created.reason == "consolidator_evidence"
      assert created.confidence == 0.85
      assert created.written_by == "consolidator"
    end

    test "propose_update invalidates original + writes replacement + writes :supersedes link",
         %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)

      original = seed_fact_simple!(scope, "vacation_plans")

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"propose_update",
                    %{
                      fact_id: original.id,
                      new_content: "updated content",
                      tags: ["v2"]
                    }}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded
      assert run.facts_added >= 1
      assert run.facts_invalidated >= 1
      assert run.links_added >= 1

      # Original row has a label, so the invalidation comes from
      # Fact.record/1's InvalidatePriorActiveLabel hook when the
      # replacement row is written — NOT from
      # maybe_invalidate_unlabeled/1, which short-circuits for labeled
      # facts.
      reloaded =
        Fact.by_id!(original.id,
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      refute is_nil(reloaded.invalid_at)

      facts =
        Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      replacement =
        Enum.find(facts, fn f ->
          f.label == "vacation_plans" and f.id != original.id and is_nil(f.invalid_at)
        end)

      refute is_nil(replacement)
      assert replacement.content == "updated content"
      assert replacement.tags == ["v2"]
      assert replacement.source == :consolidator_promoted

      links =
        Link.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      supersedes =
        Enum.find(links, fn l ->
          l.relation == :supersedes and l.from_fact_id == replacement.id and
            l.to_fact_id == original.id
        end)

      refute is_nil(supersedes)
      assert supersedes.written_by == "consolidator"
    end

    test "defer_cluster (facts) — watermark stops at row before deferred cluster", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      # Truncate to microseconds — the Ash attributes are
      # `:utc_datetime_usec` and an unrounded `DateTime.utc_now/0` can
      # produce equality surprises after Postgres round-trip.
      t0 = DateTime.truncate(DateTime.utc_now(), :microsecond)
      a = seed_fact_at!(scope, "label_a", t0)
      b = seed_fact_at!(scope, "label_b", DateTime.add(t0, 1, :second))
      _c = seed_fact_at!(scope, "label_c", DateTime.add(t0, 2, :second))

      # Public clusterer — avoids duplicating the private hash formula
      # and will stay in sync if the cluster_id derivation changes.
      [%{id: b_cluster_id}] = Clusterer.cluster([b], 1)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"defer_cluster", %{cluster_id: b_cluster_id, reason: "needs review"}}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded
      assert run.facts_processed_until_at == a.inserted_at
      assert run.facts_processed_until_id == a.id
    end

    test "defer_cluster (messages) — single-cluster defer pins watermark to nil", %{
      tenant_id: tenant_id
    } do
      {_ws, session, scope} = session_scope(tenant_id)

      t0 = DateTime.truncate(DateTime.utc_now(), :microsecond)
      _ = seed_message_at!(session, "msg one", t0, 1)
      _ = seed_message_at!(session, "msg two", DateTime.add(t0, 1, :second), 2)
      _ = seed_message_at!(session, "msg three", DateTime.add(t0, 2, :second), 3)

      # Clusterer.cluster_messages/2 keys clusters by session_id.
      message_cluster_id = "messages:#{session.id}"

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [
                   {"defer_cluster", %{cluster_id: message_cluster_id, reason: "needs review"}}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      # CONSTRAINT: `Message.for_consolidator` is restricted to `:session`
      # scope in 3b, so a single session produces exactly one message
      # cluster covering every loaded message. Deferring it defers
      # everything and `contiguous_prefix/2` returns `{nil, nil}`.
      # Cross-session message consolidation (the deferred 3c extension)
      # would change this assertion shape — once messages can come from
      # multiple sessions, this test should mirror the facts variant
      # above and assert the row-before-deferred watermark instead.
      assert run.status == :succeeded
      assert run.messages_processed_until_at == nil
      assert run.messages_processed_until_id == nil
    end

    test "fake_proposals: [] → succeeded run with zero counters", %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      # Documents current Runners.Fake behaviour: the runner
      # unconditionally calls `commit_proposals` after looping over an
      # empty proposal list (`fake.ex:39-40`), and the
      # `:commit_proposals` handler in `run_server.ex:141` sends
      # `:publish` regardless of `Staging.total`. So an empty proposal
      # list lands `:succeeded` with all zero counters. The genuine
      # `max_turns_reached` path (harness exits without committing)
      # requires a non-committing test stub runner — out of scope for
      # this PR.
      assert run.status == :succeeded
      assert run.harness == :fake
      assert run.facts_added == 0
      assert run.facts_invalidated == 0
      assert run.blocks_written == 0
      assert run.links_added == 0
    end

    test "runner_config.prompt reaches the runner via state.prompt", %{tenant_id: tenant_id} do
      {:ok, _agent} = PromptCapture.start_link()
      {_ws, scope} = workspace_scope(tenant_id)

      # PromptCapture.run_iteration returns done("") without committing
      # any proposals, so the run finalises as :failed (max_turns_reached).
      # The assertion is on the captured prompt, not the run status.
      _ =
        Consolidator.run_now(scope,
          runner_module: PromptCapture,
          override_min_input_count: true,
          await_ms: 30_000
        )

      captured = PromptCapture.last_prompt()
      assert is_binary(captured)
      assert captured =~ "memory consolidator"
      assert captured =~ "workspace (tenant=#{tenant_id}"
      assert captured =~ "list_clusters"
      assert captured =~ "commit_proposals"
    end

    test "both vendor lanes arm native session resume (F1)", %{tenant_id: tenant_id} do
      {:ok, _agent} = PromptCapture.start_link()

      for harness <- [:claude_code, :codex] do
        {_ws, scope} = workspace_scope(tenant_id)

        Application.put_env(:jido_claw, @consolidator_key,
          enabled: true,
          min_input_count: 0,
          write_skip_rows: true,
          harness: harness,
          harness_options: [sandbox_mode: :local, timeout_ms: 30_000, max_turns: 60]
        )

        # PromptCapture stands in for the CLI runner; the config under test
        # is the HARNESS lane's (`base_runner_config/2`), which the spec
        # carries regardless of the runner_module override.
        _ =
          Consolidator.run_now(scope,
            runner_module: PromptCapture,
            override_min_input_count: true,
            await_ms: 30_000
          )

        config = PromptCapture.last_config()
        assert config.resume == :armed, "the #{harness} lane must arm native resume"
        assert is_binary(config.prompt) and config.prompt != ""
      end
    end

    test "harness_model column tracks the configured model across consecutive runs", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      Application.put_env(:jido_claw, @consolidator_key,
        enabled: true,
        min_input_count: 0,
        write_skip_rows: true,
        harness: :fake,
        harness_options: [
          sandbox_mode: :local,
          timeout_ms: 30_000,
          max_turns: 60,
          fake: [model: "model-A"]
        ]
      )

      assert {:ok, run_a} =
               Consolidator.run_now(scope,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run_a.harness == :fake
      assert run_a.harness_model == "model-A"

      Application.put_env(:jido_claw, @consolidator_key,
        enabled: true,
        min_input_count: 0,
        write_skip_rows: true,
        harness: :fake,
        harness_options: [
          sandbox_mode: :local,
          timeout_ms: 30_000,
          max_turns: 60,
          fake: [model: "model-B"]
        ]
      )

      assert {:ok, run_b} =
               Consolidator.run_now(scope,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run_b.harness == :fake
      assert run_b.harness_model == "model-B"
    end

    test "per-call harness override picks the harness's nested model, not the global default's",
         %{tenant_id: tenant_id} do
      empty_codex_home =
        Path.join(System.tmp_dir!(), "empty_codex_nested_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_codex_home)
      prev_codex = Application.get_env(:jido_claw, :codex_home_dir)
      Application.put_env(:jido_claw, :codex_home_dir, empty_codex_home)

      on_exit(fn ->
        File.rm_rf(empty_codex_home)

        if prev_codex,
          do: Application.put_env(:jido_claw, :codex_home_dir, prev_codex),
          else: Application.delete_env(:jido_claw, :codex_home_dir)
      end)

      Application.put_env(:jido_claw, @consolidator_key,
        enabled: true,
        min_input_count: 0,
        write_skip_rows: true,
        harness: :claude_code,
        harness_options: [
          sandbox_mode: :local,
          timeout_ms: 30_000,
          max_turns: 60,
          claude_code: [model: "claude-x"],
          codex: [model: "codex-y"]
        ]
      )

      {_ws, scope} = workspace_scope(tenant_id)

      assert {:error, "no_credentials"} =
               Consolidator.run_now(scope,
                 harness: :codex,
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      rows =
        ConsolidationRun.list!(
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      row =
        Enum.find(rows, fn r ->
          r.tenant_id == scope.tenant_id and r.workspace_id == scope.workspace_id and
            r.harness == :codex
        end)

      assert row, "expected a ConsolidationRun row with harness=:codex"
      assert row.harness_model == "codex-y"
    end

    test ":no_credentials egress writes a failed row with harness=:codex", %{
      tenant_id: tenant_id
    } do
      empty_codex_home =
        Path.join(System.tmp_dir!(), "empty_codex_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_codex_home)
      prev_codex = Application.get_env(:jido_claw, :codex_home_dir)
      Application.put_env(:jido_claw, :codex_home_dir, empty_codex_home)

      on_exit(fn ->
        File.rm_rf(empty_codex_home)

        if prev_codex,
          do: Application.put_env(:jido_claw, :codex_home_dir, prev_codex),
          else: Application.delete_env(:jido_claw, :codex_home_dir)
      end)

      {_ws, scope} = workspace_scope(tenant_id)

      result =
        Consolidator.run_now(scope,
          harness: :codex,
          override_min_input_count: true,
          await_ms: 30_000
        )

      assert {:error, "no_credentials"} = result

      rows =
        ConsolidationRun.list!(
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      row =
        Enum.find(rows, fn r ->
          r.tenant_id == scope.tenant_id and r.workspace_id == scope.workspace_id and
            r.harness == :codex
        end)

      assert row, "expected a ConsolidationRun row with harness=:codex"
      assert row.status == :failed
      assert row.error == "no_credentials"
      assert row.harness_model == "gpt-5-codex"
      refute is_nil(row.forge_session_id), "expected a forge_session_id (init/2 ran)"
    end

    test "per-run forge_home is created mid-flight and cleaned up after the run", %{
      tenant_id: tenant_id
    } do
      forge_home =
        Path.join(System.tmp_dir!(), "forge_home_cleanup_#{System.unique_integer([:positive])}")

      File.mkdir_p!(forge_home)
      prev_forge = Application.get_env(:jido_claw, :forge_home)
      Application.put_env(:jido_claw, :forge_home, forge_home)

      on_exit(fn ->
        File.rm_rf(forge_home)

        if prev_forge,
          do: Application.put_env(:jido_claw, :forge_home, prev_forge),
          else: Application.delete_env(:jido_claw, :forge_home)
      end)

      test_pid = self()

      spawn_link(fn ->
        ForgePubSub.subscribe_sessions()

        receive do
          {:session_started, _session_id, _scope} ->
            send(test_pid, {:dirs_at_start, File.ls!(forge_home)})
        after
          10_000 -> send(test_pid, :watcher_timeout)
        end
      end)

      {_ws, scope} = workspace_scope(tenant_id)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded

      assert_receive {:dirs_at_start, dirs_at_start}, 5_000

      assert run.forge_session_id in dirs_at_start,
             "expected per-run forge_home to be created mid-flight"

      # Cleanup ran after the harness fully stopped.
      refute File.dir?(Path.join(forge_home, run.forge_session_id))
    end

    test "Forge session is eventually stopped after every covered exit path", %{
      tenant_id: tenant_id
    } do
      # DEFERRED: source plan asked for await_ready timeout, harness
      # DOWN during bootstrap, and run_iteration crash coverage. All
      # three require a test-only stub runner that hangs/crashes inside
      # `init/2` or `run_iteration/3` — not authorable against the
      # current `Runners.Fake` API. This test covers the two cleanup
      # paths reachable today: succeeded with proposals and succeeded
      # without.

      {_ws, scope1} = workspace_scope(tenant_id)

      assert {:ok, run_with_proposals} =
               Consolidator.run_now(scope1,
                 fake_proposals: [
                   {"propose_block_update", %{label: "block_for_cleanup_test", new_content: "x"}}
                 ],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run_with_proposals.status == :succeeded

      # Eventual, not immediate: `:commit_proposals` triggers `:publish`
      # and `run_now/2` can return before the harness Task has finished
      # unwinding through `maybe_stop_forge_session/1` at
      # `run_server.ex:381`.
      :ok =
        eventually(fn ->
          run_with_proposals.forge_session_id not in ForgeManager.list_sessions()
        end)

      {_ws, scope2} = workspace_scope(tenant_id)

      assert {:ok, empty_run} =
               Consolidator.run_now(scope2,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert empty_run.status == :succeeded

      :ok =
        eventually(fn ->
          empty_run.forge_session_id not in ForgeManager.list_sessions()
        end)
    end

    test ":user-scope run completes without a Forge claim and writes no forge_sessions row", %{
      tenant_id: tenant_id
    } do
      # Enable Forge persistence so a workspace-less spec would otherwise reach
      # the claim path. `claim: false` (RunServer.maybe_run_without_claim/2)
      # must skip the claim entirely — proving the run no longer crashes on
      # :scope_required (#2) and writes no forge_sessions row (#3). The setup's
      # on_exit restores the disabled default.
      Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: true)

      before = forge_session_count()

      scope = user_scope(tenant_id)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded

      # Let the harness finish unwinding (its best-effort persistence reads run
      # during stop) while the sandbox owner is still alive, to avoid teardown
      # connection races.
      :ok = eventually(fn -> run.forge_session_id not in ForgeManager.list_sessions() end)

      # The workspace-less run never claimed, so no Forge session row was written.
      assert forge_session_count() == before
    end
  end

  describe "attempt tokens, multi-turn loop, watchdog" do
    defp script(fun) do
      Application.put_env(:jido_claw, :consolidator_scripted_turn, fun)
      on_exit(fn -> Application.delete_env(:jido_claw, :consolidator_scripted_turn) end)
    end

    defp call_tool_via(url, tool, args) do
      case LoopbackClient.initialize(url) do
        {:ok, mcp} -> LoopbackClient.call_tool(mcp, tool, args)
        {:error, _} = err -> err
      end
    end

    defp scripted_result(base, turns) do
      %{base | metadata: Map.merge(base.metadata, %{turns: turns})}
    end

    test "continuation turns rotate the attempt capability; a closed token is refused through the real route; per-attempt configs are cleaned",
         %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)
      test_pid = self()
      {:ok, journal} = Agent.start_link(fn -> %{turn: 0, urls: [], paths: []} end)

      script(fn _state, opts ->
        turn = Agent.get_and_update(journal, fn s -> {s.turn + 1, %{s | turn: s.turn + 1}} end)
        url = Keyword.fetch!(opts, :mcp_server_url)
        path = Keyword.fetch!(opts, :mcp_config_path)
        Agent.update(journal, fn s -> %{s | urls: [url | s.urls], paths: [path | s.paths]} end)

        case turn do
          1 ->
            send(test_pid, {:turn, 1, Keyword.get(opts, :prompt), File.stat(path)})
            {:ok, scripted_result(ForgeRunner.continue(""), 1)}

          2 ->
            [url1, url2] = Enum.reverse(Agent.get(journal, & &1.urls))
            stale_reply = call_tool_via(url1, "propose_add", %{content: "late mutation"})
            fresh_reply = call_tool_via(url2, "propose_add", %{content: "fresh fact"})
            commit_reply = call_tool_via(url2, "commit_proposals", %{})

            send(
              test_pid,
              {:turn, 2, {Keyword.get(opts, :prompt), Keyword.get(opts, :guidance)},
               {stale_reply, fresh_reply, commit_reply}}
            )

            {:ok, scripted_result(ForgeRunner.done(""), 1)}
        end
      end)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 runner_module: ScriptedRunner,
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded
      # The late mutation against the CLOSED turn-1 capability never staged.
      assert run.facts_added == 1

      # Turn 1 carries no :prompt opt (the full prompt lives in runner
      # config); its per-attempt config file exists mode 0600 during the
      # attempt.
      assert_receive {:turn, 1, nil, {:ok, stat}}, 10_000
      assert Bitwise.band(stat.mode, 0o777) == 0o600

      # Turn 2 gets GUIDANCE only — under the semantically-tagged :guidance
      # opt with :prompt ABSENT (a fresh-armed turn reads :prompt as its
      # WHOLE prompt, so continuation guidance must never ride it) — and the
      # stale turn-1 token is refused through the real loopback route while
      # the fresh token stages + commits.
      assert_receive {:turn, 2, {nil, guidance}, {stale_reply, fresh_reply, commit_reply}},
                     10_000

      assert guidance =~ "turn 2"
      refute guidance =~ "memory consolidator"
      # The stale capability gets a TYPED tool error the CLI sees (`isError`
      # on the JSON-RPC result — the transport itself succeeded).
      assert {:ok, stale_rpc} = stale_reply
      assert get_in(stale_rpc, ["result", "isError"]) == true
      assert inspect(stale_rpc) =~ "attempt_closed"
      assert {:ok, fresh_rpc} = fresh_reply
      refute get_in(fresh_rpc, ["result", "isError"]) == true
      assert {:ok, commit_rpc} = commit_reply
      refute get_in(commit_rpc, ["result", "isError"]) == true

      # No temp leak: every per-attempt config file is gone after the run.
      for path <- Enum.reverse(Agent.get(journal, & &1.paths)) do
        refute File.exists?(path), "expected per-attempt config #{path} to be cleaned"
      end
    end

    test "prevention pin: a mid-run fresh restart still carries the full task — its commit is legitimate and warned",
         %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)
      test_pid = self()
      {:ok, journal} = Agent.start_link(fn -> %{turn: 0} end)

      script(fn _state, opts ->
        turn = Agent.get_and_update(journal, fn s -> {s.turn + 1, %{s | turn: s.turn + 1}} end)

        send(
          test_pid,
          {:turn_opts, turn, Keyword.get(opts, :prompt), Keyword.get(opts, :guidance)}
        )

        case turn do
          1 ->
            {:ok, scripted_result(ForgeRunner.continue(""), 1)}

          2 ->
            # The anchor did not survive: this turn reports a FRESH
            # conversation (source :startup). Under the :prompt/:guidance
            # split it still received the full task via state.prompt — a
            # task-free turn is structurally impossible — so its later
            # commit is legitimate work, and the driver warns loudly.
            base = ForgeRunner.continue("")

            result = %{
              base
              | metadata:
                  Map.put(base.metadata, :state, %{iteration: 2, resume: ResumeState.new()})
            }

            {:ok, scripted_result(result, 1)}

          3 ->
            url = Keyword.fetch!(opts, :mcp_server_url)
            {:ok, _} = call_tool_via(url, "propose_add", %{content: "fresh fact"})
            {:ok, _} = call_tool_via(url, "commit_proposals", %{})
            {:ok, scripted_result(ForgeRunner.done(""), 1)}
        end
      end)

      log =
        capture_log(fn ->
          assert {:ok, run} =
                   Consolidator.run_now(scope,
                     runner_module: ScriptedRunner,
                     override_min_input_count: true,
                     await_ms: 30_000
                   )

          # The run publishes exactly once — the fresh turn's commit is real.
          assert run.status == :succeeded
          assert run.facts_added == 1
        end)

      assert log =~ "FRESH conversation"

      # Turn 1 carries neither key; every turn ≥ 2 rides :guidance with
      # :prompt ABSENT — the driver-side half of the prevention.
      assert_receive {:turn_opts, 1, nil, nil}
      assert_receive {:turn_opts, 2, nil, guidance2}
      assert guidance2 =~ "turn 2"
      assert_receive {:turn_opts, 3, nil, guidance3}
      assert guidance3 =~ "turn 3"
    end

    test "commit-then-hang: the deadline watchdog publishes NOTHING (no :succeeded certificate)",
         %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)

      config = Application.get_env(:jido_claw, @consolidator_key, [])

      Application.put_env(
        :jido_claw,
        @consolidator_key,
        Keyword.put(
          config,
          :harness_options,
          sandbox_mode: :local,
          timeout_ms: 20_000,
          max_turns: 60,
          max_run_ms: 700
        )
      )

      script(fn _state, opts ->
        url = Keyword.fetch!(opts, :mcp_server_url)
        {:ok, _} = call_tool_via(url, "commit_proposals", %{})
        # The commit marker is in — but the attempt never exits cleanly
        # within the run budget. The marker alone must never publish.
        Process.sleep(5_000)
        {:ok, ForgeRunner.done("")}
      end)

      assert {:error, "run_deadline_exceeded"} =
               Consolidator.run_now(scope,
                 runner_module: ScriptedRunner,
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      # Nothing published: no :succeeded certificate exists for this scope —
      # the terminal audit row is :failed with the deadline reason.
      {:ok, rows} =
        ConsolidationRun.history_for_scope(
          %{scope_kind: :workspace, scope_fk_id: scope.workspace_id, limit: 20},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      refute Enum.any?(rows, &(&1.status == :succeeded))
      assert Enum.any?(rows, &(&1.status == :failed and &1.error == "run_deadline_exceeded"))
    end

    test "a run that keeps continuing exhausts the iteration bound and publishes nothing",
         %{tenant_id: tenant_id} do
      {_ws, scope} = workspace_scope(tenant_id)

      config = Application.get_env(:jido_claw, @consolidator_key, [])

      Application.put_env(
        :jido_claw,
        @consolidator_key,
        Keyword.put(
          config,
          :harness_options,
          sandbox_mode: :local,
          timeout_ms: 20_000,
          max_turns: 60,
          max_iterations: 2
        )
      )

      script(fn _state, _opts ->
        {:ok, ForgeRunner.continue("")}
      end)

      assert {:error, "iteration_limit_reached"} =
               Consolidator.run_now(scope,
                 runner_module: ScriptedRunner,
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      {:ok, rows} =
        ConsolidationRun.history_for_scope(
          %{scope_kind: :workspace, scope_fk_id: scope.workspace_id, limit: 20},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      refute Enum.any?(rows, &(&1.status == :succeeded))
      assert Enum.any?(rows, &(&1.error == "iteration_limit_reached"))
    end

    test "the publish certificate row carries the run's deterministic id", %{
      tenant_id: tenant_id
    } do
      {_ws, scope} = workspace_scope(tenant_id)

      assert {:ok, run} =
               Consolidator.run_now(scope,
                 fake_proposals: [{"propose_add", %{content: "certified fact"}}],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert run.status == :succeeded
      # The row is readable by ITS OWN id — the reconciliation key.
      assert {:ok, fetched} =
               ConsolidationRun.by_id(run.id, tenant: tenant_id, actor: actor_for(tenant_id))

      assert fetched.status == :succeeded
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp workspace_scope(tenant_id) do
    {:ok, ws} =
      Resolver.ensure_workspace(
        tenant_id,
        "/tmp/run_server_test_#{System.unique_integer([:positive])}"
      )

    # Resolver creates with `consolidation_policy: :disabled` — flip to
    # `:default` so `PolicyResolver.gate/1` returns `:ok` for this scope.
    {:ok, updated_ws} =
      Workspace.set_consolidation_policy(ws, :default,
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    scope = %{
      tenant_id: tenant_id,
      scope_kind: :workspace,
      user_id: nil,
      workspace_id: updated_ws.id,
      project_id: nil,
      session_id: nil
    }

    {updated_ws, scope}
  end

  defp session_scope(tenant_id) do
    {ws, _ws_scope} = workspace_scope(tenant_id)

    {:ok, session} =
      Session.start(
        %{
          workspace_id: ws.id,
          kind: :repl,
          external_id: "sess-#{System.unique_integer([:positive])}",
          started_at: DateTime.utc_now()
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    scope = %{
      tenant_id: tenant_id,
      scope_kind: :session,
      user_id: nil,
      workspace_id: ws.id,
      project_id: nil,
      session_id: session.id
    }

    {ws, session, scope}
  end

  # A workspace-less `:user` scope. `PolicyResolver.gate/1` for `:user`
  # aggregates `consolidation_policy` across the tenant's workspaces keyed to
  # this user, so register one with `:default` to make the gate return `:ok`.
  # The workspace's `user_id` FKs to `users`, so seed a real user first
  # (Ash.Seed bypasses the auth/policy registration machinery). The run itself
  # carries `workspace_id: nil` — the point of the test.
  defp user_scope(tenant_id) do
    user =
      Ash.Seed.seed!(JidoClaw.Accounts.User, %{
        email: "user-#{System.unique_integer([:positive])}@test.local"
      })

    {:ok, _ws} =
      Workspace.register(
        %{
          name: "user-scope-ws-#{System.unique_integer([:positive])}",
          path: "/tmp/user_scope_test_#{System.unique_integer([:positive])}",
          user_id: user.id,
          consolidation_policy: :default
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    %{
      tenant_id: tenant_id,
      scope_kind: :user,
      user_id: user.id,
      workspace_id: nil,
      project_id: nil,
      session_id: nil
    }
  end

  defp forge_session_count do
    %{rows: [[count]]} =
      SQL.query!(JidoClaw.Repo, "SELECT count(*) FROM forge_sessions", [])

    count
  end

  # `:model_remember` keeps seeded facts inside
  # `Fact.for_consolidator/1`'s default `sources` filter
  # (`[:model_remember, :user_save, :imported_legacy]`).
  # `:consolidator_promoted` rows are excluded by default and would
  # silently fail to load even when the test author thought timestamps
  # were the only thing that mattered.
  # Seed an active (invalid_at: nil) block at `scope`+`label` so a subsequent
  # propose_block_update for the same key routes through the revise branch.
  # Mirrors `build_block_attrs/2` in run_server.ex.
  defp seed_active_block!(scope, label, value) do
    {:ok, block} =
      Block.write(
        %{
          scope_kind: scope.scope_kind,
          user_id: scope[:user_id],
          workspace_id: scope[:workspace_id],
          project_id: scope[:project_id],
          session_id: scope[:session_id],
          label: label,
          value: value,
          char_limit: 2000,
          pinned: true,
          position: 0,
          source: :consolidator,
          written_by: "test"
        },
        tenant: scope.tenant_id,
        actor: actor_for(scope.tenant_id)
      )

    block
  end

  defp seed_fact_simple!(scope, label) do
    Fact.record!(
      %{
        scope_kind: scope.scope_kind,
        user_id: scope.user_id,
        workspace_id: scope.workspace_id,
        project_id: scope.project_id,
        session_id: scope.session_id,
        label: label,
        content: "content for #{label}",
        tags: ["seed"],
        source: :model_remember,
        written_by: "test"
      },
      tenant: scope.tenant_id,
      actor: actor_for(scope.tenant_id)
    )
  end

  # `Fact.record/1`'s accept list does not include `:inserted_at`, so
  # explicit-timestamp seeding has to go through `:import_legacy`.
  defp seed_fact_at!(scope, label, ts) do
    Fact.import_legacy!(
      %{
        scope_kind: scope.scope_kind,
        user_id: scope.user_id,
        workspace_id: scope.workspace_id,
        project_id: scope.project_id,
        session_id: scope.session_id,
        label: label,
        content: "imported content for #{label}",
        tags: ["seed-import"],
        written_by: "test",
        import_hash: "test-#{System.unique_integer([:positive])}",
        inserted_at: ts,
        valid_at: ts
      },
      tenant: scope.tenant_id,
      actor: actor_for(scope.tenant_id)
    )
  end

  # `Message.append/1` allocates `sequence` and ignores `tenant_id` /
  # `inserted_at` — `Message.import/1` is the only path that accepts
  # all three as writable arguments.
  defp seed_message_at!(session, content, ts, sequence) do
    Message.import!(
      %{
        session_id: session.id,
        role: :user,
        sequence: sequence,
        content: content,
        inserted_at: ts,
        import_hash: "msg-#{System.unique_integer([:positive])}"
      },
      tenant: session.tenant_id,
      actor: actor_for(session.tenant_id)
    )
  end

  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      true ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("eventually condition not met within timeout")
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end
    end
  end
end
