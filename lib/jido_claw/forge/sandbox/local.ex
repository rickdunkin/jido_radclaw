defmodule JidoClaw.Forge.Sandbox.Local do
  use Agent
  @behaviour JidoClaw.Forge.Sandbox.Behaviour

  defstruct [:agent_pid, :sandbox_id]

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def create(spec) do
    sandbox_id = "fake_#{:erlang.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "forge_sandbox_#{sandbox_id}")
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
      Map.put(state, sandbox_id, %{dir: dir, env: Map.get(spec, "env", %{})})
    end)

    client = %__MODULE__{agent_pid: agent_pid, sandbox_id: sandbox_id}
    {:ok, client, sandbox_id}
  end

  @impl true
  def exec(%__MODULE__{agent_pid: pid, sandbox_id: sid} = _client, command, _opts) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!(), env: %{}}

    env = Enum.map(sandbox.env, fn {k, v} -> {to_string(k), to_string(v)} end)

    try do
      {output, code} =
        System.cmd("sh", ["-c", command],
          cd: sandbox.dir,
          env: env,
          stderr_to_stdout: true
        )

      {output, code}
    rescue
      e -> {Exception.message(e), 1}
    end
  end

  @impl true
  def run(%__MODULE__{} = client, agent_type, args, _opts) do
    case System.find_executable(agent_type) do
      nil ->
        {"#{agent_type}: command not found", 127}

      executable ->
        # Split args on "--" to get only the passthrough args
        passthrough =
          case Enum.split_while(args, &(&1 != "--")) do
            {_before, ["--" | rest]} -> rest
            {all, []} -> all
          end

        exec(client, "#{executable} #{Enum.join(passthrough, " ")}", [])
    end
  end

  @impl true
  def spawn(%__MODULE__{} = _client, command, args, _opts) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(command)},
        [:binary, :exit_status, args: args]
      )

    {:ok, port}
  end

  @impl true
  def write_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path, content) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    full_path = if String.starts_with?(path, "/"), do: path, else: Path.join(sandbox.dir, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    :ok
  end

  @impl true
  def read_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    full_path = if String.starts_with?(path, "/"), do: path, else: Path.join(sandbox.dir, path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def inject_env(%__MODULE__{agent_pid: pid, sandbox_id: sid}, env) do
    sandbox = Agent.get(pid, fn state -> Map.get(state, sid) end)

    if sandbox do
      Agent.update(pid, fn state ->
        update_in(state, [sid, :env], fn existing ->
          merged = Map.merge(existing || %{}, env)
          Map.new(merged, fn {k, v} -> {to_string(k), to_string(v)} end)
        end)
      end)

      :ok
    else
      {:error, :no_sandbox}
    end
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
end
