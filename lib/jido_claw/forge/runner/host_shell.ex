defmodule JidoClaw.Forge.Runner.HostShell do
  @moduledoc """
  Non-isolated Forge backend that executes commands as the host OS user.

  This backend exists for local development and tests. It creates a per-run
  working directory, but it does not provide filesystem, process, network, user,
  cgroup, seccomp, chroot, or namespace isolation. Use
  `JidoClaw.Forge.Sandbox.Docker` when Forge execution needs a real sandbox.
  """

  use Agent

  @behaviour JidoClaw.Forge.Sandbox.Behaviour

  require Logger

  defstruct [:agent_pid, :sandbox_id]

  @warning_key {__MODULE__, :warning_emitted}
  @warning_message """
  [Forge.HostShell] Forge is using the host shell backend. Commands run as the \
  current OS user and are not sandboxed. Set FORGE_SANDBOX=docker for the Docker \
  sandbox backend when running untrusted workloads.
  """

  def start_link(_opts \\ []) do
    warn_once()
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def create(spec) do
    warn_once()

    shell_id = "host_shell_#{:erlang.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "forge_#{shell_id}")
    File.mkdir_p!(dir)

    agent_pid =
      case Process.whereis(__MODULE__) do
        nil ->
          {:ok, pid} = Agent.start_link(fn -> %{} end)
          pid

        pid ->
          pid
      end

    Agent.update(agent_pid, fn state ->
      Map.put(state, shell_id, %{dir: dir, env: Map.get(spec, "env", %{})})
    end)

    client = %__MODULE__{agent_pid: agent_pid, sandbox_id: shell_id}
    {:ok, client, shell_id}
  end

  @impl true
  def exec(%__MODULE__{agent_pid: pid, sandbox_id: sid}, command, _opts) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!(), env: %{}}

    env = Enum.map(sandbox.env, fn {k, v} -> {to_string(k), to_string(v)} end)

    try do
      System.cmd("sh", ["-c", command],
        cd: sandbox.dir,
        env: env,
        stderr_to_stdout: true
      )
    rescue
      e -> {Exception.message(e), 1}
    end
  end

  @impl true
  def exec_argv(%__MODULE__{agent_pid: pid, sandbox_id: sid}, command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {"#{command}: command not found", 127}

      executable ->
        sandbox =
          Agent.get(pid, fn state -> Map.get(state, sid) end) ||
            %{dir: System.tmp_dir!(), env: %{}}

        env = Enum.map(sandbox.env, fn {k, v} -> {to_string(k), to_string(v)} end)
        timeout = Keyword.get(opts, :timeout, :infinity)

        run_with_timeout(executable, args, sandbox.dir, env, timeout)
    end
  end

  @impl true
  def run(%__MODULE__{agent_pid: pid, sandbox_id: sid}, agent_type, args, opts) do
    case System.find_executable(agent_type) do
      nil ->
        {"#{agent_type}: command not found", 127}

      executable ->
        sandbox =
          Agent.get(pid, fn state -> Map.get(state, sid) end) ||
            %{dir: System.tmp_dir!(), env: %{}}

        env = Enum.map(sandbox.env, fn {k, v} -> {to_string(k), to_string(v)} end)
        timeout = Keyword.get(opts, :timeout, :infinity)

        passthrough =
          case Enum.split_while(args, &(&1 != "--")) do
            {_before, ["--" | rest]} -> rest
            {all, []} -> all
          end

        run_with_timeout(executable, passthrough, sandbox.dir, env, timeout)
    end
  end

  defp run_with_timeout(executable, args, cwd, env, :infinity) do
    System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 1}
  end

  defp run_with_timeout(executable, args, cwd, env, timeout) when is_integer(timeout) do
    task =
      Task.async(fn ->
        try do
          System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true)
        rescue
          e -> {Exception.message(e), 1}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"", :timeout}
      {:exit, reason} -> {"task exited: #{inspect(reason)}", 1}
    end
  end

  @impl true
  def spawn(%__MODULE__{}, command, args, _opts) do
    case System.find_executable(command) do
      nil ->
        {:error, :command_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, :exit_status, args: args]
          )

        {:ok, port}
    end
  end

  @impl true
  def write_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path, content) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    with {:ok, full_path} <- resolve_path(sandbox.dir, path),
         :ok <- File.mkdir_p(Path.dirname(full_path)) do
      File.write(full_path, content)
    end
  end

  @impl true
  def read_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    with {:ok, full_path} <- resolve_path(sandbox.dir, path) do
      File.read(full_path)
    end
  end

  @impl true
  def inject_env(%__MODULE__{agent_pid: pid, sandbox_id: sid}, env) do
    sandbox = Agent.get(pid, fn state -> Map.get(state, sid) end)

    if sandbox do
      Agent.update(pid, fn state ->
        update_in(state, [sid, :env], &stringify_env(&1, env))
      end)

      :ok
    else
      {:error, :no_sandbox}
    end
  end

  defp stringify_env(existing, env) do
    (existing || %{})
    |> Map.merge(env)
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @impl true
  def destroy(%__MODULE__{agent_pid: pid}, sandbox_id) do
    sandbox = Agent.get(pid, fn state -> Map.get(state, sandbox_id) end)
    if sandbox, do: File.rm_rf(sandbox.dir)
    Agent.update(pid, fn state -> Map.delete(state, sandbox_id) end)
    :ok
  end

  @impl true
  def impl_module, do: __MODULE__

  defp resolve_path(workspace_dir, path) do
    case Path.safe_relative(path, workspace_dir) do
      {:ok, relative_path} -> {:ok, Path.join(workspace_dir, relative_path)}
      :error -> {:error, {:unsafe_path, path}}
    end
  end

  defp warn_once do
    unless :persistent_term.get(@warning_key, false) do
      :persistent_term.put(@warning_key, true)
      Logger.warning(String.trim(@warning_message))
    end
  end
end
