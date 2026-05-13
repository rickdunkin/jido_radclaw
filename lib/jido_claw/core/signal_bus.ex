defmodule JidoClaw.SignalBus do
  @moduledoc """
  Signal Bus integration for JidoClaw internal event routing.

  Wraps `Jido.Signal.Bus` to provide a named bus (`JidoClaw.SignalBus`) and
  convenience helpers for emitting and subscribing to JidoClaw signals.

  ## Signal Types

  All signal types follow dot-notation: `jido_claw.<domain>.<action>`

    * `jido_claw.tool.complete`    — emitted after a tool call is recorded
    * `jido_claw.agent.spawned`    — emitted when a child agent is spawned
    * `jido_claw.memory.saved`     — emitted when a memory entry is saved
    * `jido_claw.skill.started`    — emitted when a skill begins execution
    * `jido_claw.skill.completed`  — emitted when a skill finishes

  ## Usage

      # Emit a signal (fire-and-forget — errors are logged, never raised)
      JidoClaw.SignalBus.emit("jido_claw.tool.complete", %{name: "read_file"})

      # Subscribe the calling process to a path pattern
      {:ok, _sub_id} = JidoClaw.SignalBus.subscribe("jido_claw.tool.*")

      # Handle in your process:
      def handle_info({:signal, signal}, state) do
        IO.inspect(signal.data)
        {:noreply, state}
      end
  """

  require Logger

  alias Jido.Signal.Bus

  @bus __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Emits a signal of the given `type` with `data` as the payload.

  Errors are logged and swallowed so that callers (Stats, etc.) are never
  disrupted if the bus is temporarily unavailable.
  """
  @spec emit(String.t(), map()) :: :ok
  def emit(type, data \\ %{}) when is_binary(type) and is_map(data) do
    case Jido.Signal.new(type, data, source: "/jido_claw") do
      {:ok, signal} ->
        case Bus.publish(@bus, [signal]) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.debug("[SignalBus] publish failed for #{type}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("[SignalBus] signal build failed for #{type}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Subscribes the calling process to signals matching `path_pattern`.

  Signals are delivered as `{:signal, %Jido.Signal{}}` messages.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe(String.t()) :: {:ok, String.t()} | {:error, term()}
  def subscribe(path_pattern) when is_binary(path_pattern) do
    Bus.subscribe(@bus, path_pattern, dispatch: {:pid, target: self(), delivery_mode: :async})
  end

  @doc """
  Unsubscribes a previously registered subscription by its ID.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(subscription_id) when is_binary(subscription_id) do
    Bus.unsubscribe(@bus, subscription_id)
  end
end
