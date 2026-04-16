defmodule JidoClaw.CLI.Main do
  @moduledoc """
  Escript entrypoint for the `jido` CLI binary.

  Usage:
    jido                  # start in current directory
    jido /path/to/project # start in target directory
    jido --mcp            # start as MCP server (stdio transport)
  """

  def main(["--mcp" | _rest]) do
    start_mcp()
  end

  def main(["--setup" | args]) do
    Application.put_env(:jido_claw, :force_setup, true)
    main(args)
  end

  def main(args) do
    Application.ensure_all_started(:jido_claw)

    project_dir =
      case args do
        [dir | _] ->
          expanded = Path.expand(dir)
          if File.dir?(expanded), do: expanded, else: File.cwd!()

        [] ->
          File.cwd!()
      end

    JidoClaw.CLI.Repl.start(project_dir)
  end

  defp start_mcp do
    Application.put_env(:jido_claw, :serve_mode, :mcp)
    # Skip Phoenix endpoint and Discord in MCP mode — stdio must stay clean.
    Application.put_env(:jido_claw, :mode, :cli)
    Application.put_env(:jido_claw, :skip_discord, true)
    Application.ensure_all_started(:jido_claw)
    # Block forever — the MCPServer GenServer owns the stdin loop.
    Process.sleep(:infinity)
  end
end
