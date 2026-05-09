defmodule JidoClaw.Embeddings.BootGuardTest do
  @moduledoc """
  Coverage for the §2 Voyage boot guard.

  Locks in:
    * Strict + unset → `RuntimeError`.
    * Strict + key present → `:ok`.
    * `embeddings_strict_boot: false` (test env default) → bypassed.
    * `:first_run_setup_pending` → bypassed regardless of strictness.
  """

  use ExUnit.Case, async: false

  alias JidoClaw.Embeddings.BootGuard

  setup do
    prior_strict = Application.get_env(:jido_claw, :embeddings_strict_boot)
    prior_first_run = Application.get_env(:jido_claw, :first_run_setup_pending)
    prior_key = System.get_env("VOYAGE_API_KEY")

    on_exit(fn ->
      restore_app_env(:embeddings_strict_boot, prior_strict)
      restore_app_env(:first_run_setup_pending, prior_first_run)
      restore_env("VOYAGE_API_KEY", prior_key)
    end)

    :ok
  end

  describe "assert_voyage_key_or_raise!/0" do
    test "strict + unset → raises RuntimeError" do
      Application.put_env(:jido_claw, :embeddings_strict_boot, true)
      Application.delete_env(:jido_claw, :first_run_setup_pending)
      System.delete_env("VOYAGE_API_KEY")

      assert_raise RuntimeError, ~r/VOYAGE_API_KEY/, fn ->
        BootGuard.assert_voyage_key_or_raise!()
      end
    end

    test "strict + key set → :ok" do
      Application.put_env(:jido_claw, :embeddings_strict_boot, true)
      Application.delete_env(:jido_claw, :first_run_setup_pending)
      System.put_env("VOYAGE_API_KEY", "vy-test-key")

      assert :ok = BootGuard.assert_voyage_key_or_raise!()
    end

    test "non-strict + unset → :ok" do
      Application.put_env(:jido_claw, :embeddings_strict_boot, false)
      Application.delete_env(:jido_claw, :first_run_setup_pending)
      System.delete_env("VOYAGE_API_KEY")

      assert :ok = BootGuard.assert_voyage_key_or_raise!()
    end

    test "first_run_setup_pending bypasses guard even when strict + unset" do
      Application.put_env(:jido_claw, :embeddings_strict_boot, true)
      Application.put_env(:jido_claw, :first_run_setup_pending, true)
      System.delete_env("VOYAGE_API_KEY")

      assert :ok = BootGuard.assert_voyage_key_or_raise!()
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
