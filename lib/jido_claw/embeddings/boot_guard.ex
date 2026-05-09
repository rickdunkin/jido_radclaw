defmodule JidoClaw.Embeddings.BootGuard do
  @moduledoc """
  Boot-time guard that asserts `VOYAGE_API_KEY` is present before the
  supervision tree starts.

  Strict mode is governed by
  `Application.get_env(:jido_claw, :embeddings_strict_boot, true)`. When
  strict mode is on and the key is missing, the application refuses to
  start. The guard is bypassed during the first-run setup wizard via
  `:first_run_setup_pending`, so the wizard can capture the key and
  persist it to `.env`.
  """

  @doc """
  Assert that `VOYAGE_API_KEY` is set in the environment, or raise a
  `RuntimeError` with a one-line remediation message.

  Skipped when:
    * `:embeddings_strict_boot` is `false` (test env, opt-out config), OR
    * `:first_run_setup_pending` is `true` (the `--setup` arm).
  """
  @spec assert_voyage_key_or_raise!() :: :ok
  def assert_voyage_key_or_raise! do
    cond do
      first_run_setup?() ->
        :ok

      not strict?() ->
        :ok

      key_present?() ->
        :ok

      true ->
        raise RuntimeError, """
        VOYAGE_API_KEY is not set.

        Set `VOYAGE_API_KEY` in your environment or `.env`. If you need to
        run setup, invoke `mix jidoclaw --setup`. To run jido_claw without
        embeddings, set `config :jido_claw, :embeddings_strict_boot, false`
        in your config.
        """
    end
  end

  defp first_run_setup?,
    do: Application.get_env(:jido_claw, :first_run_setup_pending, false) == true

  defp strict?,
    do: Application.get_env(:jido_claw, :embeddings_strict_boot, true) == true

  defp key_present? do
    case System.get_env("VOYAGE_API_KEY") do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
