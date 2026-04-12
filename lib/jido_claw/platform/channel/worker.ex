defmodule JidoClaw.Channel.Worker do
  @moduledoc "GenServer wrapping a channel adapter. Manages connect/disconnect lifecycle."
  use GenServer
  require Logger

  defstruct [:tenant_id, :adapter, :adapter_state, :config, status: :disconnected]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    adapter = Keyword.fetch!(opts, :adapter)
    config = Keyword.fetch!(opts, :config)

    case adapter.init(config) do
      {:ok, adapter_state} ->
        state = %__MODULE__{
          tenant_id: tenant_id,
          adapter: adapter,
          adapter_state: adapter_state,
          config: config
        }

        # Auto-connect
        send(self(), :connect)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      adapter: state.adapter,
      tenant_id: state.tenant_id,
      status: state.status,
      platform: state.adapter |> Module.split() |> List.last() |> String.downcase()
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case state.adapter.connect(state.adapter_state) do
      {:ok, new_adapter_state} ->
        Logger.info("[Channel] #{inspect(state.adapter)} connected for tenant #{state.tenant_id}")
        {:noreply, %{state | adapter_state: new_adapter_state, status: :connected}}

      {:error, reason} ->
        Logger.error("[Channel] #{inspect(state.adapter)} connect failed: #{inspect(reason)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, %{state | status: :reconnecting}}
    end
  end

  def handle_info({:inbound, raw_message}, state) do
    JidoClaw.Telemetry.emit_channel_inbound(%{adapter: state.adapter, tenant_id: state.tenant_id})

    case state.adapter.handle_inbound(raw_message, state.adapter_state) do
      {:reply, _response, new_adapter_state} ->
        JidoClaw.Telemetry.emit_channel_outbound(%{
          adapter: state.adapter,
          tenant_id: state.tenant_id
        })

        {:noreply, %{state | adapter_state: new_adapter_state}}

      {:noreply, new_adapter_state} ->
        {:noreply, %{state | adapter_state: new_adapter_state}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.adapter.disconnect(state.adapter_state)
    :ok
  end
end
