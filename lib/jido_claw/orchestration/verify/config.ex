defmodule JidoClaw.Orchestration.Verify.Config do
  @moduledoc """
  Resolution of the deterministic verify command (next-ten item 5, OQ-4 — this
  moduledoc is the design note of record).

  ## Resolution chain (first hit wins)

    1. **Per-run override** (`resolve/2`'s second argument, persisted in the
       composer parent config so a restart keeps it): a scalar/argv command, a
       `%{"cmd" => …, "env" => …, "timeout_ms" => …}` map, or a
       `%{"checks" => [names]}` selection over the config registry — an
       override naming an **unknown check is a loud refusal** (orca OR2-2's
       silent-skip inverted).
    2. **`.jido/config.yaml`** — `verify_cmd:` (scalar or argv list) or a
       `verify:` block (`cmd`/`env`/`timeout_ms`, or the registry-lite
       `checks:` list of named checks, orca OR2-2 fold-in). Both present is a
       loud error, never a silent pick. A non-map `verify:` value is a loud
       `{:invalid_verify_config, …}` too — never a silent fall-through to
       autodetect (which would certify the wrong command).
    3. **Minimal Elixir auto-detect**: `mix.exs` with a `precommit` alias →
       `["mix", "precommit"]`; `mix.exs` without → `["mix", "test"]`. No other
       ecosystems in v1 — camus's full detector is deliberately not ported.
    4. Nothing → `{:error, :no_verifier}`, which the verify stage surfaces as
       the loud **inconclusive** envelope (camus shape: `pass: false,
       inconclusive: true`, remedy in `log_tail`) — never a pass, never a
       silent skip.

  ## No shell, ever

  The canonical `cmd` is an **argv list** — `JidoClaw.Core.OsCmd` spawns an
  executable + args, never `sh -c` (shell plumbing masks exit codes, the house
  no-masked-gates rule). A scalar string is a convenience parsed by
  whitespace-split ONLY when it contains no shell metacharacters
  (`| & ; < > $ \\ \" ' ( ) { } [ ] * ? ~ #` and backtick) AND no leading
  env-assignment token (`FOO=bar mix test` is shell syntax, not a confusing
  `missing_tool`); either refusal is a loud validation error with the remedy
  ("use an argv list / the `env:` map / a script"). Checks accept an optional
  `env:` map (string ⇒ string, overlaid onto the scrubbed child env — the MCP
  stdio endpoint `env:` precedent).

  ## Scope pins

  No tenant-level defaults in v1, and code-path routes only — the verify stage
  runs against a `project_dir`, so `talk`/`sketch` surfaces never resolve a
  verifier. Known residual (camus C2-7, deliberately parked): `verify_cmd` is
  operator-owned config, so a fix loop editing `.jido/config.yaml` mid-run
  changes later resolutions — the freeze is future work.
  """

  # The app-level project config loader (a DIFFERENT module family from this
  # one — the alias disambiguates the two `Config`s).
  alias JidoClaw.Config, as: AppConfig
  # Shared atom-key-wins/string-key-fallback map read — total over YAML
  # string-keyed maps AND in-code atom-keyed overrides.
  alias JidoClaw.Orchestration.Verdict

  @metacharacters ~w(| & ; < > $ ` \\ " ' \( \) { } [ ] * ? ~ #)
  @env_assignment ~r/^[A-Za-z_][A-Za-z0-9_]*=/

  @remedy ~s(use an argv list \(e.g. ["mix", "precommit"]\), the check `env:` map for ) <>
            "variables, or wrap the pipeline in a script and name the script"

  @type check :: JidoClaw.Orchestration.Verify.check()

  @doc """
  Resolve the ordered check list for `project_dir` under the chain above.
  Returns `{:ok, [check]}` or `{:error, reason}` — every error reason is
  remedy-bearing via `format_error/1` and is surfaced by the verify stage as
  an inconclusive envelope, never a wave-execution error.
  """
  @spec resolve(String.t(), term()) :: {:ok, [check()]} | {:error, term()}
  def resolve(project_dir, override \\ nil) do
    case override do
      nil -> resolve_configured(project_dir)
      override -> resolve_override(override, project_dir)
    end
  end

  @doc "Render a resolution error as a bounded, remedy-bearing string."
  @spec format_error(term()) :: String.t()
  def format_error(:no_verifier),
    do:
      "no verifier resolved: no verify_cmd/verify in .jido/config.yaml and no mix.exs — " <>
        "set `verify_cmd:` in .jido/config.yaml"

  def format_error({:shell_syntax, :metacharacters, cmd}),
    do: "verify_cmd #{inspect(cmd)} contains shell metacharacters — #{@remedy}"

  def format_error({:shell_syntax, :env_assignment, cmd}),
    do:
      "verify_cmd #{inspect(cmd)} starts with an env assignment (shell syntax) — " <>
        "move it into the check `env:` map; #{@remedy}"

  def format_error({:unknown_check, name, known}),
    do:
      "verify override names unknown check #{inspect(name)} — configured checks: " <>
        "#{inspect(known)} (refusing loudly rather than silently skipping)"

  def format_error({:invalid_verify_config, detail}),
    do: "invalid verify config: #{detail}"

  def format_error(:ambiguous_verify_config),
    do:
      "both `verify_cmd:` and `verify:` are set in .jido/config.yaml — keep exactly one " <>
        "(the `verify:` block subsumes the scalar)"

  def format_error(other), do: "invalid verify config: #{inspect(other)}"

  # ---------------------------------------------------------------------------
  # Chain step 2/3 — config.yaml then auto-detect
  # ---------------------------------------------------------------------------

  defp resolve_configured(project_dir) do
    config = AppConfig.load(project_dir)

    case {AppConfig.verify_cmd(config), AppConfig.verify(config)} do
      {nil, nil} -> autodetect(project_dir)
      {nil, block} -> checks_from_block(block)
      {scalar, nil} -> checks_from_cmd(scalar, "verify")
      {_scalar, _block} -> {:error, :ambiguous_verify_config}
    end
  end

  defp checks_from_block(%{} = block) do
    case {Verdict.field(block, :checks), Verdict.field(block, :cmd)} do
      {checks, _cmd} when is_list(checks) -> decode_named_checks(checks)
      {nil, cmd} when not is_nil(cmd) -> single_check(block, cmd, "verify")
      _other -> {:error, {:invalid_verify_config, "verify: block needs `cmd` or `checks:`"}}
    end
  end

  # A non-map `verify:` (scalar/list) refuses loudly — collapsing it to nil
  # would silently autodetect and certify the WRONG command.
  defp checks_from_block(other) do
    {:error,
     {:invalid_verify_config,
      "verify: must be a map (cmd/env/timeout_ms or checks:) — a bare command belongs " <>
        "under verify_cmd:, got: #{inspect(other)}"}}
  end

  defp decode_named_checks(raw_checks) do
    decoded =
      Enum.reduce_while(raw_checks, {:ok, []}, fn raw, {:ok, acc} ->
        case decode_named_check(raw) do
          {:ok, check} -> {:cont, {:ok, [check | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case decoded do
      {:ok, checks} -> ensure_unique_names(Enum.reverse(checks))
      {:error, _reason} = error -> error
    end
  end

  defp decode_named_check(%{} = raw) do
    with name when is_binary(name) and name != "" <- Verdict.field(raw, :name),
         {:ok, [check]} <- single_check(raw, Verdict.field(raw, :cmd), name) do
      {:ok, check}
    else
      {:error, _reason} = error -> error
      _bad_name -> {:error, {:invalid_verify_config, "each check needs a non-empty `name`"}}
    end
  end

  defp decode_named_check(_other),
    do: {:error, {:invalid_verify_config, "each verify check must be a map"}}

  defp ensure_unique_names(checks) do
    names = Enum.map(checks, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> {:ok, checks}
      dupes -> {:error, {:invalid_verify_config, "duplicate check names: #{inspect(dupes)}"}}
    end
  end

  # One check from a `cmd` + optional `env`/`timeout_ms` carrier map.
  defp single_check(carrier, cmd, name) do
    with {:ok, argv} <- parse_cmd(cmd),
         {:ok, env} <- validate_env(Verdict.field(carrier, :env)),
         {:ok, timeout_ms} <- validate_timeout(Verdict.field(carrier, :timeout_ms)) do
      {:ok, [check(name, argv, env, timeout_ms)]}
    end
  end

  # The ONE construction site for the check map shape.
  defp check(name, argv, env \\ %{}, timeout_ms \\ nil) do
    %{name: name, cmd: argv, env: env, timeout_ms: timeout_ms}
  end

  # Minimal Elixir auto-detect: `mix.exs` with a `precommit` alias runs the
  # full gate; without it, the suite. Argv lists directly — never a scalar.
  defp autodetect(project_dir) do
    mix_exs = Path.join(project_dir, "mix.exs")

    if File.exists?(mix_exs) do
      if read_file(mix_exs) =~ ~r/\bprecommit:/ do
        {:ok, [check("mix:precommit", ["mix", "precommit"])]}
      else
        {:ok, [check("mix:test", ["mix", "test"])]}
      end
    else
      {:error, :no_verifier}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _error -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Chain step 1 — the per-run override
  # ---------------------------------------------------------------------------

  defp resolve_override(override, _project_dir) when is_binary(override),
    do: checks_from_cmd(override, "override")

  defp resolve_override(override, _project_dir)
       when is_list(override) do
    checks_from_cmd(override, "override")
  end

  defp resolve_override(%{} = override, project_dir) do
    case {Verdict.field(override, :checks), Verdict.field(override, :cmd)} do
      {names, nil} when is_list(names) -> select_named(names, project_dir)
      {nil, cmd} when not is_nil(cmd) -> single_check(override, cmd, "override")
      _other -> {:error, {:invalid_verify_config, "override needs `cmd` or `checks:` names"}}
    end
  end

  defp resolve_override(other, _project_dir),
    do: {:error, {:invalid_verify_config, "unsupported override shape: #{inspect(other)}"}}

  # A `%{"checks" => [names]}` override selects from the CONFIGURED registry —
  # an unknown name refuses loudly (the orca silent-skip inverted). Order
  # follows the override's naming.
  defp select_named(names, project_dir) do
    with :ok <- all_binaries(names),
         {:ok, configured} <- resolve_configured(project_dir) do
      known = Enum.map(configured, & &1.name)

      selected =
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case Enum.find(configured, &(&1.name == name)) do
            nil -> {:halt, {:error, {:unknown_check, name, known}}}
            check -> {:cont, {:ok, [check | acc]}}
          end
        end)

      case selected do
        {:ok, checks} -> {:ok, Enum.reverse(checks)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp all_binaries(names) do
    if Enum.all?(names, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_verify_config, "override `checks:` must be a list of check names"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Command / env / timeout validation
  # ---------------------------------------------------------------------------

  defp checks_from_cmd(cmd, name) do
    with {:ok, argv} <- parse_cmd(cmd) do
      {:ok, [check(name, argv)]}
    end
  end

  # The canonical argv-list form: non-empty, all binaries, verbatim.
  defp parse_cmd([_ | _] = argv) do
    if Enum.all?(argv, &is_binary/1) do
      {:ok, argv}
    else
      {:error, {:invalid_verify_config, "argv entries must all be strings"}}
    end
  end

  # The scalar convenience: whitespace-split ONLY when shell-free.
  defp parse_cmd(cmd) when is_binary(cmd) do
    trimmed = String.trim(cmd)

    cond do
      trimmed == "" ->
        {:error, {:invalid_verify_config, "verify_cmd is empty"}}

      Regex.match?(@env_assignment, trimmed) ->
        {:error, {:shell_syntax, :env_assignment, cmd}}

      String.contains?(trimmed, @metacharacters) ->
        {:error, {:shell_syntax, :metacharacters, cmd}}

      true ->
        {:ok, String.split(trimmed)}
    end
  end

  defp parse_cmd(other),
    do:
      {:error,
       {:invalid_verify_config, "cmd must be a string or argv list, got #{inspect(other)}"}}

  defp validate_env(nil), do: {:ok, %{}}

  defp validate_env(%{} = env) do
    if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, env}
    else
      {:error, {:invalid_verify_config, "check `env:` must map strings to strings"}}
    end
  end

  defp validate_env(_other),
    do: {:error, {:invalid_verify_config, "check `env:` must be a map"}}

  defp validate_timeout(nil), do: {:ok, nil}
  defp validate_timeout(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}

  defp validate_timeout(other),
    do:
      {:error,
       {:invalid_verify_config, "timeout_ms must be a positive integer, got #{inspect(other)}"}}

  # Map reads go through Verdict.field/2 (atom key wins, string key falls
  # back — total over YAML string-keyed maps AND in-code atom-keyed overrides).
end
