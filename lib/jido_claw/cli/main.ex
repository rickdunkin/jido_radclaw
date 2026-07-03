defmodule JidoClaw.CLI.Main do
  @moduledoc """
  Escript entrypoint for the `jido` CLI binary.

  Usage:
    jido                            # start in current directory
    jido /path/to/project           # start in target directory
    jido --resume <uuid> [dir]      # REPL, resuming a session by UUID
    jido --continue [dir]           # REPL, resuming the most recent CLI session
    jido --mcp                      # start as MCP server (stdio transport)
    jido run "<prompt>" [dir] [--session <uuid> | --continue]
             [--timeout <seconds>] [--format text|json]

  `run` exits 0 (success), 1 (error/failed run/timeout), 2 (usage/config
  error), or 3 (approval gate pending). Invalid or conflicting REPL flags
  (e.g. `--bogus`, a valueless or empty `--resume`, `--resume <uuid> --continue`)
  also exit 2 instead of silently booting a fresh session.
  """

  require Logger

  alias JidoClaw.CLI.Repl
  alias JidoClaw.CLI.ReplArgs
  alias JidoClaw.CLI.RunCommand
  alias JidoClaw.CLI.Setup

  @spec main([String.t()]) :: :ok | no_return()
  def main(["--mcp" | _rest]) do
    start_mcp()
  end

  def main(["run" | rest]) do
    {code, output} =
      RunCommand.main(rest,
        boot: fn ->
          # Redirect BEFORE app start — stdout carries only the result.
          JidoClaw.Application.redirect_logger_to_stderr()
          Application.ensure_all_started(:jido_claw)
        end
      )

    IO.puts(output)
    System.halt(code)
  end

  def main(["--setup" | args]) do
    project_dir = JidoClaw.Startup.resolve_project_dir_from_argv(args)
    Application.put_env(:jido_claw, :project_dir, project_dir)
    Application.put_env(:jido_claw, :first_run_setup_pending, true)
    Application.put_env(:jido_claw, :force_setup, true)
    Application.ensure_all_started(:jido_claw)
    Setup.run(project_dir)
    IO.puts("Setup complete — restart with the binary or `mix jidoclaw`.")
    :ok
  end

  def main(args) do
    case ReplArgs.parse(args) do
      {:ok, parsed} ->
        Application.put_env(:jido_claw, :project_dir, parsed.project_dir)
        Application.ensure_all_started(:jido_claw)

        Repl.start(parsed.project_dir, resume: parsed.resume, continue: parsed.continue)

      {:usage, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, "usage: jido [dir] [--resume <uuid> | --continue]")
        System.halt(2)
    end
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
