defmodule JidoClaw.Display do
  @moduledoc """
  Central display coordinator for the JidoClaw REPL.

  Manages two display modes:
  - **Single mode**: Kaomoji thinking spinner + inline tool call/result lines
  - **Swarm mode**: Activated on first child agent spawn. Shows a live swarm box
    with per-agent status, tool tracking, and token counts.

  Owns all terminal rendering (ANSI escape codes). The REPL signals state
  transitions; Display decides what/when to render.
  """

  use GenServer
  require Logger

  alias JidoClaw.Display.{StatusBar, SwarmBox}

  @spinner_interval 150
  @status_bar_interval 1000
  @render_throttle 100

  @swarm_header_debounce 300

  defstruct [
    :model,
    :provider,
    :context_window,
    :spinner_ref,
    :status_bar_ref,
    :last_render,
    :swarm_header_timer,
    mode: :single,
    thinking: false,
    spinner_tick: 0,
    terminal_width: 120,
    swarm_lines_rendered: 0,
    swarm_header_rendered: false,
    input_mode: false
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Configure the display with model/provider info (called at REPL boot)."
  def configure(model, provider, context_window \\ 131_072) do
    GenServer.cast(__MODULE__, {:configure, model, provider, context_window})
  end

  @doc "Start the thinking spinner (kaomoji animation)."
  def start_thinking do
    GenServer.cast(__MODULE__, :start_thinking)
  end

  @doc "Stop the thinking spinner."
  def stop_thinking do
    GenServer.cast(__MODULE__, :stop_thinking)
  end

  @doc "Display a tool call starting (⟳ icon)."
  def tool_start(agent_id, tool_name, args \\ %{}) do
    GenServer.cast(__MODULE__, {:tool_start, agent_id, tool_name, args})
  end

  @doc "Display a tool call completing (✓ icon). Pass optional result for rich preview."
  def tool_complete(agent_id, tool_name, result \\ nil) do
    GenServer.cast(__MODULE__, {:tool_complete, agent_id, tool_name, result})
  end

  @doc "Signal that the REPL is waiting for user input (suppress display updates)."
  def enter_input_mode do
    GenServer.cast(__MODULE__, :enter_input_mode)
  end

  @doc "Signal that the REPL has received input and is processing."
  def exit_input_mode do
    GenServer.cast(__MODULE__, :exit_input_mode)
  end

  @doc "Reset display state (e.g. between conversations)."
  def reset_mode do
    GenServer.cast(__MODULE__, :reset_mode)
  end

  @doc "Render the status bar immediately (for /status command)."
  def render_status_bar do
    GenServer.call(__MODULE__, :render_status_bar)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    width = detect_terminal_width()
    {:ok, %__MODULE__{terminal_width: width}}
  end

  @impl true
  def handle_cast({:configure, model, provider, context_window}, state) do
    {:noreply, %{state | model: model, provider: provider, context_window: context_window}}
  end

  def handle_cast(:start_thinking, state) do
    ref = Process.send_after(self(), :spinner_tick, @spinner_interval)
    {:noreply, %{state | thinking: true, spinner_ref: ref, spinner_tick: 0}}
  end

  def handle_cast(:stop_thinking, state) do
    if state.spinner_ref, do: Process.cancel_timer(state.spinner_ref)
    # Clear the spinner line
    IO.write("\e[2K\r")
    {:noreply, %{state | thinking: false, spinner_ref: nil}}
  end

  def handle_cast({:tool_start, agent_id, tool_name, args}, state) do
    # Stop thinking spinner if active (first tool call)
    state =
      if state.thinking do
        if state.spinner_ref, do: Process.cancel_timer(state.spinner_ref)
        IO.write("\e[2K\r")
        %{state | thinking: false, spinner_ref: nil}
      else
        state
      end

    case state.mode do
      :single ->
        render_tool_start(tool_name, args)
        {:noreply, state}

      :swarm ->
        render_tool_start_swarm(agent_id, tool_name)
        {:noreply, state}
    end
  end

  def handle_cast({:tool_complete, agent_id, tool_name, result}, state) do
    case state.mode do
      :single ->
        render_tool_complete(tool_name, result)
        {:noreply, state}

      :swarm ->
        render_tool_complete_swarm(agent_id, tool_name, state)
        {:noreply, state}
    end
  end

  def handle_cast(:enter_input_mode, state) do
    if state.status_bar_ref, do: Process.cancel_timer(state.status_bar_ref)
    {:noreply, %{state | input_mode: true, status_bar_ref: nil}}
  end

  def handle_cast(:exit_input_mode, state) do
    {:noreply, %{state | input_mode: false}}
  end

  def handle_cast(:reset_mode, state) do
    if state.swarm_header_timer, do: Process.cancel_timer(state.swarm_header_timer)

    {:noreply,
     %{
       state
       | mode: :single,
         swarm_lines_rendered: 0,
         swarm_header_rendered: false,
         swarm_header_timer: nil
     }}
  end

  @impl true
  def handle_call(:render_status_bar, _from, state) do
    bar = render_status_bar_string(state)
    {:reply, bar, state}
  end

  # -- Spinner tick --
  @impl true
  def handle_info(:spinner_tick, %{thinking: false} = state) do
    {:noreply, state}
  end

  def handle_info(:spinner_tick, state) do
    frame = JidoClaw.CLI.Branding.spinner_frame(state.spinner_tick)
    IO.write("\e[2K\r#{frame}")
    ref = Process.send_after(self(), :spinner_tick, @spinner_interval)
    {:noreply, %{state | spinner_tick: state.spinner_tick + 1, spinner_ref: ref}}
  end

  # -- Status bar tick --
  def handle_info(:status_bar_tick, %{input_mode: true} = state) do
    {:noreply, state}
  end

  def handle_info(:status_bar_tick, state) do
    if state.mode == :swarm and not state.input_mode do
      render_swarm_update(state)
    end

    ref = Process.send_after(self(), :status_bar_tick, @status_bar_interval)
    {:noreply, %{state | status_bar_ref: ref}}
  end

  # -- AgentTracker notifications --
  def handle_info({:agent_registered, id, _entry}, state) when id != "main" do
    state =
      if state.mode != :swarm do
        # Enter swarm mode — stop spinner, schedule debounced header render
        state =
          if state.thinking do
            if state.spinner_ref, do: Process.cancel_timer(state.spinner_ref)
            IO.write("\e[2K\r")
            %{state | thinking: false, spinner_ref: nil}
          else
            state
          end

        ref = Process.send_after(self(), :status_bar_tick, @status_bar_interval)
        timer = Process.send_after(self(), :render_swarm_header, @swarm_header_debounce)

        %{
          state
          | mode: :swarm,
            status_bar_ref: ref,
            swarm_header_timer: timer,
            swarm_header_rendered: false,
            swarm_lines_rendered: 0
        }
      else
        # Already in swarm mode — reset the debounce timer if header not yet rendered
        if not state.swarm_header_rendered and state.swarm_header_timer do
          Process.cancel_timer(state.swarm_header_timer)
          timer = Process.send_after(self(), :render_swarm_header, @swarm_header_debounce)
          %{state | swarm_header_timer: timer}
        else
          state
        end
      end

    # If header already rendered, append agent line immediately
    if state.swarm_header_rendered do
      tracker_state = JidoClaw.AgentTracker.get_state()

      case Map.get(tracker_state.agents, id) do
        nil ->
          {:noreply, state}

        entry ->
          IO.puts(SwarmBox.render_agent_line(entry))
          {:noreply, %{state | swarm_lines_rendered: state.swarm_lines_rendered + 1}}
      end
    else
      # Header not yet rendered — agents will be rendered when debounce fires
      {:noreply, state}
    end
  end

  def handle_info({:agent_registered, _id, _entry}, state) do
    {:noreply, state}
  end

  # Debounced swarm header render — fires after all rapid agent registrations settle
  def handle_info(:render_swarm_header, state) do
    tracker_state = JidoClaw.AgentTracker.get_state()
    header = SwarmBox.render_header(tracker_state.agents, state.terminal_width)
    IO.puts(header)

    # Render all agent lines registered so far
    agents_output = SwarmBox.render_agents(tracker_state.agents, tracker_state.order)
    if agents_output != "", do: IO.puts(agents_output)

    children_count =
      tracker_state.agents |> Enum.reject(fn {id, _} -> id == "main" end) |> length()

    {:noreply,
     %{
       state
       | swarm_header_rendered: true,
         swarm_header_timer: nil,
         swarm_lines_rendered: children_count
     }}
  end

  def handle_info({:agent_completed, id, _status}, state) when id != "main" do
    # Re-render the swarm box with updated status
    throttled_swarm_render(state)
    check_swarm_complete(state)
    {:noreply, state}
  end

  def handle_info({:agent_completed, _id, _status}, state) do
    {:noreply, state}
  end

  def handle_info({:agent_tool, _agent_id, _tool_name}, state) do
    # Tool tracking is handled by the tool_start/tool_complete cast calls
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Rendering (Private)
  # ---------------------------------------------------------------------------

  defp render_tool_start(tool_name, args) when is_map(args) do
    args_str =
      args
      |> Enum.map(fn {k, v} ->
        v_display = truncate_value(v)
        "\e[2m#{k}=\e[0m#{v_display}"
      end)
      |> Enum.join(" ")

    IO.puts("  \e[33m⟳\e[0m \e[1m#{tool_name}\e[0m #{args_str}")
  end

  defp render_tool_complete(tool_name, result) do
    IO.puts("  \e[32m✓\e[0m \e[2m#{tool_name}\e[0m")
    render_tool_result_preview(tool_name, result)
  end

  # Rich tool result previews — show file changes, diffs, content snippets
  defp render_tool_result_preview("edit_file", %{diff: diff, path: path}) when is_binary(diff) do
    IO.puts("    \e[2m#{Path.basename(path)}\e[0m")

    diff
    |> String.split("\n")
    |> Enum.take(12)
    |> Enum.each(fn
      "- " <> rest -> IO.puts("    \e[31m- #{rest}\e[0m")
      "+ " <> rest -> IO.puts("    \e[32m+ #{rest}\e[0m")
      line -> IO.puts("    \e[2m#{line}\e[0m")
    end)

    lines = diff |> String.split("\n") |> length()
    if lines > 12, do: IO.puts("    \e[2m... #{lines - 12} more lines\e[0m")
  end

  defp render_tool_result_preview("write_file", %{path: path, lines_written: lines}) do
    IO.puts("    \e[32m+\e[0m \e[2m#{Path.basename(path)} (#{lines} lines)\e[0m")
  end

  defp render_tool_result_preview("read_file", %{path: path, total_lines: total}) do
    IO.puts("    \e[2m#{Path.basename(path)} (#{total} lines)\e[0m")
  end

  defp render_tool_result_preview("search_code", %{matches: matches}) when is_list(matches) do
    count = length(matches)
    IO.puts("    \e[2m#{count} match#{if count != 1, do: "es", else: ""}\e[0m")
  end

  defp render_tool_result_preview("run_command", %{exit_code: code}) do
    if code == 0 do
      IO.puts("    \e[32m✓\e[0m \e[2mexit 0\e[0m")
    else
      IO.puts("    \e[31m✗\e[0m \e[2mexit #{code}\e[0m")
    end
  end

  defp render_tool_result_preview(_, _), do: :ok

  defp render_tool_start_swarm(agent_id, tool_name) do
    IO.puts("  \e[2m  └─\e[0m \e[33m⟳\e[0m \e[2m@#{agent_id}\e[0m \e[1m#{tool_name}\e[0m")
  end

  defp render_tool_complete_swarm(agent_id, tool_name, _state) do
    IO.puts("  \e[2m  └─\e[0m \e[32m✓\e[0m \e[2m@#{agent_id}\e[0m \e[2m#{tool_name}\e[0m")
  end

  defp throttled_swarm_render(state) do
    now = System.monotonic_time(:millisecond)
    last = state.last_render || 0

    if now - last >= @render_throttle do
      render_swarm_update(state)
    end
  end

  defp render_swarm_update(_state) do
    tracker_state = JidoClaw.AgentTracker.get_state()
    children = tracker_state.agents |> Enum.reject(fn {id, _} -> id == "main" end)

    if length(children) > 0 do
      # Print a compact status line
      _running = Enum.count(children, fn {_, a} -> a.status == :running end)
      done = Enum.count(children, fn {_, a} -> a.status == :done end)
      total_tokens = children |> Enum.reduce(0, fn {_, a}, acc -> acc + a.tokens end)

      status =
        "\e[2m  [swarm: #{done}/#{length(children)} done · #{StatusBar.format_tokens(total_tokens)} tokens]\e[0m"

      IO.write("\e[2K\r#{status}")
    end
  end

  defp check_swarm_complete(_state) do
    tracker_state = JidoClaw.AgentTracker.get_state()
    children = tracker_state.agents |> Enum.reject(fn {id, _} -> id == "main" end)

    all_done = Enum.all?(children, fn {_, a} -> a.status in [:done, :error] end)

    if all_done and length(children) > 0 do
      IO.puts(SwarmBox.render_summary(tracker_state.agents))
    end
  end

  defp render_status_bar_string(state) do
    tracker_state = JidoClaw.AgentTracker.get_state()
    StatusBar.render(state, tracker_state, state.terminal_width)
  end

  defp truncate_value(v) when is_binary(v) do
    if String.length(v) > 80 do
      "\e[2m\"#{String.slice(v, 0, 77)}...\"\e[0m"
    else
      "\e[2m\"#{v}\"\e[0m"
    end
  end

  defp truncate_value(v), do: "\e[2m#{inspect(v, limit: 3)}\e[0m"

  defp detect_terminal_width do
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
end
