defmodule JidoClaw.Audit.EventTest do
  @moduledoc """
  Direct coverage for the `JidoClaw.Audit.Event` resource.

  Locks in:

    * `:record` requires `tenant:` opt; `tenant_id` is NOT in accept
      list (writes that try to set it via attrs are rejected).
    * Resource is append-only — no `:update`, no `:destroy` exposed.
    * `:for_target` and `:for_actor` filter to the supplied keys
      under the active tenant.
    * Multitenancy boundary: a row written under tenant A is not
      visible from a `:read` under tenant B.
    * Each `event_kind` enum value accepts a representative payload.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.Event
  alias JidoClaw.Conversations.Message, as: ConversationsMessage
  alias JidoClaw.Cron.Job, as: CronJob
  alias JidoClaw.Memory.Block, as: MemoryBlock
  alias JidoClaw.Memory.ConsolidationRun
  alias JidoClaw.Memory.Episode
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Memory.Link, as: MemoryLink
  alias JidoClaw.Solutions.Reputation
  alias JidoClaw.Solutions.Solution

  describe ":record" do
    test "requires tenant: opt; rejects writes without tenant" do
      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: "no-tenant",
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{}} = Event.record(attrs)
    end

    test "tenant_id is not in the :record accept list — rejected when supplied via attrs" do
      tenant_id = seed_tenant("audit-attr")

      attrs = %{
        tenant_id: "wrong-tenant",
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: "x",
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert inspect(err) =~ "NoSuchInput" or inspect(err) =~ "tenant_id"
    end

    test "writes a row under the supplied tenant when called correctly" do
      tenant_id = seed_tenant("audit-write")

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        actor_id: "main",
        target_kind: :tool,
        target_id: "demo_tool",
        payload: %{request_id: "r1"}
      }

      assert {:ok, row} = Event.record(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert row.tenant_id == tenant_id
      assert row.event_kind == :tool_call
      assert row.actor_kind == :agent
      assert row.actor_id == "main"
      assert row.target_kind == :tool
      assert row.target_id == "demo_tool"
      assert row.payload == %{"request_id" => "r1"} or row.payload == %{request_id: "r1"}
    end
  end

  describe "append-only contract" do
    test "no :update action is exposed via the code interface" do
      refute function_exported?(Event, :update, 1)
      refute function_exported?(Event, :update, 2)
      refute function_exported?(Event, :update, 3)
    end

    test "no :destroy action is exposed via the code interface" do
      refute function_exported?(Event, :destroy, 1)
      refute function_exported?(Event, :destroy, 2)
    end
  end

  describe ":for_target / :for_actor" do
    test ":for_target returns matching rows under the active tenant" do
      tenant_id = seed_tenant("audit-target")

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            target_kind: :tool,
            target_id: "demo_tool",
            payload: %{}
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            target_kind: :tool,
            target_id: "other_tool",
            payload: %{}
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} =
        Event.for_target(:tool, "demo_tool", tenant: tenant_id, actor: actor_for(tenant_id))

      assert length(rows) == 1
      [row] = rows
      assert row.target_id == "demo_tool"
    end

    test ":for_actor returns matching rows under the active tenant" do
      tenant_id = seed_tenant("audit-actor")

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            actor_id: "main",
            target_kind: :tool,
            target_id: "x",
            payload: %{}
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            actor_id: "researcher",
            target_kind: :tool,
            target_id: "y",
            payload: %{}
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, rows} =
        Event.for_actor(:agent, "main", tenant: tenant_id, actor: actor_for(tenant_id))

      assert length(rows) == 1
      [row] = rows
      assert row.actor_id == "main"
    end
  end

  describe "multitenancy boundary" do
    test "rows from tenant A are invisible to a :read under tenant B" do
      tenant_a = seed_tenant("audit-tenant-a")
      tenant_b = seed_tenant("audit-tenant-b")

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            target_kind: :tool,
            target_id: "tenant_a_tool",
            payload: %{}
          },
          tenant: tenant_a,
          actor: actor_for(tenant_a)
        )

      {:ok, b_rows} = Event.read(tenant: tenant_b, actor: actor_for(tenant_b))
      refute Enum.any?(b_rows, &(&1.target_id == "tenant_a_tool"))

      {:ok, a_rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))
      assert Enum.any?(a_rows, &(&1.target_id == "tenant_a_tool"))
    end
  end

  describe "event_kind enum coverage" do
    test "every event_kind value is accepted" do
      tenant_id = seed_tenant("audit-kinds")

      kinds = [
        :memory_write,
        :memory_consolidation,
        :solution_share,
        :session_start,
        :session_end,
        :tool_call,
        :auth_event
      ]

      for kind <- kinds do
        attrs = %{
          event_kind: kind,
          actor_kind: :system,
          target_kind: :auth,
          payload: %{kind: kind}
        }

        assert {:ok, row} = Event.record(attrs, tenant: tenant_id, actor: actor_for(tenant_id)),
               "expected event_kind=#{kind} to be accepted by :record"

        assert row.event_kind == kind
      end
    end
  end

  describe "cross-tenant isolation" do
    test "Event.read(tenant: tenant_a, actor: actor_for(tenant_a)) returns no tenant_b rows" do
      tenant_a = seed_tenant("cross-iso-a")
      tenant_b = seed_tenant("cross-iso-b")

      {:ok, _} =
        Event.record(
          %{
            event_kind: :tool_call,
            actor_kind: :agent,
            target_kind: :tool,
            target_id: "tenant-b-only",
            payload: %{}
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      {:ok, a_rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))
      refute Enum.any?(a_rows, &(&1.tenant_id == tenant_b))
      refute Enum.any?(a_rows, &(&1.target_id == "tenant-b-only"))
    end

    test "Event.for_target(:session, session_b_id, tenant: tenant_a, actor: actor_for(tenant_a)) returns []" do
      tenant_a = seed_tenant("cross-target-a")
      %{tenant_id: tenant_b, session: session_b} = seed_full(tenant_label: "cross-target-b")

      {:ok, _} =
        Event.record(
          %{
            event_kind: :session_start,
            actor_kind: :system,
            target_kind: :session,
            target_id: to_string(session_b.id),
            payload: %{}
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      {:ok, rows} =
        Event.for_target(:session, session_b.id, tenant: tenant_a, actor: actor_for(tenant_a))

      assert rows == []
    end
  end

  describe "cross-tenant FK validation" do
    test ":workspace target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-ws-a")
      tenant_b = seed_tenant("fk-ws-b")
      {:ok, ws_b} = seed_workspace(tenant_b)

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :workspace,
        target_id: to_string(ws_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":session target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-sess-a")
      %{tenant_id: tenant_b, session: session_b} = seed_full(tenant_label: "fk-sess-b")

      assert tenant_b != tenant_a

      attrs = %{
        event_kind: :session_start,
        actor_kind: :system,
        target_kind: :session,
        target_id: to_string(session_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":message target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-msg-a")
      %{tenant_id: tenant_b, session: session_b} = seed_full(tenant_label: "fk-msg-b")

      {:ok, msg_b} =
        ConversationsMessage.append(
          %{
            session_id: session_b.id,
            role: :user,
            content: "hi"
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :message,
        target_id: to_string(msg_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":memory_fact target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-fact-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-fact-b")

      {:ok, fact_b} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "lbl",
            content: "content",
            source: :user_save,
            trust_score: 0.7,
            written_by: nil
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :memory_write,
        actor_kind: :user,
        target_kind: :memory_fact,
        target_id: to_string(fact_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":solution target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-sol-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-sol-b")

      {:ok, sol_b} =
        Solution.store(
          %{
            problem_signature: "sig-fk-#{System.unique_integer([:positive])}",
            solution_content: "content",
            language: "elixir",
            sharing: :local,
            workspace_id: ws_b.id,
            embedding_status: :disabled
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :solution_share,
        actor_kind: :agent,
        target_kind: :solution,
        target_id: to_string(sol_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":memory_block target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-block-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-block-b")

      {:ok, block_b} =
        MemoryBlock.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "fk-block",
            value: "v1",
            source: :user
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :memory_write,
        actor_kind: :user,
        target_kind: :memory_block,
        target_id: to_string(block_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":memory_episode target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-ep-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-ep-b")

      {:ok, ep_b} =
        Episode.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            kind: :transcript
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :memory_write,
        actor_kind: :system,
        target_kind: :memory_episode,
        target_id: to_string(ep_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":memory_link target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-link-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-link-b")

      {:ok, fact_a_b} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "fk-link-a",
            content: "a",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      {:ok, fact_b_b} =
        Fact.record(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "fk-link-b",
            content: "b",
            source: :user_save,
            trust_score: 0.7
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      {:ok, link_b} =
        MemoryLink.create_link(
          %{
            from_fact_id: fact_a_b.id,
            to_fact_id: fact_b_b.id,
            relation: :supersedes,
            confidence: 0.9
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :memory_write,
        actor_kind: :system,
        target_kind: :memory_link,
        target_id: to_string(link_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":memory_consolidation_run target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-cons-a")
      %{tenant_id: tenant_b, workspace: ws_b} = seed_full(tenant_label: "fk-cons-b")

      {:ok, run_b} =
        ConsolidationRun.record_run(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            status: :succeeded
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :memory_consolidation,
        actor_kind: :system,
        target_kind: :memory_consolidation_run,
        target_id: to_string(run_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":reputation target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-rep-a")
      tenant_b = seed_tenant("fk-rep-b")

      {:ok, rep_b} =
        Reputation.upsert(
          %{agent_id: "agent-fk-rep"},
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :reputation,
        target_id: to_string(rep_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end

    test ":cron_job target referencing a parent under another tenant fails" do
      tenant_a = seed_tenant("fk-cron-a")
      tenant_b = seed_tenant("fk-cron-b")

      {:ok, job_b} =
        CronJob.upsert(
          %{
            job_id: "fk-cron-#{System.unique_integer([:positive])}",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant_b,
          actor: actor_for(tenant_b)
        )

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :system,
        target_kind: :cron_job,
        target_id: to_string(job_b.id),
        payload: %{}
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Event.record(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end
  end
end
