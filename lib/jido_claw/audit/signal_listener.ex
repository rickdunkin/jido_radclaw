defmodule JidoClaw.Audit.SignalListener do
  @moduledoc """
  Subscribes to `ai.tool.started` on `JidoClaw.SignalBus` and emits
  one `Audit.Event` row per tool call (event_kind `:tool_call`).

  Mirrors the Conversations.Recorder pattern at `recorder.ex:280-288`:
  the signal carries `request_id` in `data.metadata`; we resolve to a
  scope via `RequestCorrelation.Cache` (with Postgres fallback). When
  no `request_id` is present the call is skipped with a telemetry
  event so a future "every tool always carries request_id" guarantee
  is observable.

  Writes are dispatched via `AsyncWriter.cast/1` so audit-write
  latency doesn't gate the request.
  """

  # audit/telemetry signal handling must never crash the listener
  # reach:disable-for-this-file bare_rescue

  use GenServer
  require Logger

  alias Jido.Signal.Bus
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Audit.EventAttrs
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Conversations.ToolTranscript
  alias JidoClaw.Core.MapKeys

  @topic "ai.tool.started"
  @retry_after_ms 250

  defstruct bus_pid: nil, subscription: nil

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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
    {:noreply, %{state | bus_pid: nil, subscription: nil}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{type: @topic} = signal}, state) do
    safe_handle(signal)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  defp do_setup(state) do
    case Bus.whereis(JidoClaw.SignalBus) do
      {:ok, bus_pid} ->
        Process.monitor(bus_pid)

        sub =
          case JidoClaw.SignalBus.subscribe(@topic) do
            {:ok, sub_id} -> sub_id
            _ -> nil
          end

        %{state | bus_pid: bus_pid, subscription: sub}

      {:error, _} ->
        Process.send_after(self(), :retry_setup, @retry_after_ms)
        state
    end
  end

  defp safe_handle(signal) do
    handle_signal(signal)
  rescue
    e ->
      Logger.warning("[Audit.SignalListener] handler raised: #{Exception.message(e)}")
  catch
    kind, payload ->
      Logger.warning("[Audit.SignalListener] handler #{kind}: #{inspect(payload)}")
  end

  defp handle_signal(%{data: data}) do
    request_id = metadata_request_id(data) || MapKeys.field(data, :request_id)
    tool_name = MapKeys.field(data, :tool_name)
    arguments = MapKeys.field(data, :arguments)

    if is_binary(request_id) do
      case resolve_scope(request_id) do
        {:ok, scope} ->
          agent_id = MapKeys.field(data, :agent_id) || metadata_field(data, :agent_id)

          AsyncWriter.cast(
            EventAttrs.new(
              tenant_id: scope.tenant_id,
              event_kind: :tool_call,
              actor_kind: :agent,
              actor_id: agent_id && to_string(agent_id),
              target_kind: :tool,
              target_id: tool_name && to_string(tool_name),
              payload: %{
                request_id: request_id,
                session_id: scope.session_id && to_string(scope.session_id),
                arguments: ToolTranscript.envelope(arguments),
                tool_name: tool_name
              }
            )
          )

        :error ->
          skip(:correlation_missing, tool_name)
      end
    else
      skip(:no_request_id, tool_name)
    end
  end

  # ex_dna:disable-for-next-line
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
    _ -> :error
  end

  defp skip(reason, tool_name) do
    :telemetry.execute(
      [:jido_claw, :audit, :tool_call, :skipped],
      %{},
      %{reason: reason, tool_name: tool_name}
    )

    :ok
  end

  defp metadata_request_id(data) do
    metadata = MapKeys.field(data, :metadata) || %{}
    MapKeys.field(metadata, :request_id)
  end

  defp metadata_field(data, key) do
    metadata = MapKeys.field(data, :metadata) || %{}
    MapKeys.field(metadata, key)
  end
end
