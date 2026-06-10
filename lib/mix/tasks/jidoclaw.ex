defmodule Mix.Tasks.Jidoclaw do
  @moduledoc "Start the JidoClaw agent REPL (or MCP server with --mcp)"
  @shortdoc "Start JidoClaw"

  use Mix.Task

  require Logger

  alias JidoClaw.CLI.Repl
  alias JidoClaw.CLI.Setup

  @impl Mix.Task
  def run(["--mcp" | _rest]) do
    Application.put_env(:jido_claw, :serve_mode, :mcp)
    # Skip Phoenix endpoint and Discord in MCP mode — stdio must stay clean.
    Application.put_env(:jido_claw, :mode, :cli)
    Application.put_env(:jido_claw, :skip_discord, true)
    Application.put_env(:jido_claw, :project_dir, File.cwd!())
    # Redirect logging to stderr before any app starts — keeps stdout clean for MCP.
    JidoClaw.Application.redirect_logger_to_stderr()
    Mix.Task.run("app.start")

    case JidoClaw.Startup.ensure_project_state(File.cwd!()) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[JidoClaw] startup: #{inspect(reason)}")
    end

    # Block — MCPServer GenServer owns the stdin read loop.
    Process.sleep(:infinity)
  end

  def run(["--setup" | args]) do
    project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
    Application.put_env(:jido_claw, :project_dir, project_dir)
    # Bypass the boot guard so the wizard can capture VOYAGE_API_KEY.
    Application.put_env(:jido_claw, :first_run_setup_pending, true)

    Mix.Task.run("app.start")

    Setup.run(project_dir)
    IO.puts("Setup complete — restart with `mix jidoclaw`.")
  end

  def run(args) do
    project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
    Application.put_env(:jido_claw, :project_dir, project_dir)

    Mix.Task.run("app.start")

    Repl.start(project_dir)
  end
end
