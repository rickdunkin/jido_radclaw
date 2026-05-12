defmodule JidoClaw.Audit.SignalListenerTest do
  @moduledoc """
  Coverage for `JidoClaw.Audit.SignalListener`.

  Locks in:

    * `:no_request_id` skip path emits the
      `[:jido_claw, :audit, :tool_call, :skipped]` telemetry event.
    * `:correlation_missing` skip path likewise emits, when the
      cache misses and Postgres lookup also fails.
    * Cache-hit path emits a `:tool_call` audit event with the
      expected scope and payload shape.
    * `safe_handle/1` swallows raises so the listener stays alive.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Audit.{AsyncWriter, Event, SignalListener}
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Core.MapKeys

  setup do
    # Each test gets a unique telemetry handler id so they don't
    # collide with each other or with the production attach.
    test_pid = self()
    handler_id = "audit-listener-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_claw, :audit, :tool_call, :skipped],
      fn _event, _measurements, metadata, _ -> send(test_pid, {:skipped, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "private handle_signal via the public listener pipeline" do
    test "skips with :no_request_id when the signal carries no request_id" do
      signal = build_signal(nil, "demo_tool", %{x: 1})

      send(SignalListener, {:signal, signal})

      assert_receive {:skipped, %{reason: :no_request_id, tool_name: "demo_tool"}}, 500
    end

    test "skips with :correlation_missing when neither cache nor DB has the request_id" do
      request_id = "missing-#{System.unique_integer([:positive])}"
      Cache.delete(request_id)

      signal = build_signal(request_id, "demo_tool", %{})

      send(SignalListener, {:signal, signal})

      assert_receive {:skipped, %{reason: :correlation_missing, tool_name: "demo_tool"}}, 500
    end

    test "cache-hit path writes a :tool_call audit event with the expected payload" do
      tenant_id = seed_tenant("listener-cache")
      session_id = Ecto.UUID.generate()
      request_id = "ok-#{System.unique_integer([:positive])}"

      Cache.put(request_id, %{
        session_id: session_id,
        tenant_id: tenant_id,
        workspace_id: nil,
        user_id: nil
      })

      signal = build_signal(request_id, "demo_tool", %{path: "x"})

      send(SignalListener, {:signal, signal})

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

          Enum.any?(rows, fn r ->
            r.event_kind == :tool_call and r.target_id == "demo_tool"
          end)
        end)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))
      [row] = Enum.filter(rows, &(&1.target_id == "demo_tool" and &1.event_kind == :tool_call))

      assert row.actor_kind == :agent
      assert row.target_kind == :tool

      payload = row.payload
      assert MapKeys.coalesce_field(payload, "request_id") == request_id
      assert MapKeys.coalesce_field(payload, "tool_name") == "demo_tool"

      Cache.delete(request_id)
    end
  end

  describe "safe_handle/1" do
    test "the listener stays alive after a malformed signal is delivered" do
      pid = Process.whereis(SignalListener)
      assert is_pid(pid)
      ref = Process.monitor(pid)

      # A signal with `data: nil` trips the field/2 helper (Map.get on
      # nil) — exception is rescued, listener keeps running.
      {:ok, malformed} = Jido.Signal.new("ai.tool.started", nil)
      send(SignalListener, {:signal, malformed})

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert Process.alive?(pid)
    end
  end

  defp build_signal(request_id, tool_name, arguments) do
    {:ok, signal} =
      Jido.Signal.new("ai.tool.started", %{
        tool_name: tool_name,
        arguments: arguments,
        metadata: if(request_id, do: %{request_id: request_id}, else: %{})
      })

    signal
  end

  # Suppress unused-alias warnings for AsyncWriter — referenced via the
  # transitive listener path; the alias keeps the moduledoc anchor stable.
  @compile {:no_warn_undefined, AsyncWriter}

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
