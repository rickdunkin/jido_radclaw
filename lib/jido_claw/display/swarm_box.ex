defmodule JidoClaw.Display.SwarmBox do
  @moduledoc """
  Pure module that computes the swarm display box with per-agent status lines.
  """

  alias JidoClaw.Display.StatusBar

  @doc "Render the full swarm box header with summary stats."
  def render_header(agents_map, width \\ 60) do
    children = agents_map |> Enum.reject(fn {id, _} -> id == "main" end)
    total = length(children)
    running = Enum.count(children, fn {_, a} -> a.status == :running end)
    done = Enum.count(children, fn {_, a} -> a.status == :done end)
    errored = Enum.count(children, fn {_, a} -> a.status == :error end)

    total_tokens = children |> Enum.reduce(0, fn {_, a}, acc -> acc + a.tokens end)
    tokens_str = StatusBar.format_tokens(total_tokens)

    status_parts = []

    status_parts =
      if running > 0, do: status_parts ++ ["\e[33m#{running} running\e[0m"], else: status_parts

    status_parts =
      if done > 0, do: status_parts ++ ["\e[32m#{done} done\e[0m"], else: status_parts

    status_parts =
      if errored > 0, do: status_parts ++ ["\e[31m#{errored} error\e[0m"], else: status_parts

    status_str = Enum.join(status_parts, "  ")

    inner_width = max(width - 4, 40)
    pad_char = "─"

    summary = "  #{total} agents  │  #{status_str}  │  #{tokens_str} tokens"

    [
      "",
      "  \e[36m┌─ SWARM #{String.duplicate(pad_char, max(inner_width - 9, 1))}┐\e[0m",
      "  \e[36m│\e[0m#{summary}  \e[36m│\e[0m",
      "  \e[36m└#{String.duplicate(pad_char, inner_width)}┘\e[0m"
    ]
    |> Enum.join("\n")
  end

  @doc "Render a single agent status line."
  def render_agent_line(agent) do
    icon = status_icon(agent.status)
    template_str = if agent.template, do: " [\e[2m#{agent.template}\e[0m]", else: ""
    status_str = status_label(agent.status)
    tokens_str = StatusBar.format_tokens(agent.tokens)

    tools_list =
      agent.tool_names
      |> MapSet.to_list()
      |> Enum.take(5)
      |> Enum.join(", ")

    tools_str = if tools_list != "", do: " │ #{tools_list}", else: ""

    "  #{icon} \e[1m@#{agent.id}\e[0m#{template_str} #{status_str} │ #{tokens_str} │ #{agent.tool_calls} calls#{tools_str}"
  end

  @doc "Render all agent lines for the swarm."
  def render_agents(agents_map, order) do
    order
    |> Enum.reject(&(&1 == "main"))
    |> Enum.map(fn id ->
      case Map.get(agents_map, id) do
        nil -> nil
        agent -> render_agent_line(agent)
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "Render a final swarm summary after all agents complete."
  def render_summary(agents_map) do
    children = agents_map |> Enum.reject(fn {id, _} -> id == "main" end)
    done = Enum.count(children, fn {_, a} -> a.status == :done end)
    errored = Enum.count(children, fn {_, a} -> a.status == :error end)
    total_tokens = children |> Enum.reduce(0, fn {_, a}, acc -> acc + a.tokens end)
    total_tools = children |> Enum.reduce(0, fn {_, a}, acc -> acc + a.tool_calls end)

    status =
      if errored > 0,
        do: "\e[33m#{done} done, #{errored} failed\e[0m",
        else: "\e[32mall #{done} done\e[0m"

    "\n  \e[36m⚡\e[0m Swarm complete: #{status} · #{StatusBar.format_tokens(total_tokens)} tokens · #{total_tools} tool calls\n"
  end

  # -- Icons --

  defp status_icon(:running), do: "\e[33m●\e[0m"
  defp status_icon(:done), do: "\e[32m✓\e[0m"
  defp status_icon(:error), do: "\e[31m✗\e[0m"
  defp status_icon(_), do: "\e[2m○\e[0m"

  defp status_label(:running), do: "\e[33mrunning\e[0m"
  defp status_label(:done), do: "\e[32mdone\e[0m"
  defp status_label(:error), do: "\e[31merror\e[0m"
  defp status_label(_), do: "\e[2munknown\e[0m"
end
