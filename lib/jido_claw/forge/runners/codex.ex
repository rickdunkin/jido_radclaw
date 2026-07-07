defmodule JidoClaw.Forge.Runners.Codex do
  @moduledoc """
  Sibling runner to `JidoClaw.Forge.Runners.ClaudeCode` for the
  OpenAI Codex CLI (`codex exec`).

  ## CLI surface differences

  Codex's flag surface differs from Claude Code's:

    * No `--mcp-config FILE`. The host's `$CODEX_HOME/config.toml` is
      synced verbatim into the per-run `$CODEX_HOME` so operator
      provider/profile/proxy settings are preserved. The per-run
      MCP server (name from `runner_config.mcp_server_name`, default
      `"consolidator"`) is injected on the `codex exec` argv as
      an inline-table override — `-c 'mcp_servers.<name> =
      {url="...", default_tools_approval_mode="approve"}'` — which
      replaces the whole server entry rather than merging into one.
      That avoids TOML 1.0's duplicate-table error when the host
      already declares `[mcp_servers.<name>]`, and also avoids Codex's
      reject-mixed-shape check when a host entry uses a stdio-style
      `command = "..."` (a sub-key override would leave that sibling
      in place alongside our `url`). The override stays on the argv,
      so the per-run endpoint never lands on disk; the approve mode is
      load-bearing (see `mcp_override/1`).
    * No `--max-turns`. We rely on `timeout_ms` instead.
    * Auth lives at `$CODEX_HOME/auth.json` (mode 600 on the host).
    * Approvals: codex ≥0.142 defaults `approval_policy` to
      `on-request` (headless `exec` auto-cancels prompts). With the
      default `access: :full` we pass
      `--dangerously-bypass-approvals-and-sandbox` because Forge
      already provides isolation; `access: :read_only` (the
      vendor-executor posture, PR-2) replaces it with `-s read-only` —
      the CLI's own sandbox holds the read floor, verified live to
      leave the loopback MCP connection open.

  ## Per-run isolation

  Both `forge_home` and `codex_home` are read from `runner_config`.
  The consolidator passes per-run paths so concurrent runs do not
  trample each other's `$CODEX_HOME/config.toml` or session files.

  ## Executor knobs (PR-2 — defaults preserve the consolidator byte-for-byte)

    * `config_sync: :full (default) | :auth_only` — `:auth_only` syncs
      `auth.json` alone: the host `config.toml` would carry the operator's
      host MCP servers into a session meant to see only the deposit
      endpoint, past the read-only intent. Under `:auth_only` a failed
      `CODEX_HOME` env inject fails the init CLOSED (the env taking effect
      is the only thing keeping the host `~/.codex` out of the session);
      `:full` stays best-effort.
    * `access: :full (default) | :read_only` — see above.
    * `cwd` — the `-C` working directory (default `forge_home`); the
      executor points it at the run's real `project_dir` for
      `workspace: :repo`.
    * `mcp_server_name` — the injected server's TOML key (default
      `"consolidator"`; the executor passes `"jido_deposit"`).
  """

  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  alias JidoClaw.Forge.Runners.FileSync
  alias JidoClaw.Security.Redaction.PromptRedaction

  # Whitelist trimmed: rules/ is inert under --ignore-rules; AGENTS.md is
  # read from `-C cwd`, not $CODEX_HOME. Auth + config are the only files
  # that actually move the needle.
  @syncable_entries ~w(auth.json config.toml)
  @auth_file "auth.json"

  @impl Runner
  def init(client, config) do
    forge_home = Map.get(config, :forge_home, default_forge_home())
    codex_home = Map.get(config, :codex_home, "#{forge_home}/.codex")
    mcp_url = Map.get(config, :mcp_server_url)
    prompt = Map.get(config, :prompt, "")
    config_sync = Map.get(config, :config_sync, :full)

    with :ok <- sync_host_codex_config(client, codex_home, forge_home, config_sync),
         :ok <- inject_codex_home(client, codex_home, config_sync) do
      if prompt != "" do
        Sandbox.write_file(
          client,
          "#{forge_home}/session/context.md",
          PromptRedaction.redact(prompt)
        )
      end

      {:ok,
       %{
         model: Map.get(config, :model, "gpt-5-codex"),
         prompt: prompt,
         iteration: 0,
         # `max_turns` carried for state symmetry with ClaudeCode; Codex has
         # no flag analogue, so the runner does not pass it to the CLI.
         max_turns: Map.get(config, :max_turns, 60),
         timeout_ms: Map.get(config, :timeout_ms, 600_000),
         codex_home: codex_home,
         forge_home: forge_home,
         mcp_server_url: mcp_url,
         mcp_server_name: Map.get(config, :mcp_server_name, "consolidator"),
         access: Map.get(config, :access, :full),
         cwd: Map.get(config, :cwd, forge_home),
         session_name: Map.get(config, :session_name)
       }}
    end
  end

  # Inject CODEX_HOME so codex finds the per-run config.toml + auth.json.
  # Under :auth_only (the vendor-executor posture) the env taking effect is
  # the ONLY thing keeping the operator's real ~/.codex (host config.toml,
  # host MCP servers) out of the session — a refused inject fails the init
  # CLOSED. :full preserves the consolidator's existing best-effort behavior:
  # static config content is a host copy, though mutable session/cache state
  # would land in the host dir.
  defp inject_codex_home(client, codex_home, :auth_only) do
    case Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_isolation_failed, reason}}
    end
  end

  defp inject_codex_home(client, codex_home, _full) do
    _ = Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})
    :ok
  end

  @impl Runner
  def run_iteration(client, state, opts) do
    redacted_prompt = PromptRedaction.redact(Keyword.get(opts, :prompt, state.prompt))

    base_args =
      ["-m", state.model] ++
        access_args(state) ++
        [
          "--json",
          "--ephemeral",
          "--skip-git-repo-check",
          "--ignore-rules",
          "-C",
          state.cwd,
          redacted_prompt
        ]

    # Inject the per-run MCP server via Codex's `-c dotted.key=value`
    # override so we never write the table to disk. The value is a TOML
    # inline table — `mcp_servers.<name> = {url="<url>"}` replaces the
    # whole server entry, not just a sub-key. This is important when a
    # host config the operator has synced declares `[mcp_servers.<name>]`
    # with a stdio shape (`command = "..."`); writing only `…url=` would
    # leave the sibling `command` key in place and Codex rejects mixed
    # url/command tables. Inline-table replacement avoids that collision
    # entirely.
    args = ["exec" | mcp_override(state) ++ base_args]

    timeout_ms = Keyword.get(opts, :timeout, state.timeout_ms)
    base_run_opts = [timeout: timeout_ms]

    run_opts =
      if state.session_name,
        do: [{:name, state.session_name} | base_run_opts],
        else: base_run_opts

    case Sandbox.run(client, "codex", args, run_opts) do
      {output, 0} -> parse_output(output)
      {_output, :timeout} -> {:ok, Runner.error("harness_timeout", "")}
      {output, 127} -> {:ok, Runner.error("runner_unavailable", output)}
      {output, _code} -> {:ok, Runner.error("codex cli failed", output)}
    end
  end

  # `default_tools_approval_mode="approve"` is load-bearing (PR-2 live smoke):
  # codex ≥0.142 gates MCP tool calls behind a per-server approval mode whose
  # default PROMPTS — headless `exec` auto-cancels the prompt ("user cancelled
  # MCP tool call") and the call never leaves the client. Auto-approving is
  # correct here by construction: the injected server is the ENGINE'S OWN
  # scoped endpoint (consolidator / deposit lane) — the engine owns both ends
  # of the channel, so there is no operator to prompt.
  defp mcp_override(%{mcp_server_url: url} = state) when is_binary(url) and url != "",
    do: [
      "-c",
      ~s(mcp_servers.#{state.mcp_server_name}=) <>
        ~s({url="#{url}", default_tools_approval_mode="approve"})
    ]

  defp mcp_override(_), do: []

  # `:read_only` is the executor posture (PR-2): the CLI's own sandbox holds
  # the read floor, never the bypass flag.
  defp access_args(%{access: :read_only}), do: ["-s", "read-only"]
  defp access_args(_state), do: ["--dangerously-bypass-approvals-and-sandbox"]

  @impl Runner
  def apply_input(client, input, state) do
    Sandbox.write_file(
      client,
      "#{state.forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  defp sync_host_codex_config(client, codex_home, forge_home, config_sync) do
    host_codex = host_codex_dir()
    auth_path = Path.join(host_codex, @auth_file)

    cond do
      not File.dir?(host_codex) ->
        {:error, :no_credentials}

      not File.regular?(auth_path) ->
        {:error, :no_credentials}

      true ->
        for dir <- ["#{forge_home}/session", "#{forge_home}/templates", codex_home] do
          Sandbox.exec(client, "mkdir -p #{dir}", [])
        end

        Enum.each(syncable_entries(config_sync), fn entry ->
          source = Path.join(host_codex, entry)
          dest = "#{codex_home}/#{entry}"

          if File.regular?(source),
            do: FileSync.sync_file(client, source, dest, @auth_file, "Codex")
        end)

        :ok
    end
  end

  # `:auth_only` (the executor posture): the host config.toml would carry the
  # operator's host MCP servers into a session meant to see only the deposit
  # endpoint — auth alone crosses.
  defp syncable_entries(:auth_only), do: [@auth_file]
  defp syncable_entries(_full), do: @syncable_entries

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    {events, terminal, turns} =
      Enum.reduce(lines, {[], nil, 0}, fn line, {events_acc, terminal_acc, turns_acc} ->
        if String.starts_with?(line, "{") do
          case Jason.decode(line) do
            {:ok, decoded} ->
              handle_event(decoded, events_acc, terminal_acc, turns_acc)

            _ ->
              {events_acc, terminal_acc, turns_acc}
          end
        else
          {events_acc, terminal_acc, turns_acc}
        end
      end)

    metadata = %{tool_events: Enum.reverse(events), turns: turns}

    case terminal do
      {:done, usage} ->
        base = Runner.done(output)
        meta = if usage, do: Map.put(metadata, :usage, usage), else: metadata
        {:ok, %{base | metadata: Map.merge(base.metadata, meta)}}

      {:error, message} ->
        base = Runner.error(message, output)
        {:ok, %{base | metadata: Map.merge(base.metadata, metadata)}}

      nil ->
        # Stream ended without a terminal turn.completed/turn.failed/error
        # line (e.g., interrupted before a turn finished but exit-0). Treat
        # as completed — same posture as ClaudeCode's missing-result branch.
        base = Runner.done(output)
        {:ok, %{base | metadata: Map.merge(base.metadata, metadata)}}
    end
  end

  # ---- Codex JSONL → ClaudeCode-shape mapping ----

  # thread.started / turn.started → drop (system noise)
  defp handle_event(%{"type" => "thread.started"}, events, terminal, turns),
    do: {events, terminal, turns}

  defp handle_event(%{"type" => "turn.started"}, events, terminal, turns),
    do: {events, terminal, turns}

  # turn.completed → terminal :done; usage stashed into metadata.usage; turns += 1
  defp handle_event(%{"type" => "turn.completed"} = ev, events, _terminal, turns) do
    {events, {:done, Map.get(ev, "usage")}, turns + 1}
  end

  # turn.failed → terminal :error with error.message
  defp handle_event(%{"type" => "turn.failed"} = ev, events, _terminal, turns) do
    msg = get_in(ev, ["error", "message"]) || "turn_failed"
    {events, {:error, msg}, turns}
  end

  # top-level error → terminal :error
  defp handle_event(%{"type" => "error"} = ev, events, _terminal, turns) do
    msg = Map.get(ev, "message") || "error"
    {events, {:error, msg}, turns}
  end

  # item.started — currently only mcp_tool_call carries forward.
  defp handle_event(
         %{"type" => "item.started", "item" => %{"type" => "mcp_tool_call"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{
      "type" => "tool_use",
      "name" => Map.get(item, "tool"),
      "server" => Map.get(item, "server"),
      "input" => Map.get(item, "arguments"),
      "id" => Map.get(item, "id")
    }

    {[decoded | events], terminal, turns}
  end

  defp handle_event(%{"type" => "item.started"}, events, terminal, turns),
    do: {events, terminal, turns}

  # item.completed — mcp_tool_call → tool_result; agent_message → assistant;
  # reasoning → reasoning. Other subtypes are dropped.
  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "mcp_tool_call"} = item},
         events,
         terminal,
         turns
       ) do
    content = get_in(item, ["result", "content"]) || get_in(item, ["error", "message"])
    is_error = Map.get(item, "status") == "failed"

    decoded = %{
      "type" => "tool_result",
      "tool_use_id" => Map.get(item, "id"),
      "content" => content,
      "is_error" => is_error
    }

    {[decoded | events], terminal, turns}
  end

  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "agent_message"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{"type" => "assistant", "text" => Map.get(item, "text")}
    {[decoded | events], terminal, turns}
  end

  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "reasoning"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{"type" => "reasoning", "text" => Map.get(item, "text")}
    {[decoded | events], terminal, turns}
  end

  defp handle_event(%{"type" => "item.completed"}, events, terminal, turns),
    do: {events, terminal, turns}

  defp handle_event(%{"type" => "item.updated"}, events, terminal, turns),
    do: {events, terminal, turns}

  defp handle_event(_, events, terminal, turns), do: {events, terminal, turns}

  defp default_forge_home,
    do: Application.get_env(:jido_claw, :forge_home, "/var/local/forge")

  defp host_codex_dir,
    do: Path.expand(Application.get_env(:jido_claw, :codex_home_dir, "~/.codex"))
end
