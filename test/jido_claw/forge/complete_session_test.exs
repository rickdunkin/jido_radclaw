defmodule JidoClaw.Forge.CompleteSessionTest do
  @moduledoc """
  AR-8b-2 F2 (1.3): `Forge.complete_session/1` closes the session as a Harness
  self-stop with `reason: :normal` — the exit reason that makes `terminate/2`'s
  `maybe_finalize_phase` finalize **`:completed`** (NOT the `:failed` a
  Manager-driven `terminate_child`'s `:shutdown` would yield), AND it tears down
  the microVM. Persistence DISABLED (in-memory GenServer, like
  `HarnessBootstrapEnvTest`) so the global Manager's async recovery never races the
  per-test sandbox; the DB-phase side is pinned deterministically in
  `JidoClaw.Forge.PersistenceCompleteTest`. The `reason: :normal` exit + that
  Persistence-layer stamp together cover the `:completed`-not-`:failed` contract.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias JidoClaw.Forge
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Test.StubSandbox

  # The `:forge_persistence` seam stub (1.3): a `:complete` stamp that FAILS.
  defmodule FailingPersistence do
    @spec complete_session(String.t()) :: {:error, term()}
    def complete_session(_session_id), do: {:error, :forced_stamp_failure}
  end

  setup do
    prev_p = Application.get_env(:jido_claw, JidoClaw.Forge.Persistence, [])
    Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, enabled: false)
    on_exit(fn -> Application.put_env(:jido_claw, JidoClaw.Forge.Persistence, prev_p) end)
    :ok
  end

  defp start_ready_session do
    sid = "complete_#{:erlang.unique_integer([:positive])}"
    ForgePubSub.subscribe(sid)
    {:ok, %{pid: pid}} = Forge.start_session(sid, %{runner: :shell, sandbox: StubSandbox})
    assert_receive {:ready, ^sid}, 10_000
    {sid, pid}
  end

  # The Registry's monitor cleanup is async after the child dies, so `get_handle`
  # can briefly return the stale pid — poll until it clears.
  defp assert_child_gone(sid) do
    cleared? =
      Enum.reduce_while(1..100, false, fn _i, _acc ->
        case Forge.get_handle(sid) do
          {:error, :not_found} -> {:halt, true}
          _ -> Process.sleep(10) && {:cont, false}
        end
      end)

    assert cleared?, "expected the Forge child for #{sid} to be torn down"
  end

  test "a clean complete closes the session with reason :normal and tears down the child" do
    {sid, pid} = start_ready_session()
    ref = Process.monitor(pid)

    assert :ok = Forge.complete_session(sid)

    # `:normal` (NOT `:shutdown`) is exactly what drives terminate's
    # `:normal ⇒ :completed` finalizer — never `:failed`.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    assert_child_gone(sid)
  end

  test "a stamp-failing complete STILL closes with reason :normal (the :completed fallback)" do
    {sid, pid} = start_ready_session()
    ref = Process.monitor(pid)

    prev = Application.get_env(:jido_claw, :forge_persistence)
    Application.put_env(:jido_claw, :forge_persistence, FailingPersistence)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:jido_claw, :forge_persistence)
        value -> Application.put_env(:jido_claw, :forge_persistence, value)
      end
    end)

    assert :ok = Forge.complete_session(sid)

    # Even when the `:complete` stamp returns `{:error, _}`, the close stays
    # `:normal` — so terminate finalizes `:completed`, never `:failed`.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    assert_child_gone(sid)
  end
end
