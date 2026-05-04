defmodule JidoClaw.Conversations.Recorder do
  @moduledoc """
  GenServer that subscribes to `ai.*` topics on `JidoClaw.SignalBus` and
  writes the corresponding `Conversations.Message` rows.

  ## Signals consumed

    * `ai.tool.started` — write a `:tool_call` row
    * `ai.tool.result` — write a `:tool_result` row, linked to the
      corresponding `:tool_call` via `parent_message_id`
    * `ai.llm.response` — extract `thinking_content` from the result
      tuple and write a `:reasoning` row when non-empty
    * `ai.request.completed` / `ai.request.failed` — terminal signals;
      delete the matching `RequestCorrelation` row + Cache entry; reply
      to any pending `flush(request_id)` calls

  All signals carry a `request_id` (in `signal.data.metadata.request_id`
  for tool signals, `signal.data.request_id` for terminal signals);
  the Recorder uses it to look up the dispatching scope from the
  `RequestCorrelation.Cache` (with Postgres fallback).

  ## Flush barrier (`flush/2`)

  The dispatcher (`JidoClaw.chat/4`, REPL, channel adapters) calls
  `Recorder.flush(request_id)` after `Agent.ask_sync` returns and
  before writing the assistant message. The call blocks until the
  Recorder has finished processing the request's terminal signal,
  which guarantees:

    * every `:tool_call` / `:tool_result` / `:reasoning` row for that
      `request_id` has been committed to Postgres
    * those rows have `sequence < assistant_row.sequence`

  Per BEAM semantics, the Recorder's mailbox is processed FIFO from a
  single sender (the bus PID). With `partition_count: 1` on the bus,
  every signal for one agent invocation is delivered in emission order
  from the same sender, so processing the terminal signal implies all
  prior request signals have already been processed.

  Implementation: a `waiters` map (`request_id => [from]`) and a
  bounded `recent_completed` LRU; the call replies immediately if the
  request already terminated, otherwise blocks until the terminal
  signal is processed.

  ## Bus restart resilience

  `init/1` returns `{:ok, state, {:continue, :setup}}`. `setup` resolves
  the bus PID via `Jido.Signal.Bus.whereis/2`; if the bus isn't up yet
  (`{:error, :not_found}`), it schedules a 250ms `:retry_setup` send.
  When the resolved bus crashes, the `:DOWN` handler schedules the
  same retry. Either path eventually re-subscribes. The agent loop
  keeps emitting signals during downtime — they're dropped, which is
  fine because the dispatcher never emits a terminal signal until
  after the Recorder has reattached (worst case the flush call times
  out and the dispatcher proceeds with a logged warning).
  """

  use GenServer
  require Logger

  alias JidoClaw.Conversations.{Message, RequestCorrelation, TranscriptEnvelope}
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Security.Redaction.Transcript

  @topics [
    "ai.tool.started",
    "ai.tool.result",
    "ai.llm.response",
    "ai.request.completed",
    "ai.request.failed"
  ]

  @recent_completed_max 512
  @retry_after_ms 250

  defstruct bus_pid: nil,
            subscriptions: [],
            waiters: %{},
            recent_completed: :queue.new(),
            recent_completed_set: MapSet.new()

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Block until the Recorder has finished processing the terminal signal
  for `request_id`, or until `timeout` ms elapse.

  Returns `:ok` on success, `{:error, :timeout}` if the timeout fires
  before the terminal signal arrives. Importantly, this does NOT
  exit the caller process on timeout — a raw `GenServer.call` would,
  which would crash the dispatcher and surface as `EXIT` to whatever
  supervises it. Wrapping in try/catch lets the dispatcher decide what
  to do — and the right call here is to log + continue with the
  assistant write, because dropping the agent's response is worse than
  a rare ordering miss.
  """
  @spec flush(String.t(), timeout()) :: :ok | {:error, :timeout}
  def flush(request_id, timeout \\ 30_000) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:flush, request_id}, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[Recorder.flush] timeout for request_id=#{request_id}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      Logger.warning("[Recorder.flush] Recorder not running, request_id=#{request_id}")
      {:error, :timeout}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_setup(state)}
  end

  @impl true
  def handle_info(:retry_setup, state) do
    {:noreply, do_setup(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Process.send_after(self(), :retry_setup, @retry_after_ms)
    {:noreply, %{state | bus_pid: nil, subscriptions: []}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = signal}, state) do
    {:noreply, handle_signal(signal, state)}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:flush, request_id}, from, state) do
    if MapSet.member?(state.recent_completed_set, request_id) do
      {:reply, :ok, state}
    else
      waiters = Map.update(state.waiters, request_id, [from], &[from | &1])
      {:noreply, %{state | waiters: waiters}}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup / subscription
  # ---------------------------------------------------------------------------

  defp do_setup(state) do
    case Jido.Signal.Bus.whereis(JidoClaw.SignalBus) do
      {:ok, bus_pid} ->
        subs = Enum.map(@topics, &subscribe_topic/1)
        Process.monitor(bus_pid)
        %{state | bus_pid: bus_pid, subscriptions: subs}

      {:error, _} ->
        Process.send_after(self(), :retry_setup, @retry_after_ms)
        state
    end
  end

  defp subscribe_topic(topic) do
    case JidoClaw.SignalBus.subscribe(topic) do
      {:ok, sub_id} -> {topic, sub_id}
      _ -> {topic, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Signal dispatch
  # ---------------------------------------------------------------------------

  defp handle_signal(%{type: "ai.tool.started"} = signal, state) do
    safe_handle(fn -> record_tool_call(signal) end, "ai.tool.started")
    state
  end

  defp handle_signal(%{type: "ai.tool.result"} = signal, state) do
    safe_handle(fn -> record_tool_result(signal) end, "ai.tool.result")
    state
  end

  defp handle_signal(%{type: "ai.llm.response"} = signal, state) do
    safe_handle(fn -> record_reasoning(signal) end, "ai.llm.response")
    state
  end

  defp handle_signal(%{type: "ai.request.completed"} = signal, state) do
    request_id = get_in(signal.data, [:request_id]) || signal.data["request_id"]
    finalize_request(request_id, state)
  end

  defp handle_signal(%{type: "ai.request.failed"} = signal, state) do
    request_id = get_in(signal.data, [:request_id]) || signal.data["request_id"]
    finalize_request(request_id, state)
  end

  defp handle_signal(_, state), do: state

  # ---------------------------------------------------------------------------
  # Tool call
  # ---------------------------------------------------------------------------

  defp record_tool_call(%{data: data}) do
    request_id = metadata_request_id(data)
    tool_call_id = field(data, :call_id)
    tool_name = field(data, :tool_name) || ""
    arguments = field(data, :arguments)

    with {:ok, scope} <- resolve_scope(request_id) do
      envelope = arguments |> TranscriptEnvelope.normalize() |> Transcript.redact()

      content = "#{tool_name}(#{summarize_args(arguments)})"

      attrs = %{
        session_id: scope.session_id,
        request_id: request_id,
        role: :tool_call,
        content: content,
        metadata: %{
          tool_name: tool_name,
          arguments: envelope
        },
        tool_call_id: tool_call_id
      }

      attempt_append(attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Tool result
  # ---------------------------------------------------------------------------

  defp record_tool_result(%{data: data}) do
    request_id = metadata_request_id(data)
    tool_call_id = field(data, :call_id)
    tool_name = field(data, :tool_name) || ""
    raw_result = field(data, :result)

    with {:ok, scope} <- resolve_scope(request_id) do
      envelope = raw_result |> TranscriptEnvelope.normalize() |> Transcript.redact()

      parent =
        if is_binary(request_id) and is_binary(tool_call_id) do
          case Message.tool_call_parent(scope.session_id, request_id, tool_call_id) do
            {:ok, [%{id: id} | _]} -> id
            _ -> nil
          end
        else
          nil
        end

      content = result_summary(tool_name, raw_result)

      attrs = %{
        session_id: scope.session_id,
        request_id: request_id,
        role: :tool_result,
        content: content,
        metadata: %{
          tool_name: tool_name,
          result: envelope
        },
        tool_call_id: tool_call_id,
        parent_message_id: parent
      }

      attempt_append(attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Reasoning
  # ---------------------------------------------------------------------------

  defp record_reasoning(%{data: data}) do
    request_id = metadata_request_id(data)
    thinking = thinking_content(data)

    cond do
      is_nil(request_id) ->
        :skip

      is_nil(thinking) or thinking == "" ->
        :skip

      true ->
        with {:ok, scope} <- resolve_scope(request_id) do
          attrs = %{
            session_id: scope.session_id,
            request_id: request_id,
            role: :reasoning,
            content: thinking,
            metadata: %{}
          }

          attempt_append(attrs)
        end
    end
  end

  defp thinking_content(%{result: {:ok, %{thinking_content: tc}, _effects}})
       when is_binary(tc),
       do: tc

  defp thinking_content(%{result: {:ok, %{thinking_content: tc}}})
       when is_binary(tc),
       do: tc

  defp thinking_content(%{result: {:ok, %{"thinking_content" => tc}, _effects}})
       when is_binary(tc),
       do: tc

  defp thinking_content(_), do: nil

  # ---------------------------------------------------------------------------
  # Terminal signals
  # ---------------------------------------------------------------------------

  defp finalize_request(nil, state), do: state

  defp finalize_request(request_id, state) do
    safe_handle(
      fn ->
        Cache.delete(request_id)

        case RequestCorrelation.complete(request_id) do
          :ok -> :ok
          {:ok, _} -> :ok
          # Already deleted (idempotent re-emission) — fine.
          {:error, _} -> :ok
        end
      end,
      "ai.request.terminal"
    )

    state
    |> reply_waiters(request_id)
    |> mark_completed(request_id)
  end

  defp reply_waiters(state, request_id) do
    {pending, waiters} = Map.pop(state.waiters, request_id, [])
    Enum.each(pending, &GenServer.reply(&1, :ok))
    %{state | waiters: waiters}
  end

  defp mark_completed(state, request_id) do
    if MapSet.member?(state.recent_completed_set, request_id) do
      state
    else
      queue = :queue.in(request_id, state.recent_completed)
      set = MapSet.put(state.recent_completed_set, request_id)

      if MapSet.size(set) > @recent_completed_max do
        case :queue.out(queue) do
          {{:value, evicted}, queue1} ->
            %{state | recent_completed: queue1, recent_completed_set: MapSet.delete(set, evicted)}

          _ ->
            %{state | recent_completed: queue, recent_completed_set: set}
        end
      else
        %{state | recent_completed: queue, recent_completed_set: set}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scope resolution
  # ---------------------------------------------------------------------------

  defp resolve_scope(nil), do: :error

  defp resolve_scope(request_id) do
    case Cache.lookup(request_id) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        case RequestCorrelation.lookup(request_id) do
          {:ok, row} ->
            scope = %{
              session_id: row.session_id,
              tenant_id: row.tenant_id,
              workspace_id: row.workspace_id,
              user_id: row.user_id
            }

            Cache.put(request_id, scope)
            {:ok, scope}

          _ ->
            :error
        end
    end
  rescue
    e ->
      Logger.warning("[Recorder] scope lookup failed: #{Exception.message(e)}")
      :error
  end

  # ---------------------------------------------------------------------------
  # Append helpers
  # ---------------------------------------------------------------------------

  defp attempt_append(attrs) do
    case Message.append(attrs) do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        if duplicate_key?(err) do
          Logger.debug("[Recorder] duplicate key (idempotent skip): #{inspect(err)}")
        else
          Logger.warning("[Recorder] append failed: #{inspect(err)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("[Recorder] append failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[Recorder] append raised: #{Exception.message(e)}")
      :ok
  end

  defp duplicate_key?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn err ->
      is_struct(err) and
        (Map.get(err, :__struct__) == Ash.Error.Changes.InvalidAttribute or
           Map.get(err, :__struct__) == Ash.Error.Invalid)
        |> Kernel.&&(true)
    end) and
      errors
      |> Enum.map(&inspect/1)
      |> Enum.any?(
        &String.contains?(&1, [
          "unique_session_sequence",
          "unique_live_tool_row",
          "unique_import_hash"
        ])
      )
  end

  defp duplicate_key?(_), do: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_handle(fun, label) do
    fun.()
  rescue
    e -> Logger.warning("[Recorder] #{label} raised: #{Exception.message(e)}")
  catch
    kind, payload -> Logger.warning("[Recorder] #{label} #{kind}: #{inspect(payload)}")
  end

  defp metadata_request_id(data) do
    metadata = field(data, :metadata) || %{}
    field(metadata, :request_id)
  end

  defp field(data, key) when is_map(data) do
    Map.get(data, key, Map.get(data, Atom.to_string(key)))
  end

  defp field(_, _), do: nil

  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{summarize_value(v)}" end)
  end

  defp summarize_args(_), do: ""

  defp summarize_value(v) when is_binary(v), do: ~s("#{String.slice(v, 0, 40)}")
  defp summarize_value(v), do: inspect(v, limit: 5)

  defp result_summary(name, {:ok, _, _}), do: "#{name} → ok"
  defp result_summary(name, {:ok, _}), do: "#{name} → ok"

  defp result_summary(name, {:error, reason, _}),
    do: "#{name} → error: #{inspect(reason, limit: 3)}"

  defp result_summary(name, {:error, reason}), do: "#{name} → error: #{inspect(reason, limit: 3)}"
  defp result_summary(name, _), do: "#{name} → unknown"
end
