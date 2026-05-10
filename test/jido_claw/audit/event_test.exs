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

      assert {:error, %Ash.Error.Invalid{} = err} = Event.record(attrs, tenant: tenant_id)
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

      assert {:ok, row} = Event.record(attrs, tenant: tenant_id)
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
          tenant: tenant_id
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
          tenant: tenant_id
        )

      {:ok, rows} = Event.for_target(:tool, "demo_tool", tenant: tenant_id)
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
          tenant: tenant_id
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
          tenant: tenant_id
        )

      {:ok, rows} = Event.for_actor(:agent, "main", tenant: tenant_id)
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
          tenant: tenant_a
        )

      {:ok, b_rows} = Event.read(tenant: tenant_b)
      refute Enum.any?(b_rows, &(&1.target_id == "tenant_a_tool"))

      {:ok, a_rows} = Event.read(tenant: tenant_a)
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

        assert {:ok, row} = Event.record(attrs, tenant: tenant_id),
               "expected event_kind=#{kind} to be accepted by :record"

        assert row.event_kind == kind
      end
    end
  end
end
