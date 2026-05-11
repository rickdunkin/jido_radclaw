defmodule JidoClaw.PolicyAuthzTest do
  @moduledoc """
  Acceptance test for the v0.6.4 `Ash.Policy.Authorizer`-based
  tenant-actor authorization layer.

  Covers the matrix from the rollout plan:

    1. Matching actor → success
    2. Cross-actor write → `Ash.Error.Forbidden`
    3. Cross-actor read → empty result or `NotFound` (filter, NOT
       `Forbidden`)
    4. `:by_id_global` bypass works without an actor — only on
       resources that define it (skip Audit.Event, ReputationImport)
    5. `authorize?: false` bypass works (system path)
    6. Missing actor on writes → `Ash.Error.Forbidden`
    7. Missing actor on reads → empty result (filter)
    8. `RequestCorrelation` permissive — lookup with no actor works
    9. `Tenants.Tenant` permissive read — no actor works
    10. `Audit.Event` tightened — cross-actor read empty, cross-actor
        write Forbidden
    11. `Cron.Job` tightened — same shape
    12. AsyncWriter still produces audit rows after the C.5
        `authorize?: false` opt
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit
  alias JidoClaw.Conversations
  alias JidoClaw.Cron
  alias JidoClaw.Memory
  alias JidoClaw.Solutions
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Workspace

  setup do
    tenant_a = seed_tenant("policy-a")
    tenant_b = seed_tenant("policy-b")

    actor_a = actor_for(tenant_a)
    actor_b = actor_for(tenant_b)

    {:ok, ws_a} = seed_workspace(tenant_a, actor: actor_a)
    {:ok, ws_b} = seed_workspace(tenant_b, actor: actor_b)

    {:ok, session_a} = seed_session(tenant_a, ws_a.id, actor: actor_a)
    {:ok, session_b} = seed_session(tenant_b, ws_b.id, actor: actor_b)

    %{
      tenant_a: tenant_a,
      tenant_b: tenant_b,
      actor_a: actor_a,
      actor_b: actor_b,
      ws_a: ws_a,
      ws_b: ws_b,
      session_a: session_a,
      session_b: session_b
    }
  end

  describe "matching actor → success" do
    test "Workspace.register/1 succeeds when actor.tenant_id matches", %{
      tenant_a: tenant,
      actor_a: actor
    } do
      assert {:ok, _ws} =
               Workspace.register(
                 %{path: "/tmp/match-#{System.unique_integer([:positive])}", name: "ok"},
                 tenant: tenant,
                 actor: actor
               )
    end

    test "Memory.Fact.record/1 succeeds for matching actor", %{
      tenant_a: tenant,
      actor_a: actor,
      ws_a: ws
    } do
      assert {:ok, _fact} =
               Memory.Fact.record(
                 %{
                   scope_kind: :workspace,
                   workspace_id: ws.id,
                   label: "lbl-#{System.unique_integer([:positive])}",
                   content: "content",
                   source: :user_save,
                   trust_score: 0.7
                 },
                 tenant: tenant,
                 actor: actor
               )
    end

    test "Cron.Job.upsert succeeds for matching actor", %{tenant_a: tenant, actor_a: actor} do
      assert {:ok, _job} =
               Cron.Job.upsert(
                 %{
                   job_id: "job-#{System.unique_integer([:positive])}",
                   schedule_kind: :every,
                   schedule_value: "60000",
                   mode: :main,
                   task: "noop"
                 },
                 tenant: tenant,
                 actor: actor
               )
    end

    test "Audit.Event.record succeeds for matching actor", %{tenant_a: tenant, actor_a: actor} do
      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: "demo",
        payload: %{}
      }

      assert {:ok, _row} = Audit.Event.record(attrs, tenant: tenant, actor: actor)
    end
  end

  describe "cross-actor write → Ash.Error.Forbidden" do
    test "Workspace.register with mismatched actor is forbidden", %{
      tenant_a: tenant_a,
      actor_b: actor_b
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Workspace.register(
                 %{path: "/tmp/cross-#{System.unique_integer([:positive])}", name: "x"},
                 tenant: tenant_a,
                 actor: actor_b
               )
    end

    test "Cron.Job.upsert with mismatched actor is forbidden", %{
      tenant_a: tenant_a,
      actor_b: actor_b
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Cron.Job.upsert(
                 %{
                   job_id: "x-#{System.unique_integer([:positive])}",
                   schedule_kind: :every,
                   schedule_value: "60000",
                   mode: :main,
                   task: "noop"
                 },
                 tenant: tenant_a,
                 actor: actor_b
               )
    end

    test "Cron.Job.disable (update) with mismatched actor is forbidden", %{
      tenant_a: tenant_a,
      actor_a: actor_a,
      actor_b: actor_b
    } do
      {:ok, job} =
        Cron.Job.upsert(
          %{
            job_id: "update-cross-#{System.unique_integer([:positive])}",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant_a,
          actor: actor_a
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Cron.Job.disable(job, tenant: tenant_a, actor: actor_b)
    end

    test "Cron.Job.remove (destroy) with mismatched actor is forbidden", %{
      tenant_a: tenant_a,
      actor_a: actor_a,
      actor_b: actor_b
    } do
      {:ok, job} =
        Cron.Job.upsert(
          %{
            job_id: "destroy-cross-#{System.unique_integer([:positive])}",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant_a,
          actor: actor_a
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Cron.Job.remove(job, tenant: tenant_a, actor: actor_b)
    end
  end

  describe "cross-actor read → empty result (filter)" do
    test "Audit.Event.read returns empty when actor's tenant doesn't match", %{
      tenant_a: tenant_a,
      actor_a: actor_a,
      tenant_b: tenant_b,
      actor_b: actor_b
    } do
      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: "cross-read-#{System.unique_integer([:positive])}",
        payload: %{}
      }

      {:ok, _row} = Audit.Event.record(attrs, tenant: tenant_a, actor: actor_a)

      # Reading from tenant_a with actor_b returns empty (filter behavior).
      {:ok, rows} = Audit.Event.read(tenant: tenant_a, actor: actor_b)
      refute Enum.any?(rows, &(&1.target_id == attrs.target_id))

      # Same from the other direction.
      {:ok, _row} =
        Audit.Event.record(
          %{attrs | target_id: "cross-read-2-#{System.unique_integer([:positive])}"},
          tenant: tenant_b,
          actor: actor_b
        )

      {:ok, rows2} = Audit.Event.read(tenant: tenant_b, actor: actor_a)
      refute Enum.any?(rows2, fn r -> String.starts_with?(r.target_id, "cross-read-2") end)
    end
  end

  describe ":by_id_global bypass works without an actor" do
    test "Workspace.by_id_global returns the row regardless of actor", %{ws_a: ws} do
      assert {:ok, fetched} = Workspace.by_id_global(ws.id)
      assert fetched.id == ws.id
    end

    test "Cron.Job.by_id_global returns the row regardless of actor", %{
      tenant_a: tenant,
      actor_a: actor
    } do
      {:ok, job} =
        Cron.Job.upsert(
          %{
            job_id: "bypass-#{System.unique_integer([:positive])}",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant,
          actor: actor
        )

      assert {:ok, fetched} = Cron.Job.by_id_global(job.id)
      assert fetched.id == job.id
    end
  end

  describe "authorize?: false bypass works" do
    test "Audit.Event.record/2 with authorize?: false succeeds without an actor", %{
      tenant_a: tenant
    } do
      attrs = %{
        event_kind: :tool_call,
        actor_kind: :system,
        target_kind: :tool,
        target_id: "bypass-write-#{System.unique_integer([:positive])}",
        payload: %{}
      }

      assert {:ok, _row} = Audit.Event.record(attrs, tenant: tenant, authorize?: false)
    end
  end

  describe "missing actor on writes → Forbidden" do
    test "Workspace.register/1 with no actor is forbidden", %{tenant_a: tenant} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Workspace.register(
                 %{path: "/tmp/no-actor-#{System.unique_integer([:positive])}", name: "x"},
                 tenant: tenant
               )
    end

    test "Cron.Job.upsert with no actor is forbidden", %{tenant_a: tenant} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Cron.Job.upsert(
                 %{
                   job_id: "no-actor-#{System.unique_integer([:positive])}",
                   schedule_kind: :every,
                   schedule_value: "60000",
                   mode: :main,
                   task: "noop"
                 },
                 tenant: tenant
               )
    end
  end

  describe "missing actor on reads → empty result" do
    test "Audit.Event.read returns empty when no actor supplied", %{
      tenant_a: tenant,
      actor_a: actor
    } do
      target_id = "missing-actor-read-#{System.unique_integer([:positive])}"

      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: target_id,
        payload: %{}
      }

      {:ok, _row} = Audit.Event.record(attrs, tenant: tenant, actor: actor)

      {:ok, rows} = Audit.Event.read(tenant: tenant)
      refute Enum.any?(rows, &(&1.target_id == target_id))
    end
  end

  describe "RequestCorrelation permissive" do
    test "lookup with no actor still works", %{tenant_a: tenant, session_a: session} do
      request_id = "perm-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Conversations.RequestCorrelation.register(
          %{
            request_id: request_id,
            session_id: session.id,
            tenant_id: tenant,
            workspace_id: session.workspace_id,
            user_id: nil
          },
          tenant: tenant
        )

      assert {:ok, %{request_id: ^request_id}} =
               Conversations.RequestCorrelation.lookup(request_id, tenant: tenant)
    end
  end

  describe "Tenants.Tenant permissive read" do
    test "by_id with no actor still works", %{tenant_a: tenant} do
      assert {:ok, %Tenant{id: ^tenant}} = Tenant.by_id(tenant)
    end
  end

  describe "Audit.Event tightened" do
    test "cross-actor write returns Forbidden", %{tenant_a: tenant_a, actor_b: actor_b} do
      attrs = %{
        event_kind: :tool_call,
        actor_kind: :agent,
        target_kind: :tool,
        target_id: "tight-write",
        payload: %{}
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               Audit.Event.record(attrs, tenant: tenant_a, actor: actor_b)
    end
  end

  describe "Cron.Job tightened" do
    test "cross-actor read returns empty (filter)", %{
      tenant_a: tenant_a,
      actor_a: actor_a,
      actor_b: actor_b
    } do
      {:ok, job} =
        Cron.Job.upsert(
          %{
            job_id: "tight-read-#{System.unique_integer([:positive])}",
            schedule_kind: :every,
            schedule_value: "60000",
            mode: :main,
            task: "noop"
          },
          tenant: tenant_a,
          actor: actor_a
        )

      assert {:ok, rows} = Cron.Job.for_tenant(tenant: tenant_a, actor: actor_b)
      refute Enum.any?(rows, &(&1.id == job.id))
    end
  end

  describe "AsyncWriter regression — system audit writes succeed" do
    test "Session.start producer writes :session_start audit row via AsyncWriter", %{
      tenant_a: tenant,
      actor_a: actor,
      ws_a: ws
    } do
      {:ok, session} =
        Conversations.Session.start(
          %{
            workspace_id: ws.id,
            kind: :api,
            external_id: "audit-#{System.unique_integer([:positive])}",
            started_at: DateTime.utc_now()
          },
          tenant: tenant,
          actor: actor
        )

      {:ok, rows} = Audit.Event.read(tenant: tenant, actor: actor)

      assert Enum.any?(rows, fn r ->
               r.event_kind == :session_start and r.target_id == to_string(session.id)
             end)
    end
  end

  describe "Solutions.Solution policies" do
    test "matching actor → success", %{tenant_a: tenant, actor_a: actor, ws_a: ws} do
      assert {:ok, _sol} =
               Solutions.Solution.store(
                 %{
                   problem_signature: "sig-#{System.unique_integer([:positive])}",
                   solution_content: "content",
                   language: "elixir",
                   sharing: :local,
                   workspace_id: ws.id,
                   embedding_status: :disabled
                 },
                 tenant: tenant,
                 actor: actor
               )
    end

    test "cross-actor write → Forbidden", %{
      tenant_a: tenant,
      actor_b: actor_b,
      ws_a: ws
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Solutions.Solution.store(
                 %{
                   problem_signature: "sig-x-#{System.unique_integer([:positive])}",
                   solution_content: "content",
                   language: "elixir",
                   sharing: :local,
                   workspace_id: ws.id,
                   embedding_status: :disabled
                 },
                 tenant: tenant,
                 actor: actor_b
               )
    end
  end
end
