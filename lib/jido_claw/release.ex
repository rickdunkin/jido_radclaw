defmodule JidoClaw.Release do
  @moduledoc """
  Release-only operational tasks.

  These functions are intended to be run from an assembled release, for example:

      bin/jido_claw eval "JidoClaw.Release.migrate()"
  """

  @app :jido_claw

  @doc """
  Runs all pending Ecto migrations for configured repos.
  """
  @spec migrate() :: :ok
  def migrate do
    :ok = load_app()

    Enum.each(repos(), &migrate_repo/1)
  end

  defp migrate_repo(repo) do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end
end
