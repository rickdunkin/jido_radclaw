defmodule JidoClaw.Audit.AsyncWriterTest do
  @moduledoc """
  Coverage for `JidoClaw.Audit.AsyncWriter`.

  Locks in:

    * Both `sync/1` and `cast/1` strip `tenant_id` from attrs and
      thread it via the `tenant:` opt — matches the Audit.Event
      `:attribute global? false` contract.
    * `sync/1` returns `:ok` even when the underlying Ash write
      errors (logs the warning, never raises).
    * `cast/1` runs under `Audit.TaskSupervisor` and never raises out.
    * Attrs without `tenant_id` are dropped with a logged warning;
      no row is written.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.{AsyncWriter, Event}

  describe "sync/1" do
    test "strips tenant_id from attrs and threads it via :tenant; row carries the right tenant" do
      tenant_id = seed_tenant("async-sync")

      attrs = %{
        tenant_id: tenant_id,
        event_kind: :tool_call,
        actor_kind: :agent,
        actor_id: "main",
        target_kind: :tool,
        target_id: "demo_tool",
        payload: %{request_id: "rsync"}
      }

      assert :ok = AsyncWriter.sync(attrs)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
      [row] = Enum.filter(rows, &(&1.target_id == "demo_tool"))
      assert row.tenant_id == tenant_id
      assert row.actor_id == "main"
    end

    test "returns :ok even when the underlying Ash write fails (e.g. invalid event_kind)" do
      tenant_id = seed_tenant("async-sync-error")

      bad_attrs = %{
        tenant_id: tenant_id,
        # Not in the @event_kinds enum.
        event_kind: :not_a_real_kind,
        actor_kind: :agent,
        target_kind: :tool,
        payload: %{}
      }

      assert :ok = AsyncWriter.sync(bad_attrs)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
      refute Enum.any?(rows, &(&1.event_kind == :not_a_real_kind))
    end

    test "drops attrs without tenant_id (logs warning, returns :ok, writes nothing)" do
      attrs = %{
        # tenant_id intentionally absent
        event_kind: :tool_call,
        actor_kind: :system,
        target_kind: :tool,
        payload: %{}
      }

      assert :ok = AsyncWriter.sync(attrs)
      # No FK to point at, so we just verify the call returned and
      # didn't raise. There's no way to read this row back without a
      # tenant scope.
    end
  end

  describe "cast/1" do
    test "spawns under Audit.TaskSupervisor and writes the row" do
      tenant_id = seed_tenant("async-cast")

      attrs = %{
        tenant_id: tenant_id,
        event_kind: :tool_call,
        actor_kind: :agent,
        actor_id: "main",
        target_kind: :tool,
        target_id: "cast_tool",
        payload: %{}
      }

      assert :ok = AsyncWriter.cast(attrs)

      # Wait for the Task.Supervisor child to drain. The Ecto sandbox
      # is in :shared mode (TenantCase default for non-async tests),
      # so the spawned process sees the same connection and writes
      # are visible immediately after the task exits.
      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
          Enum.any?(rows, &(&1.target_id == "cast_tool"))
        end)
    end

    test "cast/1 swallows Ash errors without raising" do
      tenant_id = seed_tenant("async-cast-error")

      bad_attrs = %{
        tenant_id: tenant_id,
        event_kind: :not_a_real_kind,
        actor_kind: :agent,
        target_kind: :tool,
        payload: %{}
      }

      assert :ok = AsyncWriter.cast(bad_attrs)

      # Drain any in-flight task before asserting; without this the
      # test could exit before the supervisor child has finished
      # logging the error.
      Process.sleep(50)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
      refute Enum.any?(rows, &(&1.event_kind == :not_a_real_kind))
    end
  end

  describe "enqueue/1,2" do
    test "a successful handoff returns {:ok, pid} and the row lands" do
      tenant_id = seed_tenant("async-enqueue")

      attrs = %{
        tenant_id: tenant_id,
        event_kind: :tool_call,
        actor_kind: :agent,
        actor_id: "main",
        target_kind: :tool,
        target_id: "enqueue_tool",
        payload: %{}
      }

      assert {:ok, pid} = AsyncWriter.enqueue(attrs)
      assert is_pid(pid)

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
          Enum.any?(rows, &(&1.target_id == "enqueue_tool"))
        end)
    end

    test "a returned start_child error is normalized to {:error, _}" do
      # max_children: 0 makes start_child RETURN {:error, :max_children}
      # (the non-exit failure shape).
      {:ok, sup} = Task.Supervisor.start_link(max_children: 0)

      attrs = %{tenant_id: "t", event_kind: :tool_call, target_kind: :tool, payload: %{}}

      assert {:error, :max_children} = AsyncWriter.enqueue(attrs, sup)
      :ok = Supervisor.stop(sup)
    end

    test "an unavailable supervisor EXIT (:noproc) is normalized to {:error, _}" do
      # A DEAD supervisor makes start_child EXIT rather than return —
      # the boundary must catch it, or every producer (AshTracer, auth
      # events) would crash during shutdown races.
      {:ok, sup} = Task.Supervisor.start_link()
      :ok = Supervisor.stop(sup)
      refute Process.alive?(sup)

      attrs = %{tenant_id: "t", event_kind: :tool_call, target_kind: :tool, payload: %{}}

      assert {:error, {:exit, _reason}} = AsyncWriter.enqueue(attrs, sup)
    end

    test "cast/1 stays :ok over the same failure paths" do
      # The compatibility wrapper never surfaces the enqueue result.
      attrs = %{tenant_id: "t", event_kind: :tool_call, target_kind: :tool, payload: %{}}
      assert :ok = AsyncWriter.cast(attrs)
    end
  end

  defp eventually(fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
