defmodule JidoClaw.Display.SwarmBox do
  @moduledoc """
  Pure module that computes the swarm display box with per-agent status lines.
  """

  alias JidoClaw.Display.StatusBar

  @doc "Render the full swarm box header with summary stats."
  @spec render_header(JidoClaw.SwarmView.t() | map(), non_neg_integer()) :: String.t()
  def render_header(target, width \\ 60)

  def render_header(%JidoClaw.SwarmView{} = view, width) do
    total = length(view.agents)
    tokens_str = StatusBar.format_tokens(view.total_tokens)

    status_parts =
      []
      |> prepend_if(view.error_count > 0, "\e[31m#{view.error_count} error\e[0m")
      |> prepend_if(view.done_count > 0, "\e[32m#{view.done_count} done\e[0m")
      |> prepend_if(view.running_count > 0, "\e[33m#{view.running_count} running\e[0m")

    render_header_box(total, Enum.join(status_parts, "  "), tokens_str, width)
  end

  def render_header(agents_map, width) do
    children = Enum.reject(agents_map, fn {id, _} -> id == "main" end)
    total = length(children)
    running = Enum.count(children, fn {_, a} -> a.status == :running end)
    done = Enum.count(children, fn {_, a} -> a.status == :done end)
    errored = Enum.count(children, fn {_, a} -> a.status == :error end)

    total_tokens = Enum.reduce(children, 0, fn {_, a}, acc -> acc + a.tokens end)
    tokens_str = StatusBar.format_tokens(total_tokens)

    status_parts =
      []
      |> prepend_if(errored > 0, "\e[31m#{errored} error\e[0m")
      |> prepend_if(done > 0, "\e[32m#{done} done\e[0m")
      |> prepend_if(running > 0, "\e[33m#{running} running\e[0m")

    status_str = Enum.join(status_parts, "  ")

    render_header_box(total, status_str, tokens_str, width)
  end

  @doc "Render a single agent status line."
  @spec render_agent_line(map()) :: String.t()
  def render_agent_line(agent) do
    icon = status_icon(status(agent))
    template_str = if template(agent), do: " [\e[2m#{template(agent)}\e[0m]", else: ""
    status_str = status_label(status(agent))
    tokens_str = StatusBar.format_tokens(tokens(agent))

    tools_list =
      agent
      |> tool_names()
      |> Enum.take(5)
      |> Enum.join(", ")

    tools_str = if tools_list != "", do: " │ #{tools_list}", else: ""

    "  #{icon} \e[1m@#{agent_id(agent)}\e[0m#{template_str} #{status_str} │ #{tokens_str} │ #{tool_calls(agent)} calls#{tools_str}"
  end

  @doc "Render all agent lines for the swarm."
  @spec render_agents(JidoClaw.SwarmView.t()) :: String.t()
  def render_agents(%JidoClaw.SwarmView{} = view) do
    Enum.map_join(view.agents, "\n", &render_agent_line/1)
  end

  @spec render_agents(%{optional(String.t()) => map()}, [String.t()]) :: String.t()
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
  @spec render_summary(JidoClaw.SwarmView.t() | map()) :: String.t()
  def render_summary(%JidoClaw.SwarmView{} = view) do
    status =
      if view.error_count > 0,
        do: "\e[33m#{view.done_count} done, #{view.error_count} failed\e[0m",
        else: "\e[32mall #{view.done_count} done\e[0m"

    "\n  \e[36m⚡\e[0m Swarm complete: #{status} · #{StatusBar.format_tokens(view.total_tokens)} tokens · #{view.total_tool_calls} tool calls\n"
  end

  def render_summary(agents_map) do
    children = Enum.reject(agents_map, fn {id, _} -> id == "main" end)
    done = Enum.count(children, fn {_, a} -> a.status == :done end)
    errored = Enum.count(children, fn {_, a} -> a.status == :error end)
    total_tokens = Enum.reduce(children, 0, fn {_, a}, acc -> acc + a.tokens end)
    total_tools = Enum.reduce(children, 0, fn {_, a}, acc -> acc + a.tool_calls end)

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

  defp render_header_box(total, status_str, tokens_str, width) do
    inner_width = max(width - 4, 40)
    pad_char = "─"

    summary = "  #{total} agents  │  #{status_str}  │  #{tokens_str} tokens"

    Enum.join(
      [
        "",
        "  \e[36m┌─ SWARM #{String.duplicate(pad_char, max(inner_width - 9, 1))}┐\e[0m",
        "  \e[36m│\e[0m#{summary}  \e[36m│\e[0m",
        "  \e[36m└#{String.duplicate(pad_char, inner_width)}┘\e[0m"
      ],
      "\n"
    )
  end

  defp agent_id(%{agent_id: id}), do: id
  defp agent_id(%{id: id}), do: id

  defp template(%{template: template}), do: template
  defp template(_), do: nil

  defp status(%{status: status}), do: status
  defp status(_), do: :unknown

  defp tokens(%{tokens: tokens}) when is_integer(tokens), do: tokens
  defp tokens(_), do: 0

  defp tool_calls(%{tool_calls: calls}) when is_integer(calls), do: calls
  defp tool_calls(_), do: 0

  defp tool_names(%{tool_names: %MapSet{} = names}), do: MapSet.to_list(names)
  defp tool_names(%{tool_names: names}) when is_list(names), do: names
  defp tool_names(_), do: []

  defp prepend_if(list, true, item), do: [item | list]
  defp prepend_if(list, false, _item), do: list
end
