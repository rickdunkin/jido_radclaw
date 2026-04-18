defmodule JidoClaw.CLI.Branding do
  @moduledoc """
  ASCII art, boot sequence, spinners, and visual identity for JidoClaw.
  """

  # -- Main Logo --

  def logo(:full) do
    """
    \e[36m
         ██╗██╗██████╗  ██████╗  ██████╗██╗      █████╗ ██╗    ██╗
         ██║██║██╔══██╗██╔═══██╗██╔════╝██║     ██╔══██╗██║    ██║
         ██║██║██║  ██║██║   ██║██║     ██║     ███████║██║ █╗ ██║
    ██   ██║██║██║  ██║██║   ██║██║     ██║     ██╔══██║██║███╗██║
    ╚█████╔╝██║██████╔╝╚██████╔╝╚██████╗███████╗██║  ██║╚███╔███╔╝
     ╚════╝ ╚═╝╚═════╝  ╚═════╝  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
    \e[0m\e[2m        自 動  ·  autonomous\e[0m
    """
  end

  def logo(:compact) do
    """
    \e[36m ╭─── JIDOCLAW ───╮\e[0m
    \e[36m │\e[0m  自動 · claw     \e[36m│\e[0m
    \e[36m ╰────────────────╯\e[0m
    """
  end

  def logo(:minimal), do: "\e[36m⚡ JIDOCLAW\e[0m"

  def logo do
    cols = terminal_cols()

    cond do
      cols >= 70 -> logo(:full)
      cols >= 30 -> logo(:compact)
      true -> logo(:minimal)
    end
  end

  # -- Boot Sequence --

  def boot_sequence(project_dir, opts \\ []) do
    provider = opts[:provider] || "ollama"
    model = opts[:model] || "nemotron-3-super:cloud"
    strategy = opts[:strategy] || "react"
    project_type = detect_type(project_dir)
    tools_count = opts[:tools_count] || 30
    gateway = opts[:gateway] || false

    # Count skills and agents from .jido/
    skills_count = count_yaml_files(Path.join([project_dir, ".jido", "skills"]))
    agents_count = count_yaml_files(Path.join([project_dir, ".jido", "agents"]))

    IO.write("\e[2J\e[H")
    IO.puts(logo())

    animate_line(
      "  \e[2mv#{JidoClaw.version()} · elixir #{System.version()} · otp #{:erlang.system_info(:otp_release)}\e[0m"
    )

    :timer.sleep(80)

    IO.puts("")
    animate_line("  \e[33m⚙\e[0m  workspace   \e[1m#{Path.basename(project_dir)}\e[0m")
    animate_line("  \e[33m⚙\e[0m  project     \e[1m#{project_type}\e[0m")
    animate_line("  \e[33m⚙\e[0m  provider    \e[1m#{provider}\e[0m")
    animate_line("  \e[33m⚙\e[0m  model       \e[1m#{model}\e[0m")
    animate_line("  \e[33m⚙\e[0m  strategy    \e[1m#{strategy}\e[0m")
    animate_line("  \e[33m⚙\e[0m  tools       \e[1m#{tools_count} loaded\e[0m")
    animate_line("  \e[33m⚙\e[0m  templates   \e[1m6 agent types\e[0m")

    if skills_count > 0 do
      animate_line("  \e[32m✓\e[0m  skills      \e[1m#{skills_count} loaded\e[0m")
    end

    if agents_count > 0 do
      animate_line("  \e[32m✓\e[0m  agents      \e[1m#{agents_count} custom\e[0m")
    end

    if gateway do
      animate_line("  \e[33m⚙\e[0m  gateway     \e[1mhttp://localhost:#{gateway_port()}\e[0m")
    end

    jido_md = Path.join([project_dir, ".jido", "JIDO.md"])

    if File.exists?(jido_md) do
      animate_line("  \e[32m✓\e[0m  JIDO.md     \e[2mloaded\e[0m")
    else
      animate_line("  \e[33m↻\e[0m  JIDO.md     \e[2mgenerating...\e[0m")
    end

    # Show memory size if exists
    memory_path = Path.join([project_dir, ".jido", "memory.json"])

    if File.exists?(memory_path) do
      case File.stat(memory_path) do
        {:ok, %{size: size}} when size > 0 ->
          animate_line("  \e[32m✓\e[0m  memory      \e[2m#{format_bytes(size)}\e[0m")

        _ ->
          :ok
      end
    end

    IO.puts("")
    IO.puts(divider())
    IO.puts("")
    IO.puts("  \e[2mType a message to start. /help for commands. Ctrl+C to quit.\e[0m")
    IO.puts("")
  end

  # -- Thinking Spinner --

  @spinner_frames [
    "  \e[36m(◕‿◕)\e[0m \e[2mthinking...\e[0m",
    "  \e[36m(◕ᴗ◕)\e[0m \e[2mthinking...\e[0m",
    "  \e[36m(◔‿◔)\e[0m \e[2mthinking...\e[0m",
    "  \e[36m(◕‿◕✿)\e[0m \e[2mthinking...\e[0m",
    "  \e[36m(◕‿◕)ノ\e[0m \e[2mthinking...\e[0m",
    "  \e[36m(◕ᴗ◕)ノ♡\e[0m \e[2mthinking...\e[0m"
  ]

  @tool_spinner_frames ["⟳", "⟲", "◐", "◓", "◑", "◒"]

  def spinner_frame(tick) do
    Enum.at(@spinner_frames, rem(tick, length(@spinner_frames)))
  end

  def tool_spinner_frame(tick, tool_name) do
    frame = Enum.at(@tool_spinner_frames, rem(tick, length(@tool_spinner_frames)))
    "  \e[33m#{frame}\e[0m \e[2m#{tool_name}...\e[0m"
  end

  # -- Help Screen --

  def help_text do
    """
    \e[36m╭─── JIDOCLAW ─── Commands ─────────────────────────╮\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mSession\e[0m                                         \e[36m│\e[0m
    \e[36m│\e[0m    /quit            Exit                            \e[36m│\e[0m
    \e[36m│\e[0m    /clear           Clear screen                    \e[36m│\e[0m
    \e[36m│\e[0m    /help            Show this help                  \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mConfig\e[0m                                          \e[36m│\e[0m
    \e[36m│\e[0m    /setup           Run setup wizard                \e[36m│\e[0m
    \e[36m│\e[0m    /model <m>       Switch model                    \e[36m│\e[0m
    \e[36m│\e[0m    /models [prov]   List available models           \e[36m│\e[0m
    \e[36m│\e[0m    /status          Show current config             \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mStrategy\e[0m                                        \e[36m│\e[0m
    \e[36m│\e[0m    /strategies      List reasoning strategies        \e[36m│\e[0m
    \e[36m│\e[0m    /strategy        Show active strategy             \e[36m│\e[0m
    \e[36m│\e[0m    /strategy <n>    Switch reasoning strategy        \e[36m│\e[0m
    \e[36m│\e[0m    /classify <p>    Profile a prompt, suggest strat   \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mPrompt\e[0m                                          \e[36m│\e[0m
    \e[36m│\e[0m    /upgrade-prompt  Apply pending prompt upgrade     \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mSwarm\e[0m                                           \e[36m│\e[0m
    \e[36m│\e[0m    /agents          Show running agents             \e[36m│\e[0m
    \e[36m│\e[0m    /skills          List available skills           \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mMemory\e[0m                                          \e[36m│\e[0m
    \e[36m│\e[0m    /memory          List all memories               \e[36m│\e[0m
    \e[36m│\e[0m    /memory search   Search memories                 \e[36m│\e[0m
    \e[36m│\e[0m    /memory save     Save a memory                   \e[36m│\e[0m
    \e[36m│\e[0m    /memory forget   Delete a memory                 \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mSolutions\e[0m                                       \e[36m│\e[0m
    \e[36m│\e[0m    /solutions       List solution store stats        \e[36m│\e[0m
    \e[36m│\e[0m    /solutions search Search stored solutions         \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mNetwork\e[0m                                         \e[36m│\e[0m
    \e[36m│\e[0m    /network         Show network status             \e[36m│\e[0m
    \e[36m│\e[0m    /network connect Connect to agent network        \e[36m│\e[0m
    \e[36m│\e[0m    /network disconnect Disconnect from network      \e[36m│\e[0m
    \e[36m│\e[0m    /network peers   List connected peers            \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mScheduling\e[0m                                      \e[36m│\e[0m
    \e[36m│\e[0m    /cron            List cron jobs                  \e[36m│\e[0m
    \e[36m│\e[0m    /cron add        Schedule a recurring task       \e[36m│\e[0m
    \e[36m│\e[0m    /cron remove     Remove a scheduled task         \e[36m│\e[0m
    \e[36m│\e[0m    /cron trigger    Trigger a job immediately       \e[36m│\e[0m
    \e[36m│\e[0m    /cron disable    Disable a scheduled task        \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m│\e[0m  \e[1mPlatform\e[0m                                        \e[36m│\e[0m
    \e[36m│\e[0m    /gateway         Show gateway status             \e[36m│\e[0m
    \e[36m│\e[0m    /tenants         List tenants                    \e[36m│\e[0m
    \e[36m│\e[0m    /channels        List channel adapters           \e[36m│\e[0m
    \e[36m│\e[0m                                                   \e[36m│\e[0m
    \e[36m╰───────────────────────────────────────────────────╯\e[0m
    """
  end

  # -- Goodbye --

  def goodbye(stats \\ %{}) do
    messages = Map.get(stats, :messages, 0)
    tool_calls = Map.get(stats, :tool_calls, 0)
    agents_spawned = Map.get(stats, :agents_spawned, 0)
    elapsed = Map.get(stats, :elapsed, "0s")
    estimated_cost = Map.get(stats, :estimated_cost)

    cost_part =
      case estimated_cost do
        nil -> nil
        cost when cost < 0.001 -> "~$0.00"
        cost -> "~$#{:erlang.float_to_binary(cost, decimals: 4)}"
      end

    tokens = Map.get(stats, :tokens, 0)
    tokens_str = JidoClaw.Display.StatusBar.format_tokens(tokens)

    parts =
      [
        "#{messages} msgs",
        "#{tool_calls} tools",
        "#{agents_spawned} agents",
        "#{tokens_str} tokens",
        elapsed,
        cost_part
      ]
      |> Enum.reject(&is_nil/1)

    summary = Enum.join(parts, " · ")

    """

    \e[36m  ╭────────────────────────────────────────╮
      │  session complete                       │
      │  #{summary}  │
      ╰────────────────────────────────────────╯\e[0m

      \e[2m自動 · until next time.\e[0m

    """
  end

  # -- Divider --

  def divider do
    cols = terminal_cols()
    "\e[2m  " <> String.duplicate("─", min(cols - 4, 60)) <> "\e[0m"
  end

  # -- Tool Result Display --

  def tool_start(tool_name, params) do
    params_str =
      params
      |> Enum.map(fn {k, v} ->
        v_str =
          if is_binary(v) and String.length(v) > 60,
            do: String.slice(v, 0, 57) <> "...",
            else: inspect(v)

        "#{k}=#{v_str}"
      end)
      |> Enum.join(", ")

    IO.puts("  \e[33m⟳\e[0m \e[2m#{tool_name}\e[0m #{params_str}")
  end

  def tool_done(tool_name) do
    IO.puts("  \e[32m✓\e[0m \e[2m#{tool_name}\e[0m")
  end

  # -- Gateway Config --

  def gateway_port do
    Application.get_env(:jido_claw, :gateway_port, 4000)
  end

  # -- Private --

  defp animate_line(text) do
    IO.puts(text)
    :timer.sleep(40)
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, cols} ->
        cols

      _ ->
        case System.cmd("tput", ["cols"], stderr_to_stdout: true) do
          {output, 0} ->
            case Integer.parse(String.trim(output)) do
              {cols, _} -> cols
              :error -> 120
            end

          _ ->
            120
        end
    end
  end

  defp count_yaml_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".yaml"))
      _ -> 0
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"

  defp detect_type(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "elixir"
      File.exists?(Path.join(dir, "package.json")) -> "node"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "rust"
      File.exists?(Path.join(dir, "go.mod")) -> "go"
      File.exists?(Path.join(dir, "pyproject.toml")) -> "python"
      true -> "unknown"
    end
  end
end
