defmodule JidoClaw.Test.ForgeStub do
  @moduledoc """
  Deterministic `JidoClaw.Forge` facade for `RunCommand.ForgeBridge` tests.

  The bridge resolves its Forge module from `Application.get_env(:jido_claw,
  :forge_facade, JidoClaw.Forge)`. Installing this stub lets a test drive
  `exec/3` (via a held `JidoClaw.Test.StubSandbox` client — so the real
  `program_exec/2` machinery, including its blocking / `exit`-ing forms, is
  exercised) and observe `stop_session/1` without a live microVM.

  State lives in an Agent whose pid is stashed in app-env (`:forge_stub_agent`)
  so the stub's module functions can find it without a fixed registered name —
  keeping per-test isolation simple. `stop_session/1` records the call **and**
  flips `exec/3` to `{:error, :not_found}`, modelling the torn-down session a
  taint produces (so a follow-up `RunCommand` hard-fails).
  """

  alias JidoClaw.Test.StubSandbox

  @agent_key :forge_stub_agent

  @doc """
  Install this module as the `:forge_facade` and back it with a fresh state
  Agent. `:client` is the `StubSandbox` client `exec/3` delegates to; programme
  its result via `StubSandbox.program_exec/2`. Restores prior env on test exit
  via the returned cleanup fun (call it from `on_exit/1`).

  Options:

    * `:notify` (default `nil`) — a pid `stop_session/2` sends
      `{:forge_stub_stopped, session_id}` to after recording, so a test can
      rendezvous with the now-asynchronous teardown via `assert_receive`.
    * `:stop_delay` (default `0`) — ms `stop_session/2` sleeps **before**
      recording/flipping, simulating a slow `Forge.stop_session` (drives the
      bridge's detached-teardown race). Override per-test via `set_stop_delay/1`.
  """
  @spec install(keyword()) :: (-> :ok)
  def install(opts) do
    client = Keyword.fetch!(opts, :client)
    notify = Keyword.get(opts, :notify)
    stop_delay = Keyword.get(opts, :stop_delay, 0)
    prev_facade = Application.get_env(:jido_claw, :forge_facade)
    prev_agent = Application.get_env(:jido_claw, @agent_key)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          client: client,
          exec_result: :delegate,
          execs: [],
          stops: [],
          notify: notify,
          stop_delay: stop_delay
        }
      end)

    Application.put_env(:jido_claw, :forge_facade, __MODULE__)
    Application.put_env(:jido_claw, @agent_key, agent)

    fn ->
      restore(:forge_facade, prev_facade)
      restore(@agent_key, prev_agent)
      if Process.alive?(agent), do: Agent.stop(agent)
      :ok
    end
  end

  @doc "Force `exec/3` to return `{:error, reason}` (models an absent session)."
  @spec set_absent(term()) :: :ok
  def set_absent(reason \\ :not_found) do
    Agent.update(agent(), fn s -> %{s | exec_result: {:error, reason}} end)
  end

  @doc "Override the simulated `stop_session/2` delay (ms) after the shared setup."
  @spec set_stop_delay(non_neg_integer()) :: :ok
  def set_stop_delay(ms) do
    Agent.update(agent(), fn s -> %{s | stop_delay: ms} end)
  end

  @doc "Recorded `exec/3` calls in chronological order (each `%{command:, opts:}`)."
  @spec execs() :: [map()]
  def execs, do: Agent.get(agent(), fn s -> Enum.reverse(s.execs) end)

  @doc "Recorded `stop_session/1` session ids in chronological order."
  @spec stops() :: [term()]
  def stops, do: Agent.get(agent(), fn s -> Enum.reverse(s.stops) end)

  # -- Forge facade surface the bridge calls -----------------------------------

  @spec exec(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def exec(session_id, command, opts) do
    {client, result} =
      Agent.get_and_update(agent(), fn s ->
        entry = %{session_id: session_id, command: command, opts: opts}
        {{s.client, s.exec_result}, %{s | execs: [entry | s.execs]}}
      end)

    case result do
      :delegate -> {:ok, StubSandbox.exec(client, command, opts)}
      {:error, _reason} = err -> err
    end
  end

  @spec stop_session(term(), term()) :: :ok
  def stop_session(session_id, _reason \\ :normal) do
    {notify, stop_delay} = Agent.get(agent(), fn s -> {s.notify, s.stop_delay} end)

    if stop_delay > 0, do: Process.sleep(stop_delay)

    Agent.update(agent(), fn s ->
      %{s | stops: [session_id | s.stops], exec_result: {:error, :not_found}}
    end)

    if notify, do: send(notify, {:forge_stub_stopped, session_id})

    :ok
  end

  defp agent, do: Application.fetch_env!(:jido_claw, @agent_key)

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
end
