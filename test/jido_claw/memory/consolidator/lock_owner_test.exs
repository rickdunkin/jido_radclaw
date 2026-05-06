defmodule JidoClaw.Memory.Consolidator.LockOwnerTest do
  @moduledoc """
  Unit coverage for the per-run advisory-lock holder.

  `RunServerTest` bypasses LockOwner via the
  `:consolidator_advisory_lock_disabled?` flag (LockOwner's
  `Repo.checkout/1` pin is incompatible with `Sandbox`'s shared mode),
  so the acquire/busy/release semantics are pinned here against the
  real Postgres advisory-lock primitives.

  Sandbox mode is `:auto` — each LockOwner Task takes its own pool
  connection on first query, just like in production. We don't
  rollback between tests, but advisory locks are connection-scoped
  and auto-release when the connection returns to the pool, so leaks
  aren't possible. Each test uses a unique random key so concurrent
  test invocations can't collide on the same lock.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Memory.Consolidator.LockOwner

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :auto)
    on_exit(fn -> :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :manual) end)
    :ok
  end

  describe "acquire/1" do
    test "returns {:ok, pid} when the key is uncontended" do
      key = unique_key()

      assert {:ok, pid} = LockOwner.acquire(key)
      assert is_pid(pid)
      assert Process.alive?(pid)

      :ok = LockOwner.release(pid)
    end

    test "returns :busy when another holder owns the same key" do
      key = unique_key()

      {:ok, pid1} = LockOwner.acquire(key)
      assert :busy = LockOwner.acquire(key)

      :ok = LockOwner.release(pid1)
    end

    test "different keys are independent" do
      k1 = unique_key()
      k2 = unique_key()

      {:ok, p1} = LockOwner.acquire(k1)
      {:ok, p2} = LockOwner.acquire(k2)

      assert p1 != p2

      :ok = LockOwner.release(p1)
      :ok = LockOwner.release(p2)
    end

    test "the same key can be re-acquired after release" do
      key = unique_key()

      {:ok, p1} = LockOwner.acquire(key)
      :ok = LockOwner.release(p1)

      {:ok, p2} = LockOwner.acquire(key)
      assert p2 != p1

      :ok = LockOwner.release(p2)
    end
  end

  describe "release/1" do
    test "is idempotent — returns :ok when the holder has already exited" do
      key = unique_key()
      {:ok, pid} = LockOwner.acquire(key)

      :ok = LockOwner.release(pid)
      assert :ok = LockOwner.release(pid)
    end
  end

  describe "bypass via :consolidator_advisory_lock_disabled?" do
    setup do
      Application.put_env(:jido_claw, :consolidator_advisory_lock_disabled?, true)

      on_exit(fn ->
        Application.put_env(:jido_claw, :consolidator_advisory_lock_disabled?, false)
      end)

      :ok
    end

    test "acquire returns {:ok, pid} without touching Postgres" do
      assert {:ok, pid} = LockOwner.acquire(unique_key())
      assert is_pid(pid)
    end

    test "acquire never reports :busy even with a held key" do
      key = unique_key()
      {:ok, _} = LockOwner.acquire(key)
      # In bypass mode every acquire returns {:ok, _} regardless of
      # other "holders" — there's no real lock backing it.
      assert {:ok, _} = LockOwner.acquire(key)
    end

    test "release is a no-op" do
      {:ok, pid} = LockOwner.acquire(unique_key())
      assert :ok = LockOwner.release(pid)
    end
  end

  defp unique_key, do: System.unique_integer([:positive])
end
