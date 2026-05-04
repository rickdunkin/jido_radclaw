defmodule JidoClaw.AgentServerPlugin.Recorder do
  @moduledoc """
  Bridges agent-mailbox `ai.*` signals onto `JidoClaw.SignalBus`.

  The agent's `Jido.AgentServer` runs `handle_signal/2` for every plugin
  before signal processing. We use this hook to publish the signal onto
  the project-wide `Jido.Signal.Bus` so the `Conversations.Recorder`
  GenServer can persist tool activity into Postgres.

  ## Why a plugin (not a `Bus.subscribe` from the Recorder)

  `Jido.AgentServer` does NOT publish signals to the bus by default —
  it dispatches them directly to plugins, then to the router, then to
  actions. There's no central bus topic carrying every `ai.tool.*` /
  `ai.llm.response` signal. This plugin is the bridge.

  ## Signal patterns

  This plugin observes (but does not route) the v0.6 conversation
  signals:

    * `ai.tool.started` — tool call about to execute
    * `ai.tool.result` — tool call returned (ok or error envelope)
    * `ai.llm.response` — final LLM response, may carry `thinking_content`
    * `ai.request.completed` — terminal signal for a request_id
    * `ai.request.failed` — terminal signal (error path)

  Returning `{:ok, :continue}` from `handle_signal/2` is critical:
  the AgentServer halts signal processing on `{:error, _}` returns
  (`agent_server.ex:1896`). Wrap publish in try/rescue and always
  return `{:ok, :continue}` so a bus crash never stalls the agent.
  """

  use Jido.Plugin,
    name: "recorder",
    state_key: :recorder,
    actions: [],
    description: "Bridges agent ai.* signals onto JidoClaw.SignalBus.",
    signal_patterns: [
      "ai.tool.started",
      "ai.tool.result",
      "ai.llm.response",
      "ai.request.completed",
      "ai.request.failed"
    ]

  require Logger

  @impl Jido.Plugin
  def mount(_agent, _config), do: {:ok, nil}

  @impl Jido.Plugin
  def handle_signal(signal, _ctx) do
    publish(signal)
    {:ok, :continue}
  end

  defp publish(signal) do
    Jido.Signal.Bus.publish(JidoClaw.SignalBus, [signal])
  rescue
    e ->
      Logger.warning("[Recorder.Plugin] publish raised: #{Exception.message(e)}")
      :error
  catch
    kind, payload ->
      Logger.warning("[Recorder.Plugin] publish #{kind}: #{inspect(payload)}")
      :error
  end
end
