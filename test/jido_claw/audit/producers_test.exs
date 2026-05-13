defmodule JidoClaw.Audit.ProducersTest do
  @moduledoc """
  Coverage for the inline `JidoClaw.Audit.Producers.*` change modules
  wired into producer actions.

  Locks in:

    * `Session.start` (`SessionStart` producer) writes a
      `:session_start` audit row in the same transaction.
    * `Session.close` (`SessionEnd` producer) writes a `:session_end`
      audit row.
    * `Memory.Block.write` (`MemoryWrite` producer) writes a
      `:memory_write` audit row with `target_kind: :memory_block`.
    * Solution `:store` with `sharing in [:shared, :public]` writes a
      `:solution_share` row; `:local` does NOT.
    * Each producer flows through `AsyncWriter.sync/1` so the audit
      row is durably visible after the action returns.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.Event
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Memory.Block
  alias JidoClaw.Memory.BlockRevision
  alias JidoClaw.Solutions.Solution

  describe "SessionStart producer" do
    test "Session.start writes a :session_start audit row in the same transaction" do
      tenant_id = seed_tenant("audit-session-start")
      {:ok, ws} = seed_workspace(tenant_id)

      external_id = "ext-#{System.unique_integer([:positive])}"

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: external_id,
            started_at: DateTime.utc_now()
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :session_start and r.target_kind == :session and
            r.target_id == to_string(session.id)
        end)

      assert audit_row, "expected one :session_start audit row for the new session"
      assert audit_row.actor_kind == :system
      payload = audit_row.payload
      assert MapKeys.coalesce_field(payload, "external_id") == external_id
    end
  end

  describe "SessionEnd producer" do
    test "Session.close writes a :session_end audit row" do
      tenant_id = seed_tenant("audit-session-end")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: "ext-end-#{System.unique_integer([:positive])}",
            started_at: DateTime.utc_now()
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _closed} = Session.close(session, %{}, tenant: tenant_id, actor: actor_for(tenant_id))

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :session_end and r.target_id == to_string(session.id)
        end)

      assert audit_row, "expected one :session_end audit row for the closed session"
    end
  end

  describe "MemoryWrite producer" do
    test "Block.write writes a :memory_write audit row with target_kind :memory_block" do
      tenant_id = seed_tenant("audit-memory-write")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit_test",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(block.id)
        end)

      assert audit_row, "expected one :memory_write audit row for the new block"
    end
  end

  describe "SolutionShare producer" do
    test "Solution.store with sharing: :shared writes a :solution_share audit row" do
      tenant_id = seed_tenant("audit-share")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, sol} =
        Solution.store(
          %{
            problem_signature: "sig-shared-#{System.unique_integer([:positive])}",
            solution_content: "shared content",
            language: "elixir",
            sharing: :shared,
            workspace_id: ws.id,
            embedding_status: :disabled
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      audit_row =
        Enum.find(rows, fn r ->
          r.event_kind == :solution_share and r.target_kind == :solution and
            r.target_id == to_string(sol.id)
        end)

      assert audit_row, "expected one :solution_share audit row for the shared solution"
    end

    test "Solution.store with sharing: :local does NOT write a :solution_share audit row" do
      tenant_id = seed_tenant("audit-share-local")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, sol} =
        Solution.store(
          %{
            problem_signature: "sig-local-#{System.unique_integer([:positive])}",
            solution_content: "local content",
            language: "elixir",
            sharing: :local,
            workspace_id: ws.id,
            embedding_status: :disabled
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert Enum.all?(rows, fn r ->
               not (r.event_kind == :solution_share and r.target_id == to_string(sol.id))
             end),
             "did not expect a :solution_share audit row for a :local solution"
    end
  end

  describe "real action surfaces" do
    alias JidoClaw.Memory.ConsolidationRun
    alias JidoClaw.Memory.Episode
    alias JidoClaw.Memory.Fact
    alias JidoClaw.Memory.Link

    defp find_audit(rows, kind, target_kind, target_id) do
      Enum.find(rows, fn r ->
        r.event_kind == kind and r.target_kind == target_kind and
          r.target_id == to_string(target_id)
      end)
    end

    test "Memory.Fact.record / promote / invalidate_by_id all emit :memory_write" do
      tenant_id = seed_tenant("audit-fact")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, fact} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-fact-record",
            content: "v1",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _promoted} =
        Fact.promote(fact, %{trust_score: 0.85}, tenant: tenant_id, actor: actor_for(tenant_id))

      {:ok, _invalidated} =
        Fact.invalidate_by_id(fact, %{reason: "test"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      memory_writes =
        Enum.filter(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_fact and
            r.target_id == to_string(fact.id)
        end)

      assert length(memory_writes) >= 3,
             "expected three :memory_write audit rows (record + promote + invalidate)"
    end

    test "Memory.Fact.invalidate_by_label emits :memory_write" do
      tenant_id = seed_tenant("audit-fact-label")
      {:ok, ws} = seed_workspace(tenant_id)

      label = "lbl-#{System.unique_integer([:positive])}"

      {:ok, fact} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: label,
            content: "to invalidate",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _} =
        Fact.invalidate_by_label(fact, %{source: :user_save, reason: "label test"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :memory_write, :memory_fact, fact.id),
             "expected :memory_write audit row for invalidate_by_label"
    end

    test "Memory.Block.write / invalidate emit :memory_write" do
      tenant_id = seed_tenant("audit-block")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-block",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _invalidated} =
        Block.invalidate(block, %{}, tenant: tenant_id, actor: actor_for(tenant_id))

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      writes =
        Enum.filter(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(block.id)
        end)

      assert length(writes) >= 2,
             "expected :memory_write audit rows for both write and invalidate"
    end

    test "Block.invalidate carries the BlockRevision id in the audit payload" do
      tenant_id = seed_tenant("audit-block-revision")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-block-rev",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _invalidated} =
        Block.invalidate(block, %{reason: "carrying-rev-test"},
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, revisions} =
        BlockRevision.for_block(block.id,
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert [revision] = revisions

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      invalidate_audit =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(block.id) and
            MapKeys.coalesce_field(r.payload, "block_revision_id") != nil
        end)

      assert invalidate_audit,
             "expected :invalidate audit row to carry block_revision_id in payload"

      assert MapKeys.coalesce_field(invalidate_audit.payload, "block_revision_id") ==
               to_string(revision.id)
    end

    test "Block.revise emits a :revise audit row linking prior -> new -> revision" do
      tenant_id = seed_tenant("audit-block-revise")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, prior} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-revise",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, new_block} =
        Block.revise(prior, %{value: "v2", reason: "test-revise"}, actor: actor_for(tenant_id))

      {:ok, revisions} =
        BlockRevision.for_block(prior.id,
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert [revision] = revisions

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      revise_audit =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(prior.id) and
            MapKeys.coalesce_field(r.payload, "operation") == "revise"
        end)

      assert revise_audit, "expected a :memory_write audit row marked operation: :revise"

      payload = revise_audit.payload
      pick = fn key -> MapKeys.coalesce_field(payload, Atom.to_string(key)) end

      assert pick.(:prior_block_id) == to_string(prior.id)
      assert pick.(:new_block_id) == to_string(new_block.id)
      assert pick.(:block_revision_id) == to_string(revision.id)
    end

    test "Block.revise by a user actor records actor_kind: :user with actor_id" do
      # Before Fix 2, emit_revise_audit derived actor_id from
      # actor[:id], so canonical user actors (which carry :user_id,
      # not :id) logged actor_id: nil. The classifier reads :user_id
      # first, so the row now carries the tenant-bound user id.
      tenant_id = seed_tenant("audit-revise-user-actor")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, prior} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-revise-user",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _new_block} =
        Block.revise(prior, %{value: "v2", reason: "user-actor"}, actor: actor_for(tenant_id))

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      revise_audit =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(prior.id) and
            MapKeys.coalesce_field(r.payload, "operation") == "revise"
        end)

      assert revise_audit
      assert revise_audit.actor_kind == :user
      assert revise_audit.actor_id == tenant_id
    end

    test "Block.revise by a system actor of a :user-sourced prior records actor_kind: :system" do
      # Before Fix 2, actor_kind_for(prior.source) returned :user from
      # the prior block's source field — so a system revise of a
      # user-sourced block was logged with actor_kind: :user. The
      # classifier reads the actor instead of the prior's source.
      tenant_id = seed_tenant("audit-revise-sys-actor")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, prior} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "audit-revise-sys",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _new_block} =
        Block.revise(prior, %{value: "v2", reason: "sys-actor"}, actor: Actor.system(tenant_id))

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      revise_audit =
        Enum.find(rows, fn r ->
          r.event_kind == :memory_write and r.target_kind == :memory_block and
            r.target_id == to_string(prior.id) and
            MapKeys.coalesce_field(r.payload, "operation") == "revise"
        end)

      assert revise_audit
      assert revise_audit.actor_kind == :system
      assert revise_audit.actor_id == nil
    end

    test "Memory.Episode.record emits :memory_write with target_kind :memory_episode" do
      tenant_id = seed_tenant("audit-episode")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, episode} =
        Episode.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            kind: :transcript
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :memory_write, :memory_episode, episode.id),
             "expected :memory_write audit row for episode"
    end

    test "Memory.Link.create_link emits :memory_write with target_kind :memory_link" do
      tenant_id = seed_tenant("audit-link")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, fact_a} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "lnk-a",
            content: "a",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, fact_b} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "lnk-b",
            content: "b",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, link} =
        Link.create_link(
          %{
            from_fact_id: fact_a.id,
            to_fact_id: fact_b.id,
            relation: :supersedes,
            confidence: 0.9
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :memory_write, :memory_link, link.id),
             "expected :memory_write audit row for link"
    end

    test "Memory.ConsolidationRun.record_run emits :memory_consolidation" do
      tenant_id = seed_tenant("audit-cons")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, run} =
        ConsolidationRun.record_run(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            status: :succeeded,
            facts_added: 1,
            blocks_written: 0,
            links_added: 0
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :memory_consolidation, :memory_consolidation_run, run.id),
             "expected :memory_consolidation audit row for record_run"
    end

    test "Solution.store (shared/public) emits :solution_share" do
      tenant_id = seed_tenant("audit-sol-share2")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, sol} =
        Solution.store(
          %{
            problem_signature: "sig-share2-#{System.unique_integer([:positive])}",
            solution_content: "shared content",
            language: "elixir",
            sharing: :public,
            workspace_id: ws.id,
            embedding_status: :disabled
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :solution_share, :solution, sol.id),
             "expected :solution_share audit row for public solution"
    end

    test "Session.start / Session.close emit :session_start and :session_end" do
      tenant_id = seed_tenant("audit-sessions")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: "ext-real-#{System.unique_integer([:positive])}",
            started_at: DateTime.utc_now()
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _closed} = Session.close(session, %{}, tenant: tenant_id, actor: actor_for(tenant_id))

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      assert find_audit(rows, :session_start, :session, session.id),
             "expected :session_start audit row"

      assert find_audit(rows, :session_end, :session, session.id),
             "expected :session_end audit row"
    end
  end
end
