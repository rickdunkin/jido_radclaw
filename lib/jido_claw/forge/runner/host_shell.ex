defmodule JidoClaw.Forge.Runner.HostShell do
  @moduledoc """
  Non-isolated Forge backend that executes commands as the host OS user.

  This backend exists for local development and tests. It creates a per-run
  working directory, but it does not provide filesystem, process, network, user,
  cgroup, seccomp, chroot, or namespace isolation. Use
  `JidoClaw.Forge.Sandbox.Docker` when Forge execution needs a real sandbox.
  """

  # Runner backend boundary: every bare rescue wraps a `System.cmd`/`Port`
  # call and must always return the Behaviour-required `{output, status}`
  # tuple so the caller (Forge runner) gets a well-formed result regardless
  # of what posix/erlang error the host shell throws.
  # reach:disable-for-this-file bare_rescue

  use Agent

  @behaviour JidoClaw.Forge.Sandbox.Behaviour

  require Logger

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Forge.Sandbox
  alias JidoClaw.Security.Redaction.Env

  defstruct [:agent_pid, :sandbox_id]

  @warning_key {__MODULE__, :warning_emitted}
  @warning_message """
  [Forge.HostShell] Forge is using the host shell backend. Commands run as the \
  current OS user and are not sandboxed. Set FORGE_SANDBOX=docker for the Docker \
  sandbox backend when running untrusted workloads.
  """

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    warn_once()
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
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

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec(%__MODULE__{agent_pid: pid, sandbox_id: sid}, command, _opts) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!(), env: %{}}

    env = Env.scrubbed_cmd_env(sandbox.env)

    try do
      case shell_path() do
        nil ->
          {"sh: command not found", 127}

        sh ->
          # OsCmd (vs the previous raw System.cmd) gets this path the
          # output cap and the process-tree kill behind it.
          case OsCmd.run(sh, ["-c", ulimit_prelude() <> command],
                 cd: sandbox.dir,
                 env: env,
                 timeout: :infinity
               ) do
            {output, :output_limit} -> {output, Sandbox.output_limit_exit_status()}
            {output, status} when is_integer(status) -> {output, status}
          end
      end
    rescue
      e -> {Exception.message(e), 1}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec_argv(%__MODULE__{agent_pid: pid, sandbox_id: sid}, command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {"#{command}: command not found", 127}

      executable ->
        sandbox =
          Agent.get(pid, fn state -> Map.get(state, sid) end) ||
            %{dir: System.tmp_dir!(), env: %{}}

        env = Env.scrubbed_cmd_env(sandbox.env)
        timeout = Keyword.get(opts, :timeout, :infinity)

        run_with_timeout(executable, args, sandbox.dir, env, timeout)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def run(%__MODULE__{agent_pid: pid, sandbox_id: sid}, agent_type, args, opts) do
    case System.find_executable(agent_type) do
      nil ->
        {"#{agent_type}: command not found", 127}

      executable ->
        sandbox =
          Agent.get(pid, fn state -> Map.get(state, sid) end) ||
            %{dir: System.tmp_dir!(), env: %{}}

        env = Env.scrubbed_cmd_env(sandbox.env)
        timeout = Keyword.get(opts, :timeout, :infinity)

        passthrough =
          case Enum.split_while(args, &(&1 != "--")) do
            {_before, ["--" | rest]} -> rest
            {all, []} -> all
          end

        run_with_timeout(executable, passthrough, sandbox.dir, env, timeout)
    end
  end

  defp run_with_timeout(executable, args, cwd, env, timeout) do
    # OsCmd kills the whole OS process tree on timeout — a brutally
    # killed Task only reaped the BEAM side and orphaned the real
    # command (and any grandchildren it forked). It also caps output
    # (mapped to exit 153 here, partial output preserved for
    # debuggability) and accepts `:infinity`, so the previous raw
    # System.cmd no-timeout clause is gone.
    {exec, exec_args} = apply_ulimits(executable, args)

    case OsCmd.run(exec, exec_args, cd: cwd, env: env, timeout: timeout) do
      {_partial, :timeout} -> {"", :timeout}
      {output, :output_limit} -> {output, Sandbox.output_limit_exit_status()}
      {output, status} -> {output, status}
    end
  rescue
    e -> {Exception.message(e), 1}
  end

  # Resolve the POSIX shell used for `exec/3` command strings and the
  # ulimit wrapper — PATH first, then /bin/sh directly (robust to weird
  # PATH environments; find_executable on an absolute path checks that
  # file itself). nil when neither resolves.
  defp shell_path do
    System.find_executable("sh") || System.find_executable("/bin/sh")
  end

  # Opt-in resource limits (default off — both keys unset): `ulimit -t`
  # (CPU seconds, portable) and `ulimit -v` (virtual memory KB, enforced
  # on Linux; macOS accepts but does not enforce it). Only validated
  # positive integers are ever interpolated, and each limit is
  # best-effort (`|| true`) — a shell that rejects it must not abort the
  # command.
  defp ulimit_prelude do
    [
      {"-t", positive_int_config(:forge_ulimit_cpu_seconds)},
      {"-v", positive_int_config(:forge_ulimit_virtual_memory_kb)}
    ]
    |> Enum.reject(fn {_flag, value} -> is_nil(value) end)
    |> Enum.map_join(fn {flag, value} -> "ulimit #{flag} #{value} 2>/dev/null || true; " end)
  end

  defp positive_int_config(key) do
    case Application.get_env(:jido_claw, key) do
      value when is_integer(value) and value > 0 -> value
      _unset_or_invalid -> nil
    end
  end

  # Wraps an argv in a shell that applies the ulimit prelude and then
  # `exec`s the real command: `"$0" "$@"` keeps the argv out of the
  # shell string entirely (no escaping), and `exec` replaces the shell
  # so the rlimits land on the command's own process — OsCmd's kill_tree
  # walks grandchildren either way. With no ulimits configured (or no
  # shell to wrap with) this is byte-identical pass-through. Public for
  # the default-off pin test.
  @doc false
  @spec apply_ulimits(String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def apply_ulimits(executable, args) do
    with prelude when prelude != "" <- ulimit_prelude(),
         sh when is_binary(sh) <- shell_path() do
      {sh, ["-c", prelude <> ~S(exec "$0" "$@"), executable | args]}
    else
      _none_configured_or_no_shell -> {executable, args}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def spawn(%__MODULE__{}, command, args, _opts) do
    case System.find_executable(command) do
      nil ->
        {:error, :command_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, :exit_status, args: args, env: Env.scrubbed_port_env()]
          )

        {:ok, port}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def write_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path, content) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    with {:ok, full_path} <- resolve_path(sandbox.dir, path),
         :ok <- File.mkdir_p(Path.dirname(full_path)) do
      File.write(full_path, content)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def read_file(%__MODULE__{agent_pid: pid, sandbox_id: sid}, path) do
    sandbox =
      Agent.get(pid, fn state -> Map.get(state, sid) end) ||
        %{dir: System.tmp_dir!()}

    with {:ok, full_path} <- resolve_path(sandbox.dir, path) do
      File.read(full_path)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
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

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def destroy(%__MODULE__{agent_pid: pid}, sandbox_id) do
    sandbox = Agent.get(pid, fn state -> Map.get(state, sandbox_id) end)
    if sandbox, do: File.rm_rf(sandbox.dir)
    Agent.update(pid, fn state -> Map.delete(state, sandbox_id) end)
    :ok
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
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
