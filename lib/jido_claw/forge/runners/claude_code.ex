defmodule JidoClaw.Forge.Runners.ClaudeCode do
  @moduledoc """
  Forge runner for the Claude Code CLI (`claude -p`).

  ## Executor knobs (PR-2 — defaults preserve the consolidator byte-for-byte)

    * `config_sync: :full (default) | :auth_only` — `:full` syncs the host
      `~/.claude` whitelist into `forge_home/.claude` and pins an allow-all
      `settings.json` (today's consolidator posture, unchanged). `:auth_only`
      builds an ISOLATED per-run config dir instead: the credential alone
      crosses, resolved through the shared source (host `.credentials.json`
      → legacy `credentials.json` → macOS Keychain via the
      `:claude_keychain_reader` seam) and written to the DOTTED
      `<config_dir>/.credentials.json` — what claude reads under
      `CLAUDE_CONFIG_DIR` — through a CHECKED exec-based base64 write +
      `chmod 600` (`FileSync.write_checked/3`; a failed write fails the init
      CLOSED). A minimal non-allow-all `settings.json` rides the same
      transport (best-effort), and `CLAUDE_CONFIG_DIR` is injected so
      claude's whole config universe is the per-run dir — host
      settings/skills/CLAUDE.md/plugins cannot bleed in (review finding P1b:
      HostShell inherits the allowlisted `HOME`, so without the env override
      claude reads the operator's REAL `~/.claude`; the `forge_home/.claude`
      file writes alone are decorative there). A failed env inject fails the
      init CLOSED — an unisolated session must not start.
    * `access: :full (default) | :read_only` — `:full` keeps
      `--dangerously-skip-permissions`. `:read_only` (the vendor-executor
      posture) replaces it with a restricted `--tools` read set,
      `--allowedTools` (read set + `allowed_mcp_tools`),
      `--permission-mode dontAsk` (auto-deny instead of prompt-hang in
      headless `-p`), and `--strict-mcp-config`.
    * `allowed_mcp_tools` — full `mcp__<server>__<tool>` names appended to
      `--allowedTools` under `:read_only` (the executor passes its deposit
      tool).
    * `add_dirs` — repeated `--add-dir` entries (the executor's
      `workspace: :repo` grant; claude's cwd is the HostShell sandbox dir and
      is not ours to set).
  """
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  alias JidoClaw.Forge.Runners.FileSync
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  # Files/dirs from ~/.claude worth syncing into the sandbox.
  # Excludes logs, telemetry, and other ephemeral data.
  @syncable_entries ~w(settings.json credentials.json skills CLAUDE.md)
  @auth_file "credentials.json"
  # What claude actually READS under CLAUDE_CONFIG_DIR (in-VM Linux and
  # modern macOS write the dotted name; the dotless @auth_file is the legacy
  # host layout the :full sync still mirrors verbatim).
  @dotted_auth_file ".credentials.json"
  @keychain_service "Claude Code-credentials"

  # The built-in read-tool set `access: :read_only` pins (verified against the
  # operator-installed CLI at the PR-2 build-time smoke; PR-3's `.jido/config.yaml`
  # `review: executor:` lane is the first production declarer — operator config,
  # not a committed template).
  @read_only_tools ~w(Read Glob Grep)

  @impl Runner
  def init(client, config) do
    prompt = Map.get(config, :prompt, "")
    model = Map.get(config, :model, "claude-sonnet-4-20250514")
    session_name = Map.get(config, :session_name)
    max_turns = Map.get(config, :max_turns, 200)
    timeout_ms = Map.get(config, :timeout_ms, 300_000)
    mcp_config_path = Map.get(config, :mcp_config_path)
    thinking_effort = Map.get(config, :thinking_effort)
    forge_home = Map.get(config, :forge_home, default_forge_home())
    config_sync = Map.get(config, :config_sync, :full)

    with :ok <- sync_host_claude_config(client, forge_home, config_sync),
         :ok <- write_mcp_config(client, config) do
      if prompt != "" do
        redacted = PromptRedaction.redact(prompt)
        Sandbox.write_file(client, "#{forge_home}/session/context.md", redacted)
      end

      {:ok,
       %{
         model: model,
         prompt: prompt,
         iteration: 0,
         session_name: session_name,
         max_turns: max_turns,
         timeout_ms: timeout_ms,
         mcp_config_path: mcp_config_path,
         thinking_effort: thinking_effort,
         forge_home: forge_home,
         access: Map.get(config, :access, :full),
         allowed_mcp_tools: Map.get(config, :allowed_mcp_tools, []),
         add_dirs: Map.get(config, :add_dirs, []),
         strict_mcp: Map.get(config, :strict_mcp, false)
       }}
    end
  end

  # Docker write build: a docker executor plan carries the deposit client
  # config as CONTENT (`mcp_config_json`) because the host-tmp file the local
  # path writes doesn't exist in-VM — without this in-VM write claude has no
  # deposit server at all. Checked: a session without its deposit config must
  # not start (fail init CLOSED). Absent (local plans, consolidator) ⇒ no-op.
  defp write_mcp_config(client, %{mcp_config_json: json, mcp_config_path: path} = _config)
       when is_binary(json) and is_binary(path) and path != "",
       do: FileSync.write_checked(client, path, json)

  defp write_mcp_config(_client, _config), do: :ok

  @impl Runner
  def run_iteration(client, state, opts) do
    prompt = Keyword.get(opts, :prompt, state.prompt)
    redacted_prompt = PromptRedaction.redact(prompt)
    model = state.model
    max_turns = Map.get(state, :max_turns) || 200

    # `--verbose` is REQUIRED alongside `-p --output-format stream-json` on
    # current claude CLIs (≥ ~2.1.19x refuse without it — write-build smoke;
    # PR-2 shipped against an older CLI that tolerated its absence). The
    # verbose stream adds event types `parse_output/1` already drops.
    args =
      (["-p", redacted_prompt, "--model", model] ++
         permission_args(state) ++
         [
           "--output-format",
           "stream-json",
           "--verbose",
           "--max-turns",
           Integer.to_string(max_turns)
         ])
      |> append_add_dirs(state)
      |> append_mcp_config(state)
      |> append_thinking_effort(state)

    timeout_ms = Keyword.get(opts, :timeout, Map.get(state, :timeout_ms) || 300_000)
    base_run_opts = [timeout: timeout_ms]

    run_opts =
      if state.session_name,
        do: [{:name, state.session_name} | base_run_opts],
        else: base_run_opts

    case Sandbox.run(client, "claude", args, run_opts) do
      {output, 0} -> parse_output(output)
      {output, :timeout} -> {:ok, Runner.error("harness_timeout", output)}
      {output, _code} -> {:ok, Runner.error("claude cli failed", output)}
    end
  end

  # `:read_only` — never `--dangerously-skip-permissions`: the restricted
  # `--tools` set is the hard floor, `--allowedTools` pre-approves that floor
  # plus the caller's MCP tools, `dontAsk` auto-denies anything else instead
  # of prompt-hanging headless, and `--strict-mcp-config` pins the MCP surface
  # to the passed `--mcp-config` file alone.
  defp permission_args(%{access: :read_only} = state) do
    read_set = Enum.join(@read_only_tools, ",")
    allowed = Enum.join(@read_only_tools ++ state.allowed_mcp_tools, ",")

    [
      "--tools",
      read_set,
      "--allowedTools",
      allowed,
      "--permission-mode",
      "dontAsk",
      "--strict-mcp-config"
    ]
  end

  # The write arm (docker write build): the bypass flag is the runners'
  # existing `:full` posture — the microVM + workspace mount mode is the
  # boundary — and `strict_mcp` still pins the MCP surface to the passed
  # `--mcp-config` alone (orthogonal to permissions: a mounted repo's
  # `.mcp.json` must not shadow/expand the deposit surface). Default absent ⇒
  # the consolidator args stay byte-identical.
  defp permission_args(state),
    do: ["--dangerously-skip-permissions"] ++ strict_mcp_args(state)

  defp strict_mcp_args(%{strict_mcp: true}), do: ["--strict-mcp-config"]
  defp strict_mcp_args(_state), do: []

  defp append_add_dirs(args, %{add_dirs: [_ | _] = dirs}),
    do: args ++ Enum.flat_map(dirs, &["--add-dir", &1])

  defp append_add_dirs(args, _), do: args

  defp append_mcp_config(args, %{mcp_config_path: path}) when is_binary(path) and path != "",
    do: args ++ ["--mcp-config", path]

  defp append_mcp_config(args, _), do: args

  defp append_thinking_effort(args, %{thinking_effort: effort})
       when is_binary(effort) and effort != "",
       do: args ++ ["--effort", effort]

  defp append_thinking_effort(args, _), do: args

  @impl Runner
  def apply_input(client, input, state) do
    forge_home = Map.get(state, :forge_home, default_forge_home())

    Sandbox.write_file(
      client,
      "#{forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    {events, last_result, turns} =
      Enum.reduce(lines, {[], nil, 0}, fn line, {events_acc, result_acc, turns_acc} ->
        if String.starts_with?(line, "{") do
          case Jason.decode(line) do
            {:ok, %{"type" => "assistant"} = decoded} ->
              {[decoded | events_acc], result_acc, turns_acc + 1}

            {:ok, %{"type" => type} = decoded}
            when type in ["tool_use", "tool_result", "system"] ->
              {[decoded | events_acc], result_acc, turns_acc}

            {:ok, %{"type" => "result"} = result} ->
              {events_acc, result, turns_acc}

            _ ->
              {events_acc, result_acc, turns_acc}
          end
        else
          {events_acc, result_acc, turns_acc}
        end
      end)

    metadata = %{tool_events: Enum.reverse(events), turns: turns}

    base =
      case last_result do
        %{"subtype" => "error_max_turns"} -> Runner.continue(output)
        _ -> Runner.done(output)
      end

    {:ok, %{base | metadata: Map.merge(base.metadata, metadata)}}
  end

  # `:full` — today's consolidator posture, byte-identical: sync the host
  # whitelist into forge_home/.claude, then pin the allow-all settings.json
  # (the sync would have overwritten any existing one).
  defp sync_host_claude_config(client, forge_home, :full) do
    with :ok <- sync_full_whitelist(client, forge_home) do
      settings = Jason.encode!(%{permissions: %{allow: ["*"]}})
      Sandbox.write_file(client, "#{forge_home}/.claude/settings.json", settings)
      :ok
    end
  end

  # `:auth_only` — the isolated per-run config universe (P1b). Everything
  # lands through exec-based writes (`FileSync`), and `CLAUDE_CONFIG_DIR` is
  # what makes it real on HostShell: without it claude reads the operator's
  # host `~/.claude`, so a failed inject fails the init closed. The
  # credential is resolved through the shared source (dotted file → legacy
  # file → macOS Keychain) and lands at the DOTTED in-sandbox name — what
  # claude reads under CLAUDE_CONFIG_DIR — via a CHECKED write (a session
  # without its credential must not start).
  defp sync_host_claude_config(client, forge_home, :auth_only) do
    config_dir = "#{forge_home}/.claude"

    with {:ok, credentials} <- resolve_host_credentials() do
      for dir <- ["#{forge_home}/session", "#{forge_home}/templates", config_dir] do
        Sandbox.exec(client, "mkdir -p #{dir}", [])
      end

      with :ok <-
             FileSync.write_checked(client, "#{config_dir}/#{@dotted_auth_file}", credentials) do
        FileSync.write_content(client, "#{config_dir}/settings.json", "{}")

        case Sandbox.inject_env(client, %{"CLAUDE_CONFIG_DIR" => config_dir}) do
          :ok -> :ok
          {:error, reason} -> {:error, {:config_isolation_failed, reason}}
        end
      end
    end
  end

  # The shared credential source, content-based (an empty source falls
  # through): the DOTTED host file → the legacy dotless file → (darwin) the
  # macOS Keychain. The blob never lands on host disk — it rides the
  # exec-based transport straight into the sandbox. None ⇒ :no_credentials
  # (the existing clean step error). Accepted residuals: an in-VM token
  # refresh can rotate the refresh token while the host Keychain copy goes
  # stale (same class as the existing Linux file sync), and the first
  # Keychain extraction may pop a one-time macOS approval prompt (attended
  # runs OK; unattended runs need pre-authorization).
  defp resolve_host_credentials do
    host_claude = host_claude_dir()

    read_first_regular([
      Path.join(host_claude, @dotted_auth_file),
      Path.join(host_claude, @auth_file)
    ]) || keychain_credentials() || {:error, :no_credentials}
  end

  defp read_first_regular(paths) do
    Enum.find_value(paths, fn path ->
      with true <- File.regular?(path),
           {:ok, content} when content != "" <- File.read(path) do
        {:ok, content}
      else
        _ -> nil
      end
    end)
  end

  defp keychain_credentials do
    case keychain_reader().() do
      {:ok, content} when is_binary(content) and content != "" -> {:ok, content}
      _miss_or_error -> nil
    end
  end

  # Injectable Keychain seam (the `:sbx_finder` app-env idiom) so tests can
  # arm a deterministic hit/miss without shelling out; the default carries
  # the REAL invocation. Anything but a 0-arity fun falls back to the real
  # reader — bad config must not crash a session init.
  defp keychain_reader do
    case Application.get_env(:jido_claw, :claude_keychain_reader) do
      fun when is_function(fun, 0) -> fun
      _absent_or_invalid -> &read_macos_keychain/0
    end
  end

  # darwin only: claude on macOS stores the OAuth blob as the
  # "Claude Code-credentials" generic password, not a file. Scrubbed env;
  # stderr NOT merged (the stdout IS the credential — never mix, never log).
  defp read_macos_keychain do
    with {:unix, :darwin} <- :os.type(),
         security when is_binary(security) <- System.find_executable("security"),
         {output, 0} <-
           System.cmd(security, ["find-generic-password", "-s", @keychain_service, "-w"],
             env: Env.scrubbed_cmd_env()
           ) do
      {:ok, String.trim(output)}
    else
      _ -> :error
    end
  end

  defp sync_full_whitelist(client, forge_home) do
    host_claude = host_claude_dir()
    auth_path = Path.join(host_claude, @auth_file)

    cond do
      not File.dir?(host_claude) ->
        {:error, :no_credentials}

      not File.regular?(auth_path) ->
        {:error, :no_credentials}

      true ->
        for dir <- ["#{forge_home}/session", "#{forge_home}/templates", "#{forge_home}/.claude"] do
          Sandbox.exec(client, "mkdir -p #{dir}", [])
        end

        Enum.each(@syncable_entries, fn entry ->
          source = Path.join(host_claude, entry)
          dest = "#{forge_home}/.claude/#{entry}"

          cond do
            File.regular?(source) ->
              FileSync.sync_file(client, source, dest, @auth_file, "ClaudeCode")

            File.dir?(source) ->
              sync_dir(client, source, dest)

            true ->
              :skip
          end
        end)

        :ok
    end
  end

  defp sync_dir(client, source_dir, dest_dir) do
    Sandbox.exec(client, "mkdir -p #{dest_dir}", [])

    case File.ls(source_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          source = Path.join(source_dir, entry)
          dest = "#{dest_dir}/#{entry}"

          cond do
            File.regular?(source) ->
              FileSync.sync_file(client, source, dest, @auth_file, "ClaudeCode")

            File.dir?(source) ->
              sync_dir(client, source, dest)

            true ->
              :skip
          end
        end)

      {:error, reason} ->
        Logger.debug("[ClaudeCode] Skipping dir #{source_dir}: #{reason}")
    end
  end

  defp default_forge_home,
    do: Application.get_env(:jido_claw, :forge_home, "/var/local/forge")

  defp host_claude_dir,
    do: Path.expand(Application.get_env(:jido_claw, :claude_home_dir, "~/.claude"))
end
