defmodule JidoClaw.Test.TerminalSignal do
  @moduledoc false

  # Publishes the terminal signal (`ai.request.completed` / `ai.request.failed`)
  # that the real `JidoClaw.AgentServerPlugin.Recorder` plugin emits when an
  # agent run finishes, so stubbed LLM paths release `Conversations.Recorder`'s
  # flush barrier immediately instead of blocking to the test-capped timeout.
  # Both types hit the same finalize path (recorder.ex:333-343); pick the one
  # matching the stub's outcome. No-op for nil request_ids and when the
  # SignalBus isn't running.

  alias Jido.Signal.Bus

  @bus JidoClaw.SignalBus
  @completed "ai.request.completed"
  @failed "ai.request.failed"

  @spec emit_completed(String.t() | nil) :: :ok
  def emit_completed(request_id), do: emit_terminal(request_id, @completed)

  @spec emit_failed(String.t() | nil) :: :ok
  def emit_failed(request_id), do: emit_terminal(request_id, @failed)

  @doc "Emit for the request_id embedded in an `await_completion` `:result_path` opt."
  @spec emit_from_await(keyword(), String.t()) :: :ok
  def emit_from_await(opts, type \\ @completed) do
    case Keyword.get(opts, :result_path) do
      [:requests, request_id | _rest] -> emit_terminal(request_id, type)
      _other -> :ok
    end
  end

  defp emit_terminal(request_id, type) when is_binary(request_id) do
    with {:ok, _pid} <- Bus.whereis(@bus),
         {:ok, signal} <- Jido.Signal.new(type, %{request_id: request_id}, source: "/test") do
      _ = Bus.publish(@bus, [signal])
    end

    :ok
  end

  defp emit_terminal(_request_id, _type), do: :ok
end
