defmodule JidoClaw.CLI.Main do
  @moduledoc """
  Escript entrypoint for the `jido` CLI binary.

  Usage:
    jido                  # start in current directory
    jido /path/to/project # start in target directory
    jido --mcp            # start as MCP server (stdio transport)
  """

  require Logger

  def main(["--mcp" | _rest]) do
    start_mcp()
  end

  def main(["--setup" | args]) do
    Application.put_env(:jido_claw, :force_setup, true)
    main(args)
  end

  def main(args) do
    project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
    Application.put_env(:jido_claw, :project_dir, project_dir)
    Application.ensure_all_started(:jido_claw)

    JidoClaw.CLI.Repl.start(project_dir)
  end

  defp start_mcp do
    Application.put_env(:jido_claw, :serve_mode, :mcp)
    # Skip Phoenix endpoint and Discord in MCP mode — stdio must stay clean.
    Application.put_env(:jido_claw, :mode, :cli)
    Application.put_env(:jido_claw, :skip_discord, true)
    Application.put_env(:jido_claw, :project_dir, File.cwd!())
    Application.ensure_all_started(:jido_claw)

    case JidoClaw.Startup.ensure_project_state(File.cwd!()) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[JidoClaw] startup: #{inspect(reason)}")
    end

    # Block forever — the MCPServer GenServer owns the stdin loop.
    Process.sleep(:infinity)
  end
end
