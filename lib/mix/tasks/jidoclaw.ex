defmodule Mix.Tasks.Jidoclaw do
  @moduledoc "Start the JidoClaw agent REPL (or MCP server with --mcp)"
  @shortdoc "Start JidoClaw"

  use Mix.Task

  require Logger

  @impl true
  def run(["--mcp" | _rest]) do
    Application.put_env(:jido_claw, :serve_mode, :mcp)
    # Skip Phoenix endpoint and Discord in MCP mode — stdio must stay clean.
    Application.put_env(:jido_claw, :mode, :cli)
    Application.put_env(:jido_claw, :skip_discord, true)
    # Redirect logging to stderr before any app starts — keeps stdout clean for MCP.
    JidoClaw.Application.redirect_logger_to_stderr()
    Mix.Task.run("app.start")
    # Block — MCPServer GenServer owns the stdin read loop.
    Process.sleep(:infinity)
  end

  def run(args) do
    Mix.Task.run("app.start")

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

end
