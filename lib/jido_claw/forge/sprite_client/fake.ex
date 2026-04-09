defmodule JidoClaw.Forge.SpriteClient.Fake do
  use Agent
  @behaviour JidoClaw.Forge.SpriteClient.Behaviour

  defstruct [:agent_pid]

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def create(spec) do
    sprite_id = "fake_#{:erlang.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "forge_sprite_#{sprite_id}")
    File.mkdir_p!(dir)

    agent_pid = case Process.whereis(__MODULE__) do
      nil ->
        {:ok, pid} = Agent.start_link(fn -> %{} end)
        pid
      pid -> pid
    end

    Agent.update(agent_pid, fn state ->
      Map.put(state, sprite_id, %{dir: dir, env: Map.get(spec, "env", %{})})
    end)

    client = %__MODULE__{agent_pid: agent_pid}
    {:ok, client, sprite_id}
  end

  @impl true
  def exec(%__MODULE__{agent_pid: pid} = _client, command, _opts) do
    sprites = Agent.get(pid, & &1)
    {_id, sprite} = Enum.at(sprites, 0) || {nil, %{dir: System.tmp_dir!(), env: %{}}}

    env = Enum.map(sprite.env, fn {k, v} -> {to_string(k), to_string(v)} end)

    try do
      {output, code} = System.cmd("sh", ["-c", command],
        cd: sprite.dir,
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
    port = Port.open({:spawn_executable, System.find_executable(command)},
      [:binary, :exit_status, args: args])
    {:ok, port}
  end

  @impl true
  def write_file(%__MODULE__{agent_pid: pid}, path, content) do
    sprites = Agent.get(pid, & &1)
    {_id, sprite} = Enum.at(sprites, 0) || {nil, %{dir: System.tmp_dir!()}}

    full_path = if String.starts_with?(path, "/"), do: path, else: Path.join(sprite.dir, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    :ok
  end

  @impl true
  def read_file(%__MODULE__{agent_pid: pid}, path) do
    sprites = Agent.get(pid, & &1)
    {_id, sprite} = Enum.at(sprites, 0) || {nil, %{dir: System.tmp_dir!()}}

    full_path = if String.starts_with?(path, "/"), do: path, else: Path.join(sprite.dir, path)
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def inject_env(%__MODULE__{agent_pid: pid}, env) do
    sprites = Agent.get(pid, & &1)
    {id, _sprite} = Enum.at(sprites, 0) || {nil, nil}

    if id do
      Agent.update(pid, fn state ->
        update_in(state, [id, :env], fn existing ->
          merged = Map.merge(existing || %{}, env)
          Map.new(merged, fn {k, v} -> {to_string(k), to_string(v)} end)
        end)
      end)
      :ok
    else
      {:error, :no_sprite}
    end
  end

  @impl true
  def destroy(%__MODULE__{agent_pid: pid}, sprite_id) do
    sprite = Agent.get(pid, fn state -> Map.get(state, sprite_id) end)
    if sprite, do: File.rm_rf(sprite.dir)
    Agent.update(pid, fn state -> Map.delete(state, sprite_id) end)
    :ok
  end

  @impl true
  def impl_module, do: __MODULE__
end
