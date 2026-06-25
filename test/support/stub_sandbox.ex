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

  @fail_inject_env_key "STUB_SANDBOX_FAIL_INJECT_ENV"

  @doc """
  Magic env key: when present in the map given to `inject_env/2`, the
  call fails with `{:error, :inject_env_refused}` and records nothing.
  Lets Harness tests drive the spec-env-injection failure path without
  a real sandbox backend.
  """
  @spec fail_inject_env_key() :: String.t()
  def fail_inject_env_key, do: @fail_inject_env_key

  @doc """
  Create a new stub-sandbox client with an empty event log.

  Reads an optional `:exec_response` from `spec` (default `{"", 0}`) so a
  Harness-driven session (whose internal client a test can't reach) can still
  program `exec/3` via `sandbox_spec: %{exec_response: ...}`. See
  `program_exec/2` for the accepted response shapes.
  """
  @impl JidoClaw.Forge.Sandbox.Behaviour
  def create(spec \\ %{}) do
    # AR-8b-2 F2: an optional create-time block so a Harness-driven session stalls
    # before `:ready`, driving `Forge.start_session_ready/3`'s await-timeout +
    # unconditional-stop orphan guard (`sandbox_spec: %{create_sleep_ms: ms}`).
    case Map.get(spec, :create_sleep_ms) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end

    exec_response = Map.get(spec, :exec_response, {"", 0})

    {:ok, agent} =
      Agent.start_link(fn ->
        %{events: [], run_response: {"", 0}, exec_response: exec_response, files: %{}, env: %{}}
      end)

    {:ok, %__MODULE__{agent_pid: agent}, "stub-#{:erlang.unique_integer([:positive])}"}
  end

  @doc "Return the recorded events in chronological order."
  @spec events(%__MODULE__{}) :: list()
  def events(%__MODULE__{agent_pid: pid}),
    do: Agent.get(pid, fn s -> Enum.reverse(s.events) end)

  @doc "Return the file contents written to `path`, or `nil`."
  @spec file(%__MODULE__{}, String.t()) :: binary() | nil
  def file(%__MODULE__{agent_pid: pid}, path),
    do: Agent.get(pid, fn s -> Map.get(s.files, path) end)

  @doc "Return the injected env map."
  @spec env(%__MODULE__{}) :: map()
  def env(%__MODULE__{agent_pid: pid}),
    do: Agent.get(pid, fn s -> s.env end)

  @doc "Program the next return value of `run/4` (and any subsequent calls)."
  @spec program_run(%__MODULE__{}, term()) :: :ok
  def program_run(%__MODULE__{agent_pid: pid}, response),
    do: Agent.update(pid, fn s -> %{s | run_response: response} end)

  @doc """
  Program the next return value of `exec/3` (and subsequent calls).

  Accepts:

    * a plain `{out, code}` tuple — returned immediately;
    * `{:sleep, ms, response}` — blocks `ms` then returns `response` (drive the
      AR-8b-2 F2 C3 cushion / bridge-catch timeout race past `timeout` or
      `timeout + cushion`); and
    * a 0-arity fun — invoked and its result returned (it may itself sleep,
      return, or `exit({:timeout, _})` to drive the ForgeBridge's residual catch).
  """
  @spec program_exec(%__MODULE__{}, term()) :: :ok
  def program_exec(%__MODULE__{agent_pid: pid}, response),
    do: Agent.update(pid, fn s -> %{s | exec_response: response} end)

  @doc "Return the most recent recorded `run/4` argv."
  @spec last_run_args(%__MODULE__{}) :: list() | nil
  def last_run_args(%__MODULE__{agent_pid: pid}) do
    Agent.get(pid, fn s ->
      Enum.find_value(s.events, fn
        {:run, args} -> args
        _ -> nil
      end)
    end)
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec(%__MODULE__{agent_pid: pid} = _client, command, _opts) do
    Agent.update(pid, fn s -> %{s | events: [{:exec, command} | s.events]} end)

    pid
    |> Agent.get(fn s -> s.exec_response end)
    |> resolve_exec_response()
  end

  # Blocking forms let a test drive the C3 timeout race; see `program_exec/2`.
  defp resolve_exec_response({:sleep, ms, response}) when is_integer(ms) do
    Process.sleep(ms)
    response
  end

  defp resolve_exec_response(fun) when is_function(fun, 0), do: fun.()
  defp resolve_exec_response(response), do: response

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec_argv(%__MODULE__{agent_pid: pid} = _client, command, args, _opts) do
    Agent.update(pid, fn s -> %{s | events: [{:exec_argv, [command | args]} | s.events]} end)
    {"", 0}
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def write_file(%__MODULE__{agent_pid: pid} = _client, path, content) do
    Agent.update(pid, fn s ->
      %{s | files: Map.put(s.files, path, content), events: [{:write, path} | s.events]}
    end)

    :ok
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def read_file(%__MODULE__{agent_pid: pid}, path) do
    case Agent.get(pid, fn s -> Map.get(s.files, path) end) do
      nil -> {:error, :enoent}
      content -> {:ok, content}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def inject_env(%__MODULE__{agent_pid: pid}, env_map) do
    env = Map.new(env_map, fn {k, v} -> {to_string(k), to_string(v)} end)

    if Map.has_key?(env, @fail_inject_env_key) do
      {:error, :inject_env_refused}
    else
      Agent.update(pid, fn s ->
        %{s | env: Map.merge(s.env, env), events: [{:inject_env, env_map} | s.events]}
      end)

      :ok
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def run(%__MODULE__{agent_pid: pid} = _client, agent_type, args, _opts) do
    Agent.update(pid, fn s -> %{s | events: [{:run, [agent_type | args]} | s.events]} end)
    Agent.get(pid, fn s -> s.run_response end)
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def spawn(_, _, _, _), do: {:error, :not_supported}

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def destroy(%__MODULE__{agent_pid: pid}, _sandbox_id) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def impl_module, do: __MODULE__
end
