defmodule JidoClaw.Forge.Runners.ClaudeCode do
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Runner, Sandbox}
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  @forge_home "/var/local/forge"

  # Files/dirs from ~/.claude worth syncing into the sandbox.
  # Excludes logs, telemetry, and other ephemeral data.
  @syncable_entries ~w(settings.json credentials.json skills CLAUDE.md)

  @impl true
  def init(client, config) do
    prompt = Map.get(config, :prompt, "")
    model = Map.get(config, :model, "claude-sonnet-4-20250514")
    session_name = Map.get(config, :session_name)

    dirs = ["#{@forge_home}/session", "#{@forge_home}/templates", "#{@forge_home}/.claude"]

    for dir <- dirs do
      Sandbox.exec(client, "mkdir -p #{dir}", [])
    end

    # Sync user-level ~/.claude config into sandbox HOME (not workspace)
    sync_host_claude_config(client)

    # Ensure dangerously-skip-permissions settings are in place
    settings = Jason.encode!(%{permissions: %{allow: ["*"]}})
    Sandbox.write_file(client, "#{@forge_home}/.claude/settings.json", settings)

    if prompt != "" do
      redacted = PromptRedaction.redact(prompt)
      Sandbox.write_file(client, "#{@forge_home}/session/context.md", redacted)
    end

    {:ok, %{model: model, prompt: prompt, iteration: 0, session_name: session_name}}
  end

  @impl true
  def run_iteration(client, state, opts) do
    prompt = Keyword.get(opts, :prompt, state.prompt)
    redacted_prompt = PromptRedaction.redact(prompt)
    model = state.model

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
        "200"
      ]

    run_opts = [timeout: 300_000]
    run_opts = if state.session_name, do: [{:name, state.session_name} | run_opts], else: run_opts

    case Sandbox.run(client, "claude", args, run_opts) do
      {output, 0} -> parse_output(output)
      {output, _code} -> {:ok, Runner.error("claude cli failed", output)}
    end
  end

  @impl true
  def apply_input(client, input, _state) do
    Sandbox.write_file(
      client,
      "#{@forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    last_result =
      lines
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.reduce(nil, fn line, _acc ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result"} = result} -> result
          _ -> nil
        end
      end)

    case last_result do
      %{"subtype" => "success"} -> {:ok, Runner.done(output)}
      %{"subtype" => "error_max_turns"} -> {:ok, Runner.continue(output)}
      _ -> {:ok, Runner.done(output)}
    end
  end

  defp sync_host_claude_config(client) do
    host_claude = Path.expand("~/.claude")

    if File.dir?(host_claude) do
      @syncable_entries
      |> Enum.each(fn entry ->
        source = Path.join(host_claude, entry)
        dest = "#{@forge_home}/.claude/#{entry}"

        cond do
          File.regular?(source) ->
            sync_file(client, source, dest)

          File.dir?(source) ->
            sync_dir(client, source, dest)

          true ->
            :skip
        end
      end)
    end
  end

  defp sync_file(client, source, dest) do
    case File.read(source) do
      {:ok, content} ->
        encoded = Base.encode64(content)
        Sandbox.exec(client, "echo '#{encoded}' | base64 -d > #{dest}", [])

      {:error, reason} ->
        Logger.debug("[ClaudeCode] Skipping #{source}: #{reason}")
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
            File.regular?(source) -> sync_file(client, source, dest)
            File.dir?(source) -> sync_dir(client, source, dest)
            true -> :skip
          end
        end)

      {:error, reason} ->
        Logger.debug("[ClaudeCode] Skipping dir #{source_dir}: #{reason}")
    end
  end
end
