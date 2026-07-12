defmodule Mix.Tasks.Jidoclaw do
  @moduledoc """
  Start the JidoClaw agent REPL, MCP server, or a headless one-shot run.

      mix jidoclaw [dir]                    # interactive REPL
      mix jidoclaw --resume <uuid> [dir]    # REPL, resuming a session by UUID
      mix jidoclaw --continue [dir]         # REPL, resuming the most recent CLI session
      mix jidoclaw --mcp                    # MCP server (stdio)
      mix jidoclaw --setup [dir]            # first-run setup wizard
      mix jidoclaw run "<prompt>" [dir] [--session <uuid> | --continue]
                    [--timeout <seconds>] [--format text|json]

  `run` exits 0 (success), 1 (error/failed run/timeout), 2 (usage/config
  error), 3 (approval gate or clarify questions pending), 4 (session not
  found), 5 (provider unreachable), or 6 (provider auth failure). Invalid or
  conflicting REPL flags (e.g. `--bogus`, a valueless or empty `--resume`,
  `--resume <uuid> --continue`) also exit 2 instead of silently booting a
  fresh session.
  """
  @shortdoc "Start JidoClaw"

  use Mix.Task

  require Logger

  alias JidoClaw.CLI.Repl
  alias JidoClaw.CLI.ReplArgs
  alias JidoClaw.CLI.RunCommand
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

  def run(["run" | rest]) do
    {code, output} =
      RunCommand.main(rest,
        boot: fn ->
          # Redirect BEFORE app start — stdout carries only the result.
          JidoClaw.Application.redirect_logger_to_stderr()
          Mix.Task.run("app.start")
        end
      )

    IO.puts(output)
    System.halt(code)
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
    case ReplArgs.parse(args) do
      {:ok, parsed} ->
        Application.put_env(:jido_claw, :project_dir, parsed.project_dir)

        Mix.Task.run("app.start")

        Repl.start(parsed.project_dir, resume: parsed.resume, continue: parsed.continue)

      {:usage, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, "usage: mix jidoclaw [dir] [--resume <uuid> | --continue]")
        System.halt(2)
    end
  end
end
