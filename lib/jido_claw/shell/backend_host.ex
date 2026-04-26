defmodule JidoClaw.Shell.BackendHost do
  @moduledoc """
  Host backend for jido_shell that executes real system commands.

  Uses Erlang `Port` for streaming output and real process execution.
  Integrates with jido_shell's session model for CWD/env persistence,
  command history, and the subscribe/transport streaming protocol.

  ## Protocol

  The session server calls `execute/4` which spawns a Task that:
  1. Opens a Port running `sh -c <command>` with the session's CWD and env
  2. Streams `{:command_event, {:output, chunk}}` to `session_pid`
  3. Sends `{:command_finished, {:ok, exit_code}}` on completion
  """

  @behaviour Jido.Shell.Backend

  alias Jido.Shell.Backend.OutputLimiter

  @default_task_supervisor Jido.Shell.CommandTaskSupervisor

  # -- Backend callbacks ------------------------------------------------------

  @impl true
  def init(config) when is_map(config) do
    case Map.fetch(config, :session_pid) do
      {:ok, pid} when is_pid(pid) ->
        {:ok,
         %{
           session_pid: pid,
           task_supervisor: Map.get(config, :task_supervisor, @default_task_supervisor),
           cwd: Map.get(config, :cwd, File.cwd!()),
           env: Map.get(config, :env, %{})
         }}

      _ ->
        {:error, :missing_session_pid}
    end
  end

  @impl true
  def execute(state, command, args, exec_opts) when is_binary(command) and is_list(args) do
    line = command_line(command, args)
    cwd = Keyword.get(exec_opts, :dir, state.cwd)
    env = Keyword.get(exec_opts, :env, state.env)
    timeout = Keyword.get(exec_opts, :timeout, 30_000)
    # Explicit `:output_limit` always wins (e.g. SessionManager's SSH
    # cap) so the streaming-aware default doesn't shadow callers that
    # already know what they want.
    output_limit = Keyword.get(exec_opts, :output_limit, max_output_bytes(exec_opts))

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           run_command(state.session_pid, line, cwd, env, timeout, output_limit)
         end) do
      {:ok, task_pid} ->
        {:ok, task_pid, %{state | cwd: cwd, env: env}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Visible for testing. The streaming branch honors the test-only
  # config override so overflow tests don't have to generate megabytes
  # of output. Non-streaming is fixed at 50 KB to keep existing
  # overflow-test expectations stable.
  def max_output_bytes(opts) do
    if Keyword.get(opts, :streaming, false) do
      Application.get_env(:jido_claw, :test_streaming_max_output_bytes_override) ||
        10_000_000
    else
      50_000
    end
  end

  @impl true
  def cancel(_state, command_ref) when is_pid(command_ref) do
    if Process.alive?(command_ref) do
      Process.exit(command_ref, :shutdown)
    end

    :ok
  end

  def cancel(_state, _ref), do: {:error, :invalid_command_ref}

  @impl true
  def terminate(_state), do: :ok

  @impl true
  def cwd(state), do: {:ok, state.cwd, state}

  @impl true
  def cd(state, path) when is_binary(path) do
    # Resolve relative paths against current cwd
    resolved =
      if Path.type(path) == :absolute do
        path
      else
        Path.expand(path, state.cwd)
      end

    if File.dir?(resolved) do
      {:ok, %{state | cwd: resolved}}
    else
      {:error, :not_a_directory}
    end
  end

  # -- Private: command execution ---------------------------------------------

  defp run_command(session_pid, line, cwd, env, timeout, output_limit) do
    # Validate cwd exists
    effective_cwd =
      if File.dir?(cwd) do
        cwd
      else
        File.cwd!()
      end

    port_env =
      Enum.map(env, fn {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      end)

    port =
      Port.open({:spawn, "sh -c #{shell_escape(line)}"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, effective_cwd},
        {:env, port_env}
      ])

    result = collect_port_output(port, session_pid, timeout, output_limit, 0)
    send(session_pid, {:command_finished, result})
  rescue
    error ->
      send(session_pid, {:command_finished, {:error, Exception.message(error)}})
  end

  defp collect_port_output(port, session_pid, timeout, output_limit, bytes_sent) do
    receive do
      {^port, {:data, chunk}} ->
        case OutputLimiter.check(byte_size(chunk), bytes_sent, output_limit) do
          {:ok, new_total} ->
            send(session_pid, {:command_event, {:output, chunk}})
            collect_port_output(port, session_pid, timeout, output_limit, new_total)

          {:limit_exceeded, %Jido.Shell.Error{} = error} ->
            # Don't emit the over-limit chunk (matches SSH/Local
            # behavior). The error context already carries the byte
            # accounting (`emitted_bytes`, `max_output_bytes`).
            catch_port_close(port)
            {:error, error}
        end

      {^port, {:exit_status, exit_code}} ->
        send(session_pid, {:command_event, {:exit_status, exit_code}})
        {:ok, exit_code}
    after
      timeout ->
        catch_port_close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp catch_port_close(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    # Drain remaining messages
    receive do
      {^port, _} -> :ok
    after
      100 -> :ok
    end
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp command_line(command, []), do: command
  defp command_line(command, args), do: Enum.join([command | args], " ")
end
