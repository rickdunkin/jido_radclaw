defmodule JidoClaw.Test.StubSandbox do
  @moduledoc """
  Test substrate for runner unit tests. Records every Sandbox API call
  in a per-client Agent so the test can assert on argv shape, file
  writes, and env injection without executing anything. Programs the
  return value of `run/4` via `program_run/2` so tests can drive the
  parser through `run_iteration/3` with canned JSONL.
  """

  @behaviour JidoClaw.Forge.Sandbox.Behaviour

  defstruct [:agent_pid]

  @doc "Create a new stub-sandbox client with an empty event log."
  @impl true
  def create(_spec \\ %{}) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{events: [], run_response: {"", 0}, files: %{}, env: %{}}
      end)

    {:ok, %__MODULE__{agent_pid: agent}, "stub-#{:erlang.unique_integer([:positive])}"}
  end

  @doc "Return the recorded events in chronological order."
  def events(%__MODULE__{agent_pid: pid}),
    do: Agent.get(pid, fn s -> Enum.reverse(s.events) end)

  @doc "Return the file contents written to `path`, or `nil`."
  def file(%__MODULE__{agent_pid: pid}, path),
    do: Agent.get(pid, fn s -> Map.get(s.files, path) end)

  @doc "Return the injected env map."
  def env(%__MODULE__{agent_pid: pid}),
    do: Agent.get(pid, fn s -> s.env end)

  @doc "Program the next return value of `run/4` (and any subsequent calls)."
  def program_run(%__MODULE__{agent_pid: pid}, response),
    do: Agent.update(pid, fn s -> %{s | run_response: response} end)

  @doc "Return the most recent recorded `run/4` argv."
  def last_run_args(%__MODULE__{agent_pid: pid}) do
    Agent.get(pid, fn s ->
      Enum.find_value(s.events, fn
        {:run, args} -> args
        _ -> nil
      end)
    end)
  end

  @impl true
  def exec(%__MODULE__{agent_pid: pid} = _client, command, _opts) do
    Agent.update(pid, fn s -> %{s | events: [{:exec, command} | s.events]} end)
    {"", 0}
  end

  @impl true
  def write_file(%__MODULE__{agent_pid: pid} = _client, path, content) do
    Agent.update(pid, fn s ->
      %{s | files: Map.put(s.files, path, content), events: [{:write, path} | s.events]}
    end)

    :ok
  end

  @impl true
  def read_file(%__MODULE__{agent_pid: pid}, path) do
    case Agent.get(pid, fn s -> Map.get(s.files, path) end) do
      nil -> {:error, :enoent}
      content -> {:ok, content}
    end
  end

  @impl true
  def inject_env(%__MODULE__{agent_pid: pid}, env_map) do
    Agent.update(pid, fn s ->
      %{
        s
        | env: Map.merge(s.env, Map.new(env_map, fn {k, v} -> {to_string(k), to_string(v)} end)),
          events: [{:inject_env, env_map} | s.events]
      }
    end)

    :ok
  end

  @impl true
  def run(%__MODULE__{agent_pid: pid} = _client, agent_type, args, _opts) do
    Agent.update(pid, fn s -> %{s | events: [{:run, [agent_type | args]} | s.events]} end)
    Agent.get(pid, fn s -> s.run_response end)
  end

  @impl true
  def spawn(_, _, _, _), do: {:error, :not_supported}

  @impl true
  def destroy(%__MODULE__{agent_pid: pid}, _sandbox_id) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  @impl true
  def impl_module, do: __MODULE__
end
