defmodule JidoClaw.CLI.Main do
  @moduledoc """
  Escript entrypoint for the `jido` CLI binary.

  Usage:
    jido                            # start in current directory
    jido /path/to/project           # start in target directory
    jido --resume <uuid> [dir]      # REPL, resuming a session by UUID
    jido --continue [dir]           # REPL, resuming the most recent CLI session
    jido --mcp                      # start as MCP server (stdio transport)
    jido --third-party-licenses     # print bundled third-party license texts
    jido run "<prompt>" [dir] [--session <uuid> | --continue]
             [--timeout <seconds>] [--format text|json]

  `run` exits 0 (success), 1 (error/failed run/timeout), 2 (usage/config
  error), 3 (approval gate or clarify questions pending), 4 (session not
  found), 5 (provider unreachable), or 6 (provider auth failure). Invalid or
  conflicting REPL flags (e.g. `--bogus`, a valueless or empty `--resume`,
  `--resume <uuid> --continue`) also exit 2 instead of silently booting a
  fresh session.

  The escript builds with `app: nil` (mix.exs) so nothing boots before
  `main/1` runs — `--third-party-licenses` is a pre-boot early exit that
  must work from the bare binary (no secrets, no database, no config), and
  `config/runtime.exs` is total/configure-only to keep that true. Every
  booting branch therefore starts the application itself through the CHECKED
  `start_app_or_halt!/0` — a failed start terminates with exit 2 (the
  documented config-error code) and a stderr message, exactly as Mix's
  pre-`main/1` bootstrap used to.
  """

  require Logger

  alias JidoClaw.CLI.Repl
  alias JidoClaw.CLI.ReplArgs
  alias JidoClaw.CLI.RunCommand
  alias JidoClaw.CLI.Setup
  alias JidoClaw.Core.ThirdPartyLicenses

  @spec main([String.t()]) :: :ok | no_return()
  def main(["--third-party-licenses" | _rest]) do
    # Pre-boot early exit: the Apache-2.0 §4(a)/(b) route for escript
    # recipients (the binary bundles no priv/). Runs before any application
    # start — the license must be obtainable from the bare binary.
    # binwrite, not write: the escript's stdout device is latin1-mode, and
    # IO.write would escape any non-latin1 char into \x{...} noise; raw
    # bytes keep the output byte-identical to the embedded texts on every
    # device. Both texts are deliberately pure ASCII — a future non-ASCII
    # edit fails the capture_io byte-equality row loudly (a unicode-mode
    # capture device latin1-reinterprets raw UTF-8 bytes).
    IO.binwrite(:stdio, ThirdPartyLicenses.jido_action_notice())
    IO.binwrite(:stdio, "\n")
    IO.binwrite(:stdio, ThirdPartyLicenses.jido_action_license())
    :ok
  end

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
    # persistent: true on every pre-boot put_env in this module — under the
    # escript's `app: nil` the app is not LOADED yet, and Application.load
    # would otherwise clobber these with the app-spec env defaults.
    Application.put_env(:jido_claw, :project_dir, project_dir, persistent: true)
    Application.put_env(:jido_claw, :first_run_setup_pending, true, persistent: true)
    Application.put_env(:jido_claw, :force_setup, true, persistent: true)
    start_app_or_halt!()
    Setup.run(project_dir)
    IO.puts("Setup complete — restart with the binary or `mix jidoclaw`.")
    :ok
  end

  def main(args) do
    case ReplArgs.parse(args) do
      {:ok, parsed} ->
        Application.put_env(:jido_claw, :project_dir, parsed.project_dir, persistent: true)
        start_app_or_halt!()

        Repl.start(parsed.project_dir, resume: parsed.resume, continue: parsed.continue)

      {:usage, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, "usage: jido [dir] [--resume <uuid> | --continue]")
        System.halt(2)
    end
  end

  @doc """
  Checked application startup for the escript's booting branches: under
  `app: nil` nothing starts before `main/1`, so a discarded
  `ensure_all_started/1` failure would fall through into the branch body
  (worst case: the MCP branch parking on a dead server). A start failure
  prints the reason to stderr and terminates with exit 2 (the documented
  usage/config-error code) — terminal, exactly as Mix's pre-`main/1`
  bootstrap failure was.
  """
  @spec start_app_or_halt!() :: :ok
  def start_app_or_halt! do
    case start_jido_claw() do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "error: JidoClaw failed to start: #{inspect(reason)}")
        halt!(2)
    end
  end

  # The starter/halter injection seams are COMPILED ONLY under
  # MIX_ENV=test (the error boundary's chaos-seam idiom): production builds
  # get direct Application.ensure_all_started/1 + System.halt/1 calls,
  # structurally unable to consult config. The raise after the test halter
  # is the structurally non-returning failure arm — a stale or malformed
  # injected callback must never recreate the fall-through bug this seam
  # exists to test.
  if Mix.env() == :test do
    defp start_jido_claw do
      case Application.get_env(:jido_claw, :cli_app_starter) do
        starter when is_function(starter, 0) -> starter.()
        _not_injected -> Application.ensure_all_started(:jido_claw)
      end
    end

    @spec halt!(pos_integer()) :: no_return()
    defp halt!(code) do
      case Application.get_env(:jido_claw, :cli_halter) do
        halter when is_function(halter, 1) -> halter.(code)
        _not_injected -> System.halt(code)
      end

      raise "CLI halt seam returned (exit code #{code}) — the halter must terminate"
    end
  else
    defp start_jido_claw, do: Application.ensure_all_started(:jido_claw)

    @spec halt!(pos_integer()) :: no_return()
    defp halt!(code), do: System.halt(code)
  end

  defp start_mcp do
    # persistent: true — see main(["--setup" | _]): pre-boot env must
    # survive Application.load under the escript's `app: nil` (a
    # non-persistent :mode here left the Phoenix endpoint starting inside
    # MCP mode; a non-persistent :serve_mode kept the MCP server itself
    # from starting at all).
    Application.put_env(:jido_claw, :serve_mode, :mcp, persistent: true)
    # Skip Phoenix endpoint and Discord in MCP mode — stdio must stay clean.
    Application.put_env(:jido_claw, :mode, :cli, persistent: true)
    Application.put_env(:jido_claw, :skip_discord, true, persistent: true)
    Application.put_env(:jido_claw, :project_dir, File.cwd!(), persistent: true)
    # Redirect BEFORE app start (the `mix jidoclaw --mcp` task does the
    # same): under `app: nil`, ensure_all_started/1 boots dependency
    # applications before JidoClaw.Application.start/2 can install its own
    # redirect, and any dep startup log reaching stdout would corrupt the
    # JSON-RPC stream.
    JidoClaw.Application.redirect_logger_to_stderr()
    start_app_or_halt!()

    case JidoClaw.Startup.ensure_project_state(File.cwd!()) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[JidoClaw] startup: #{inspect(reason)}")
    end

    # Block forever — the MCPServer GenServer owns the stdin loop.
    Process.sleep(:infinity)
  end
end
