defmodule JidoClaw.Conversations.RequestCorrelation.SweeperTest do
  @moduledoc """
  WS4 — the leader gate on `RequestCorrelation.Sweeper`'s periodic `:sweep`.

  The prune is an idempotent DELETE, so running it on every node is
  wasteful-but-safe; the gate just cuts the cross-node-redundant work. Drives
  the app's singleton with `send(pid, :sweep)` + a `:sys.get_state` barrier
  (per `retention_sweeper_test.exs`). `async: false` (`TenantCase`, shared
  sandbox) so the boot-supervised Sweeper sees the seeded row.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.ClusterLeaderStub
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Sweeper
  alias JidoClaw.Repo

  setup do
    saved = Application.fetch_env(:jido_claw, :cluster_leader_module)
    Application.put_env(:jido_claw, :cluster_leader_module, ClusterLeaderStub)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:jido_claw, :cluster_leader_module, value)
        :error -> Application.delete_env(:jido_claw, :cluster_leader_module)
      end

      Application.delete_env(:jido_claw, :cluster_leader_stub_result)
    end)

    :ok
  end

  test "off-leader: the :sweep tick is a no-op (the expired row survives)" do
    request_id = seed_expired_correlation()
    Application.put_env(:jido_claw, :cluster_leader_stub_result, false)

    tick_sweeper!()

    assert correlation_count(request_id) == 1
  end

  test "on-leader: the :sweep tick deletes the expired row" do
    request_id = seed_expired_correlation()
    Application.put_env(:jido_claw, :cluster_leader_stub_result, true)

    tick_sweeper!()

    assert correlation_count(request_id) == 0
  end

  defp seed_expired_correlation do
    %{tenant_id: tenant, session: session} =
      seed_full(
        tenant_label: "rc-gate",
        session: [kind: :api, external_id: "ext-#{System.unique_integer([:positive])}"]
      )

    request_id = "req-#{System.unique_integer([:positive])}"

    {:ok, _} =
      RequestCorrelation.register(%{
        request_id: request_id,
        session_id: session.id,
        tenant_id: tenant,
        # Already expired ⇒ eligible for the very next sweep.
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    request_id
  end

  # `send` + `:sys.get_state` barrier: the mailbox is FIFO, so by the time
  # get_state returns the :sweep has been fully handled.
  defp tick_sweeper! do
    pid = Process.whereis(Sweeper)
    assert is_pid(pid)
    send(pid, :sweep)
    :sys.get_state(pid)
    :ok
  end

  defp correlation_count(request_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM request_correlations WHERE request_id = $1", [request_id])

    n
  end
end
