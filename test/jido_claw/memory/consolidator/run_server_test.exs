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
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.{Message, Session}
  alias JidoClaw.Memory.{Block, Fact, Link}
  alias JidoClaw.Memory.Consolidator
  alias JidoClaw.Memory.Consolidator.Clusterer
  alias JidoClaw.Workspaces.{Resolver, Workspace}

  @consolidator_key JidoClaw.Memory.Consolidator
  @memory_domain JidoClaw.Memory.Domain

  setup do
    # Shared sandbox so cross-process writes (RunServer, harness Task,
    # Bandit workers) are visible to every spawned process AND get
    # rolled back at test teardown. The advisory-lock bypass is
    # required because `LockOwner.hold/2` pins a Postgres connection
    # for the run's duration via `Repo.checkout/1` — that's
    # incompatible with shared mode's single routed connection. Lock
    # semantics are covered separately in `lock_owner_test.exs`.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
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
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  describe "end-to-end fake-harness run" do
    test "succeeded run writes a block + fact when proposals stage cleanly" do
      {_ws, scope} = workspace_scope()

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

      blocks = Ash.read!(Block, domain: @memory_domain)
      assert Enum.any?(blocks, &(&1.label == "core_facts" and &1.value =~ "shipping"))

      facts = Ash.read!(Fact, domain: @memory_domain)
      assert Enum.any?(facts, &(&1.label == "geo" and &1.content =~ "Canada"))
    end

    test "propose_link forwards relation, reason, confidence to a Link row" do
      {_ws, scope} = workspace_scope()

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

      links = Ash.read!(Link, domain: @memory_domain)
      created = Enum.find(links, &(&1.from_fact_id == fact_a.id and &1.to_fact_id == fact_b.id))

      refute is_nil(created)
      assert created.relation == :supports
      assert created.reason == "consolidator_evidence"
      assert created.confidence == 0.85
      assert created.written_by == "consolidator"
    end

    test "propose_update invalidates original + writes replacement + writes :supersedes link" do
      {_ws, scope} = workspace_scope()

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
      reloaded = Ash.get!(Fact, original.id, domain: @memory_domain)
      refute is_nil(reloaded.invalid_at)

      facts = Ash.read!(Fact, domain: @memory_domain)

      replacement =
        Enum.find(facts, fn f ->
          f.label == "vacation_plans" and f.id != original.id and is_nil(f.invalid_at)
        end)

      refute is_nil(replacement)
      assert replacement.content == "updated content"
      assert replacement.tags == ["v2"]
      assert replacement.source == :consolidator_promoted

      links = Ash.read!(Link, domain: @memory_domain)

      supersedes =
        Enum.find(links, fn l ->
          l.relation == :supersedes and l.from_fact_id == replacement.id and
            l.to_fact_id == original.id
        end)

      refute is_nil(supersedes)
      assert supersedes.written_by == "consolidator"
    end

    test "defer_cluster (facts) — watermark stops at row before deferred cluster" do
      {_ws, scope} = workspace_scope()

      # Truncate to microseconds — the Ash attributes are
      # `:utc_datetime_usec` and an unrounded `DateTime.utc_now/0` can
      # produce equality surprises after Postgres round-trip.
      t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)
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

    test "defer_cluster (messages) — single-cluster defer pins watermark to nil" do
      {_ws, session, scope} = session_scope()

      t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)
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

    test "fake_proposals: [] → succeeded run with zero counters" do
      {_ws, scope} = workspace_scope()

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

    test "Forge session is eventually stopped after every covered exit path" do
      # DEFERRED: source plan asked for await_ready timeout, harness
      # DOWN during bootstrap, and run_iteration crash coverage. All
      # three require a test-only stub runner that hangs/crashes inside
      # `init/2` or `run_iteration/3` — not authorable against the
      # current `Runners.Fake` API. This test covers the two cleanup
      # paths reachable today: succeeded with proposals and succeeded
      # without.

      {_ws, scope1} = workspace_scope()

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
          run_with_proposals.forge_session_id not in JidoClaw.Forge.Manager.list_sessions()
        end)

      {_ws, scope2} = workspace_scope()

      assert {:ok, empty_run} =
               Consolidator.run_now(scope2,
                 fake_proposals: [],
                 override_min_input_count: true,
                 await_ms: 30_000
               )

      assert empty_run.status == :succeeded

      :ok =
        eventually(fn ->
          empty_run.forge_session_id not in JidoClaw.Forge.Manager.list_sessions()
        end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp workspace_scope do
    {:ok, ws} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/run_server_test_#{System.unique_integer([:positive])}"
      )

    # Resolver creates with `consolidation_policy: :disabled` — flip to
    # `:default` so `PolicyResolver.gate/1` returns `:ok` for this scope.
    {:ok, ws} = Workspace.set_consolidation_policy(ws, :default)

    scope = %{
      tenant_id: "default",
      scope_kind: :workspace,
      user_id: nil,
      workspace_id: ws.id,
      project_id: nil,
      session_id: nil
    }

    {ws, scope}
  end

  defp session_scope do
    {ws, _ws_scope} = workspace_scope()

    {:ok, session} =
      Session.start(%{
        workspace_id: ws.id,
        tenant_id: "default",
        kind: :repl,
        external_id: "sess-#{System.unique_integer([:positive])}",
        started_at: DateTime.utc_now()
      })

    scope = %{
      tenant_id: "default",
      scope_kind: :session,
      user_id: nil,
      workspace_id: ws.id,
      project_id: nil,
      session_id: session.id
    }

    {ws, session, scope}
  end

  # `:model_remember` keeps seeded facts inside
  # `Fact.for_consolidator/1`'s default `sources` filter
  # (`[:model_remember, :user_save, :imported_legacy]`).
  # `:consolidator_promoted` rows are excluded by default and would
  # silently fail to load even when the test author thought timestamps
  # were the only thing that mattered.
  defp seed_fact_simple!(scope, label) do
    Fact.record!(%{
      tenant_id: scope.tenant_id,
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
    })
  end

  # `Fact.record/1`'s accept list does not include `:inserted_at`, so
  # explicit-timestamp seeding has to go through `:import_legacy`.
  defp seed_fact_at!(scope, label, ts) do
    Fact.import_legacy!(%{
      tenant_id: scope.tenant_id,
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
    })
  end

  # `Message.append/1` allocates `sequence` and ignores `tenant_id` /
  # `inserted_at` — `Message.import/1` is the only path that accepts
  # all three as writable arguments.
  defp seed_message_at!(session, content, ts, sequence) do
    Message.import!(%{
      session_id: session.id,
      tenant_id: session.tenant_id,
      role: :user,
      sequence: sequence,
      content: content,
      inserted_at: ts,
      import_hash: "msg-#{System.unique_integer([:positive])}"
    })
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
