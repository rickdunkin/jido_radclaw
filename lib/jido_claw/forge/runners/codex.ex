defmodule JidoClaw.Forge.Runners.Codex do
  @moduledoc """
  Sibling runner to `JidoClaw.Forge.Runners.ClaudeCode` for the
  OpenAI Codex CLI (`codex exec`).

  ## CLI surface differences

  Codex's flag surface differs from Claude Code's:

    * No `--mcp-config FILE`. The host's `$CODEX_HOME/config.toml` is
      synced verbatim into the per-run `$CODEX_HOME` so operator
      provider/profile/proxy settings are preserved. The per-run
      consolidator MCP server is injected on the `codex exec` argv as
      an inline-table override — `-c 'mcp_servers.consolidator =
      {url="..."}'` — which replaces the whole server entry rather
      than merging into one. That avoids TOML 1.0's duplicate-table
      error when the host already declares
      `[mcp_servers.consolidator]`, and also avoids Codex's
      reject-mixed-shape check when a host entry uses a stdio-style
      `command = "..."` (a sub-key override would leave that sibling
      in place alongside our `url`). The override stays on the argv,
      so the per-run endpoint never lands on disk.
    * No `--max-turns`. We rely on `timeout_ms` instead.
    * Auth lives at `$CODEX_HOME/auth.json` (mode 600 on the host).
    * `codex exec` headless mode defaults the approval policy to
      `Never`, so `-a` is unnecessary. We pass
      `--dangerously-bypass-approvals-and-sandbox` because Forge
      already provides isolation.

  ## Per-run isolation

  Both `forge_home` and `codex_home` are read from `runner_config`.
  The consolidator passes per-run paths so concurrent runs do not
  trample each other's `$CODEX_HOME/config.toml` or session files.
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
  @consolidator_server_name "consolidator"

  @impl Runner
  def init(client, config) do
    forge_home = Map.get(config, :forge_home, default_forge_home())
    codex_home = Map.get(config, :codex_home, "#{forge_home}/.codex")
    mcp_url = Map.get(config, :mcp_server_url)
    prompt = Map.get(config, :prompt, "")

    case sync_host_codex_config(client, codex_home, forge_home) do
      :ok ->
        if prompt != "" do
          Sandbox.write_file(
            client,
            "#{forge_home}/session/context.md",
            PromptRedaction.redact(prompt)
          )
        end

        # Inject CODEX_HOME so codex finds the per-run config.toml + auth.json
        Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})

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
           session_name: Map.get(config, :session_name)
         }}

      {:error, :no_credentials} = err ->
        err
    end
  end

  @impl Runner
  def run_iteration(client, state, opts) do
    redacted_prompt = PromptRedaction.redact(Keyword.get(opts, :prompt, state.prompt))

    base_args = [
      "-m",
      state.model,
      "--dangerously-bypass-approvals-and-sandbox",
      "--json",
      "--ephemeral",
      "--skip-git-repo-check",
      "--ignore-rules",
      "-C",
      state.forge_home,
      redacted_prompt
    ]

    # Inject the per-run consolidator MCP server via Codex's `-c
    # dotted.key=value` override so we never write the table to disk.
    # The value is a TOML inline table — `mcp_servers.consolidator =
    # {url="<url>"}` replaces the whole `consolidator` server entry,
    # not just a sub-key. This is important when a host config the
    # operator has synced declares `[mcp_servers.consolidator]` with a
    # stdio shape (`command = "..."`); writing only `…url=` would leave
    # the sibling `command` key in place and Codex rejects mixed
    # url/command tables. Inline-table replacement avoids that
    # collision entirely.
    args = ["exec" | consolidator_mcp_override(state) ++ base_args]

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

  defp consolidator_mcp_override(%{mcp_server_url: url}) when is_binary(url) and url != "",
    do: ["-c", ~s(mcp_servers.#{@consolidator_server_name}={url="#{url}"})]

  defp consolidator_mcp_override(_), do: []

  @impl Runner
  def apply_input(client, input, state) do
    Sandbox.write_file(
      client,
      "#{state.forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  defp sync_host_codex_config(client, codex_home, forge_home) do
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

        Enum.each(@syncable_entries, fn entry ->
          source = Path.join(host_codex, entry)
          dest = "#{codex_home}/#{entry}"

          if File.regular?(source),
            do: FileSync.sync_file(client, source, dest, @auth_file, "Codex")
        end)

        :ok
    end
  end

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
