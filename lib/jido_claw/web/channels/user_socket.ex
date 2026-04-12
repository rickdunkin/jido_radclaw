defmodule JidoClaw.Web.UserSocket do
  use Phoenix.Socket

  channel("rpc:*", JidoClaw.Web.RpcChannel)

  @impl true
  def connect(params, socket, _connect_info) do
    device_id = Map.get(params, "deviceId", "anonymous")
    {:ok, assign(socket, :device_id, device_id)}
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.device_id}"
end
