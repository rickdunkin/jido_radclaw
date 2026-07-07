defmodule JidoClaw.Forge.Runners.ClaudeCode do
  @moduledoc """
  Forge runner for the Claude Code CLI (`claude -p`).

  ## Executor knobs (PR-2 — defaults preserve the consolidator byte-for-byte)

    * `config_sync: :full (default) | :auth_only` — `:full` syncs the host
      `~/.claude` whitelist into `forge_home/.claude` and pins an allow-all
      `settings.json` (today's consolidator posture, unchanged). `:auth_only`
      builds an ISOLATED per-run config dir instead: `credentials.json` alone
      is synced (exec-based base64 write — the transport that actually lands
      on HostShell), a minimal non-allow-all `settings.json` is written the
      same way, and `CLAUDE_CONFIG_DIR` is injected so claude's whole config
      universe is the per-run dir — host settings/skills/CLAUDE.md/plugins
      cannot bleed in (review finding P1b: HostShell inherits the allowlisted
      `HOME`, so without the env override claude reads the operator's REAL
      `~/.claude`; the `forge_home/.claude` file writes alone are decorative
      there). A failed env inject fails the init CLOSED — an unisolated
      session must not start.
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
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  # Files/dirs from ~/.claude worth syncing into the sandbox.
  # Excludes logs, telemetry, and other ephemeral data.
  @syncable_entries ~w(settings.json credentials.json skills CLAUDE.md)
  @auth_file "credentials.json"

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

    case sync_host_claude_config(client, forge_home, config_sync) do
      :ok ->
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
           add_dirs: Map.get(config, :add_dirs, [])
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @impl Runner
  def run_iteration(client, state, opts) do
    prompt = Keyword.get(opts, :prompt, state.prompt)
    redacted_prompt = PromptRedaction.redact(prompt)
    model = state.model
    max_turns = Map.get(state, :max_turns) || 200

    args =
      (["-p", redacted_prompt, "--model", model] ++
         permission_args(state) ++
         ["--output-format", "stream-json", "--max-turns", Integer.to_string(max_turns)])
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

  defp permission_args(_state), do: ["--dangerously-skip-permissions"]

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
  # host `~/.claude`, so a failed inject fails the init closed.
  defp sync_host_claude_config(client, forge_home, :auth_only) do
    host_claude = host_claude_dir()
    auth_path = Path.join(host_claude, @auth_file)
    config_dir = "#{forge_home}/.claude"

    cond do
      not File.dir?(host_claude) ->
        {:error, :no_credentials}

      not File.regular?(auth_path) ->
        {:error, :no_credentials}

      true ->
        for dir <- ["#{forge_home}/session", "#{forge_home}/templates", config_dir] do
          Sandbox.exec(client, "mkdir -p #{dir}", [])
        end

        FileSync.sync_file(
          client,
          auth_path,
          "#{config_dir}/#{@auth_file}",
          @auth_file,
          "ClaudeCode"
        )

        FileSync.write_content(client, "#{config_dir}/settings.json", "{}")

        case Sandbox.inject_env(client, %{"CLAUDE_CONFIG_DIR" => config_dir}) do
          :ok -> :ok
          {:error, reason} -> {:error, {:config_isolation_failed, reason}}
        end
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
