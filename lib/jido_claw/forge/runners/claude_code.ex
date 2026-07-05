defmodule JidoClaw.Forge.Runners.ClaudeCode do
  @moduledoc false
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  alias JidoClaw.Forge.Runners.FileSync
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  # Files/dirs from ~/.claude worth syncing into the sandbox.
  # Excludes logs, telemetry, and other ephemeral data.
  @syncable_entries ~w(settings.json credentials.json skills CLAUDE.md)
  @auth_file "credentials.json"

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

    case sync_host_claude_config(client, forge_home) do
      :ok ->
        # Ensure dangerously-skip-permissions settings are in place after the
        # sync (the sync would have overwritten any existing settings.json).
        settings = Jason.encode!(%{permissions: %{allow: ["*"]}})
        Sandbox.write_file(client, "#{forge_home}/.claude/settings.json", settings)

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
           forge_home: forge_home
         }}

      {:error, :no_credentials} = err ->
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
      [
        "-p",
        redacted_prompt,
        "--model",
        model,
        "--dangerously-skip-permissions",
        "--output-format",
        "stream-json",
        "--max-turns",
        Integer.to_string(max_turns)
      ]
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

  defp sync_host_claude_config(client, forge_home) do
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
