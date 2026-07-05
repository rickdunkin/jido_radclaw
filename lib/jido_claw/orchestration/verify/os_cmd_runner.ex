defmodule JidoClaw.Orchestration.Verify.OsCmdRunner do
  @moduledoc """
  The real check runner over `JidoClaw.Core.OsCmd.run/3` — the engine spawns
  the executable + argv directly (never a shell: shell plumbing masks exit
  codes, the house no-masked-gates rule) and reads the exit code itself.

  ## argv0 resolution (execvp-style, pre-spawn)

  `Core.OsCmd` is `Port.open({:spawn_executable, _}, ...)` — a missing
  executable RAISES `:enoent`, it never returns 127. So argv0 is resolved
  BEFORE spawning:

    * a **path-bearing** argv0 (contains `/`, e.g. `./scripts/verify.sh` — the
      very "wrap it in a script" remedy the config validation points to) is
      expanded against the check's cwd and must exist + be executable
      (`System.find_executable/1` on an absolute path checks that file);
    * a **bare** argv0 is probed against the EFFECTIVE child PATH — the
      check's `env:` override wins over the parent's PATH
      (`System.find_executable/1` consults only the parent PATH, so an `env:`
      PATH override exposing a verifier binary would otherwise misresolve).

  Either miss → `{127, "command not found: …"}` without spawning; a raced
  `:enoent` raise from the Port is rescued to the same shape. The 127
  classification row remains live for commands that themselves exit 127 (a
  script whose interior tool is missing).

  ## Result mapping

    * `{out, :timeout}` → the 124 sentinel + the config-lever hint
      (`:verify` `timeout_ms`) — the `host_shell.ex` idiom;
    * `{out, :output_limit}` → the `:output_limit` sentinel + its lever hint;
    * `{out, exit}` → the exit verbatim.

  Output is redacted on the FULL capture (ANSI-strip → pattern redaction —
  an escape-split secret reassembles before matching), THEN tailed
  (redact-before-truncate; truncating first leaks secrets).
  """

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Security.Redaction.Ansi
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Security.Redaction.Patterns

  @default_timeout_ms 900_000
  @default_max_output_bytes 10_000_000
  @default_tail_lines 40

  @doc """
  Run one check in `repo`, returning `{exit :: integer() | :output_limit,
  log_tail :: binary()}`. The check map carries `:cmd` (argv list), optional
  `:env` (string⇒string overrides onto the scrubbed base), and optional
  `:timeout_ms` (else the `:verify` config default).
  """
  @spec run(map(), String.t()) :: {integer() | :output_limit, binary()}
  def run(check, repo) do
    [argv0 | args] = check.cmd
    env_overrides = Map.get(check, :env) || %{}
    timeout = Map.get(check, :timeout_ms) || config(:timeout_ms, @default_timeout_ms)

    case resolve_argv0(argv0, repo, env_overrides) do
      {:ok, executable} ->
        execute(executable, argv0, args, repo, env_overrides, timeout)

      :not_found ->
        {127, "command not found: #{argv0}"}
    end
  end

  defp execute(executable, argv0, args, repo, env_overrides, timeout) do
    {output, status} =
      OsCmd.run(executable, args,
        cd: repo,
        timeout: timeout,
        env: Env.scrubbed_cmd_env(env_overrides),
        max_output_bytes: config(:max_output_bytes, @default_max_output_bytes)
      )

    map_status(status, output, timeout)
  rescue
    # The Port raced our pre-spawn resolution (file deleted between probe and
    # spawn) — same env-lane classification, never a crash.
    error in [ErlangError] ->
      case error do
        %ErlangError{original: :enoent} -> {127, "command not found: #{argv0}"}
        other -> reraise other, __STACKTRACE__
      end
  end

  defp map_status(:timeout, output, timeout) do
    hint =
      "[jidoclaw] verify check timed out after #{timeout}ms — raise `timeout_ms` " <>
        "(config :jido_claw, :verify) or the check's own `timeout_ms:` for cold builds"

    {124, redact_then_tail(output, hint)}
  end

  defp map_status(:output_limit, output, _timeout) do
    hint =
      "[jidoclaw] verify check exceeded the output cap — raise `max_output_bytes` " <>
        "(config :jido_claw, :verify) if this check legitimately prints more"

    {:output_limit, redact_then_tail(output, hint)}
  end

  defp map_status(exit, output, _timeout) when is_integer(exit) do
    {exit, redact_then_tail(output, nil)}
  end

  # Redact the FULL output first (ANSI-strip so escape-split secrets
  # reassemble, then pattern redaction), THEN tail — redact-before-truncate.
  # The trailing newline is dropped (camus `_tail` splitlines semantics).
  defp redact_then_tail(output, hint) do
    output
    |> Ansi.strip()
    |> Patterns.redact()
    |> String.trim_trailing("\n")
    |> tail_lines(config(:tail_lines, @default_tail_lines))
    |> with_hint(hint)
  end

  defp with_hint(tail, nil), do: tail
  defp with_hint("", hint), do: hint
  defp with_hint(tail, hint), do: tail <> "\n" <> hint

  defp tail_lines("", _n), do: ""

  defp tail_lines(text, n) do
    text
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # argv0 resolution
  # ---------------------------------------------------------------------------

  defp resolve_argv0(argv0, repo, env_overrides) do
    if String.contains?(argv0, "/") do
      resolve_path_bearing(argv0, repo)
    else
      resolve_bare(argv0, env_overrides)
    end
  end

  # A relative/absolute argv0 resolves against the check's cwd — the repo —
  # and must exist + be executable (find_executable on an absolute path checks
  # exactly that file). The Port gets the ABSOLUTE path (its own cwd handling
  # must never re-interpret the relative form).
  defp resolve_path_bearing(argv0, repo) do
    expanded = Path.expand(argv0, repo)

    case System.find_executable(expanded) do
      nil -> :not_found
      path -> {:ok, path}
    end
  end

  # A bare argv0 probes the EFFECTIVE child PATH: the check's env override
  # wins, else the parent PATH (which the scrubbed base env inherits).
  defp resolve_bare(argv0, env_overrides) do
    path_value = Map.get(env_overrides, "PATH") || System.get_env("PATH") || ""

    path_value
    |> String.split(":", trim: true)
    |> Enum.find_value(:not_found, fn dir ->
      candidate = Path.join(dir, argv0)
      if executable_file?(candidate), do: {:ok, candidate}
    end)
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp config(key, default) do
    :jido_claw
    |> Application.get_env(:verify, [])
    |> Keyword.get(key, default)
  end
end
