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

  # Streaming-shell-output backpressure. When Display's mailbox grows
  # past the watermark we drain a batch of pending {:output, _} chunks
  # for the affected stream — better to drop bytes than wedge the
  # event loop. The captured-output preview returned to the agent is
  # already preview-sized, so dropping live render bytes is purely a
  # rendering decision.
  @backpressure_watermark 1000
  @drain_batch 500

  # Maximum partial-line buffer we retain in multi-stream mode while
  # waiting for a newline to flush. Prevents unbounded growth on a
  # raw-binary stream with no newlines.
  @line_buffer_cap 65_536

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
    input_mode: false,
    # Active streaming-shell-output sessions, keyed by session_id.
    # Each value: %{agent_id, tool_name, bytes_streamed, started_at,
    # line_buffer, dropped_warned?, done?, end_requested?}.
    streaming_sessions: %{},
    # Profile name surfaced in the status bar. profile != default_profile
    # triggers the yellow `⚑ <name>` segment (see StatusBar.profile_segment/1).
    profile: "default",
    default_profile: "default"
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

  @doc """
  Update the active profile name surfaced in the status bar. Called at
  REPL boot and after every `/profile switch`.
  """
  def set_profile(profile) when is_binary(profile) do
    GenServer.cast(__MODULE__, {:set_profile, profile})
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

  @doc """
  Begin streaming-shell-output rendering for `session_id` attributed
  to `agent_id` running `tool_name`. Returns `:ok` when freshly
  registered, `{:error, :stream_still_draining}` when an entry
  already exists for the session.

  Synchronous on purpose so the caller can subscribe the Display pid
  to the shell session immediately after the registration completes,
  with no race against the first transport event.
  """
  @spec start_stream(String.t(), String.t(), String.t()) ::
          :ok | {:error, :stream_still_draining}
  def start_stream(session_id, agent_id, tool_name) do
    GenServer.call(__MODULE__, {:start_stream, session_id, agent_id, tool_name})
  end

  @doc """
  Mark a streaming-shell-output session as caller-side-done. The
  Display state may not yet be removed — the entry is reaped only
  after both the caller has signalled `end_stream/1` AND a terminal
  transport event (`:command_done`, `{:error, _}`, `:command_cancelled`,
  `{:command_crashed, _}`) has arrived. The flag pair makes ordering
  edge-cases between the two signals safe.
  """
  @spec end_stream(String.t()) :: :ok
  def end_stream(session_id) do
    GenServer.cast(__MODULE__, {:end_stream, session_id})
  end

  @doc """
  Force-drop a streaming-shell-output session registration. Use only
  at known abort sites where no terminal transport event will ever
  arrive — `start_display_stream`'s subscribe-fail branch and
  `run_command` rejection inside `execute_command/4` /
  `execute_ssh_command/...`. Normal completion must use `end_stream/1`
  so queued events from the shell-session sender still render.
  """
  @spec abort_stream(String.t()) :: :ok
  def abort_stream(session_id) do
    GenServer.cast(__MODULE__, {:abort_stream, session_id})
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

  def handle_cast({:set_profile, profile}, state) do
    {:noreply, %{state | profile: profile}}
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

  def handle_cast({:end_stream, session_id}, state) do
    case Map.get(state.streaming_sessions, session_id) do
      nil ->
        # Already removed — terminal event already reaped it.
        {:noreply, state}

      %{done?: true} ->
        {:noreply, drop_streaming(state, session_id)}

      entry ->
        new_entry = %{entry | end_requested?: true}
        {:noreply, put_streaming(state, session_id, new_entry)}
    end
  end

  def handle_cast({:abort_stream, session_id}, state) do
    # Unconditional drop — used only by callers that know no terminal
    # event will ever arrive (subscribe failure, run_command rejection
    # before any broadcast). Safe to call multiple times: second call
    # hits the nil branch above on the corresponding `end_stream`.
    {:noreply, drop_streaming(state, session_id)}
  end

  @impl true
  def handle_call(:render_status_bar, _from, state) do
    bar = render_status_bar_string(state)
    {:reply, bar, state}
  end

  def handle_call({:start_stream, session_id, agent_id, tool_name}, _from, state) do
    if Map.has_key?(state.streaming_sessions, session_id) do
      # Same session_id is reused across back-to-back commands within
      # a workspace (`<workspace>:host`, `:vfs`, `:ssh:<server>` are
      # persistent). Replacing an active entry would misattribute its
      # lagging chunks; better to refuse and let SessionManager fall
      # through to non-streaming mode for this command.
      {:reply, {:error, :stream_still_draining}, state}
    else
      # Clear any spinner so its CR doesn't tear streaming output.
      state =
        if state.thinking do
          if state.spinner_ref, do: Process.cancel_timer(state.spinner_ref)
          IO.write("\e[2K\r")
          %{state | thinking: false, spinner_ref: nil}
        else
          IO.write("\e[2K\r")
          state
        end

      entry = %{
        agent_id: agent_id,
        tool_name: tool_name,
        bytes_streamed: 0,
        started_at: System.monotonic_time(:millisecond),
        line_buffer: <<>>,
        dropped_warned?: false,
        done?: false,
        end_requested?: false
      }

      {:reply, :ok, put_streaming(state, session_id, entry)}
    end
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
    state =
      if state.mode == :swarm and not state.input_mode do
        render_swarm_update(state)
      else
        state
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
    {state, _} = throttled_swarm_render(state)
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

  # -- Streaming-shell-output events ----------------------------------------

  def handle_info({:jido_shell_session, sid, event}, state) do
    case Map.get(state.streaming_sessions, sid) do
      nil ->
        # No active stream for this sid — straggler from an already-reaped
        # entry, or a session_id we never registered. Drop silently.
        {:noreply, state}

      entry ->
        handle_stream_event(sid, entry, event, state)
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Streaming event dispatch (private) -----------------------------------

  defp handle_stream_event(sid, entry, {:command_started, line}, state) do
    if state.thinking do
      if state.spinner_ref, do: Process.cancel_timer(state.spinner_ref)
      IO.write("\e[2K\r")
    end

    IO.write("\n[#{entry.agent_id}] #{entry.tool_name}: $ #{line}\n")
    state = if state.thinking, do: %{state | thinking: false, spinner_ref: nil}, else: state
    {:noreply, put_streaming(state, sid, entry)}
  end

  defp handle_stream_event(sid, entry, {:output, chunk}, state) do
    {entry, state} = maybe_apply_backpressure(sid, entry, state)
    new_entry = emit_chunk(chunk, entry, state)
    {:noreply, put_streaming(state, sid, new_entry)}
  end

  defp handle_stream_event(_sid, _entry, {:exit_status, _code}, state) do
    {:noreply, state}
  end

  defp handle_stream_event(_sid, _entry, {:cwd_changed, _cwd}, state) do
    {:noreply, state}
  end

  defp handle_stream_event(sid, entry, :command_done, state) do
    state = flush_line_buffer(entry, state)
    {:noreply, mark_done_and_maybe_drop(state, sid)}
  end

  defp handle_stream_event(
         sid,
         entry,
         {:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: code}}},
         state
       ) do
    state = flush_line_buffer(entry, state)
    IO.write("\e[2m[exit #{code}]\e[0m\n")
    {:noreply, mark_done_and_maybe_drop(state, sid)}
  end

  defp handle_stream_event(sid, entry, {:error, err}, state) do
    state = flush_line_buffer(entry, state)
    msg = error_message(err)
    IO.write("\e[31m! #{msg}\e[0m\n")
    {:noreply, mark_done_and_maybe_drop(state, sid)}
  end

  defp handle_stream_event(sid, entry, :command_cancelled, state) do
    state = flush_line_buffer(entry, state)
    IO.write("\e[2m[cancelled]\e[0m\n")
    {:noreply, mark_done_and_maybe_drop(state, sid)}
  end

  defp handle_stream_event(sid, entry, {:command_crashed, reason}, state) do
    state = flush_line_buffer(entry, state)
    IO.write("\e[31m[backend crashed: #{inspect(reason)}]\e[0m\n")
    {:noreply, mark_done_and_maybe_drop(state, sid)}
  end

  # Anything else we ignore (catch-all so unexpected event shapes
  # don't blow up the Display).
  defp handle_stream_event(_sid, _entry, _event, state), do: {:noreply, state}

  defp emit_chunk(chunk, %{line_buffer: buf} = entry, state) do
    combined = buf <> chunk
    new_bytes = entry.bytes_streamed + byte_size(chunk)

    case map_size(state.streaming_sessions) do
      1 ->
        IO.binwrite(combined)
        %{entry | line_buffer: <<>>, bytes_streamed: new_bytes}

      _ ->
        {complete_lines, remainder} = split_at_last_newline(combined)

        if complete_lines != <<>>,
          do: IO.binwrite(prefix_each_line(complete_lines, entry.agent_id))

        %{entry | line_buffer: cap_buffer(remainder), bytes_streamed: new_bytes}
    end
  end

  defp split_at_last_newline(data) do
    case :binary.matches(data, <<"\n">>) do
      [] ->
        {<<>>, data}

      matches ->
        {pos, len} = List.last(matches)
        cut = pos + len
        complete = binary_part(data, 0, cut)
        remainder = binary_part(data, cut, byte_size(data) - cut)
        {complete, remainder}
    end
  end

  defp prefix_each_line(lines, agent_id) do
    prefix = "[#{agent_id}] "

    lines
    |> :binary.split(<<"\n">>, [:global])
    |> Enum.map(fn line ->
      cond do
        line == <<>> -> <<>>
        true -> prefix <> line
      end
    end)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp cap_buffer(buf) when byte_size(buf) <= @line_buffer_cap, do: buf

  defp cap_buffer(buf) do
    # Emit + reset with a one-time elision marker so the local
    # rendering still shows roughly what's there. The agent-facing
    # capture is preview-sized regardless.
    IO.binwrite(binary_part(buf, 0, @line_buffer_cap))
    IO.binwrite("\n... (line buffer reset)\n")
    <<>>
  end

  defp flush_line_buffer(%{line_buffer: <<>>}, state), do: state

  defp flush_line_buffer(%{line_buffer: buf, agent_id: agent_id}, state) do
    # Multi-stream mode buffers an unterminated final line until a newline.
    # Terminal events flush whatever's left with the agent prefix.
    IO.binwrite(prefix_each_line(buf, agent_id))
    IO.write("\n")
    state
  end

  defp mark_done_and_maybe_drop(state, sid) do
    case Map.get(state.streaming_sessions, sid) do
      nil ->
        state

      %{end_requested?: true} ->
        drop_streaming(state, sid)

      entry ->
        put_streaming(state, sid, %{entry | done?: true})
    end
  end

  defp put_streaming(state, sid, entry) do
    %{state | streaming_sessions: Map.put(state.streaming_sessions, sid, entry)}
  end

  defp drop_streaming(state, sid) do
    %{state | streaming_sessions: Map.delete(state.streaming_sessions, sid)}
  end

  defp error_message(%_{} = err) do
    try do
      Exception.message(err)
    rescue
      _ -> inspect(err)
    end
  end

  defp error_message(other), do: inspect(other)

  # Drain pending {:output, _} chunks for `sid` when our mailbox is
  # past the watermark. One-shot warn (yellow line) per stream.
  defp maybe_apply_backpressure(sid, entry, state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n > @backpressure_watermark ->
        drained = drain_oldest_output_chunks(sid, @drain_batch)
        warn_backpressure_if_needed(entry, drained, state, sid)

      _ ->
        {entry, state}
    end
  end

  defp drain_oldest_output_chunks(sid, max) do
    do_drain(sid, max, 0)
  end

  defp do_drain(_sid, 0, count), do: count

  defp do_drain(sid, remaining, count) do
    receive do
      {:jido_shell_session, ^sid, {:output, _chunk}} ->
        do_drain(sid, remaining - 1, count + 1)
    after
      0 -> count
    end
  end

  defp warn_backpressure_if_needed(entry, drained, state, sid) when drained > 0 do
    if entry.dropped_warned? do
      {entry, state}
    else
      IO.write(
        "\e[33m[#{entry.agent_id}] [output dropped to keep up — captured result is preview only]\e[0m\n"
      )

      new_entry = %{entry | dropped_warned?: true}
      {new_entry, put_streaming(state, sid, new_entry)}
    end
  end

  defp warn_backpressure_if_needed(entry, _drained, state, _sid), do: {entry, state}

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

  # Returns `{updated_state, :ok | :throttled}`. Bumps `last_render`
  # only when we actually rendered, so the gate can re-open after the
  # throttle window has elapsed (the previous shape never wrote
  # `last_render` back, leaving the gate permanently open).
  defp throttled_swarm_render(state) do
    now = System.monotonic_time(:millisecond)
    last = state.last_render || 0

    if now - last >= @render_throttle do
      state = render_swarm_update(state)
      {%{state | last_render: now}, :ok}
    else
      {state, :throttled}
    end
  end

  defp render_swarm_update(state) do
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

    state
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
