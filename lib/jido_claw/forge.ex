defmodule JidoClaw.Forge do
  alias JidoClaw.Forge.{Manager, Harness, Persistence}

  defmodule SessionHandle do
    defstruct [:session_id, :pid]
  end

  def start_session(session_id, spec) when is_binary(session_id) and is_map(spec) do
    Manager.start_session(session_id, spec)
  end

  def get_handle(session_id) do
    case Manager.get_session(session_id) do
      {:ok, pid} -> {:ok, %SessionHandle{session_id: session_id, pid: pid}}
      error -> error
    end
  end

  def wake(session_id) do
    with db_session when not is_nil(db_session) <- Persistence.find_session(session_id),
         true <- db_session.phase not in [:completed, :cancelled],
         checkpoint when not is_nil(checkpoint) <- Persistence.latest_checkpoint(session_id) do
      spec =
        db_session.spec
        |> Map.put(:resume_checkpoint_id, checkpoint.id)

      Manager.start_session(session_id, spec)
    else
      nil -> {:error, :no_checkpoint}
      false -> {:error, :session_terminal}
    end
  end

  def stop_session(session_id, reason \\ :normal) do
    Manager.stop_session(session_id, reason)
  end

  def list_sessions, do: Manager.list_sessions()

  def status(session_id), do: Harness.status(session_id)

  def run_iteration(session_id, opts \\ []) do
    Harness.run_iteration(session_id, opts)
  end

  def exec(session_id, command, opts \\ []) do
    Harness.exec(session_id, command, opts)
  end

  def cmd(%SessionHandle{session_id: sid}, command, args, opts \\ []) when is_list(args) do
    escaped = Enum.map_join(args, " ", &shell_escape/1)
    full_command = "#{command} #{escaped}"
    exec(sid, full_command, opts)
  end

  def apply_input(session_id, input) do
    Harness.apply_input(session_id, input)
  end

  def attach_sandbox(session_id, name, sandbox_spec) when is_atom(name) and is_map(sandbox_spec) do
    Harness.attach_sandbox(session_id, name, sandbox_spec)
  end

  def detach_sandbox(session_id, name) when is_atom(name) do
    Harness.detach_sandbox(session_id, name)
  end

  def run_loop(session_id, opts \\ []) do
    max = Keyword.get(opts, :max_iterations, 50)
    do_run_loop(session_id, opts, 0, max)
  end

  defp do_run_loop(_session_id, _opts, iteration, max) when iteration >= max do
    {:ok, :max_iterations_reached}
  end

  defp do_run_loop(session_id, opts, iteration, max) do
    case run_iteration(session_id, opts) do
      {:ok, %{status: :done} = result} -> {:ok, result}
      {:ok, %{status: :needs_input}} -> {:ok, :needs_input}
      {:ok, %{status: :blocked}} -> {:ok, :blocked}
      {:ok, %{status: :error} = result} -> {:error, result}
      {:ok, %{status: :continue}} -> do_run_loop(session_id, opts, iteration + 1, max)
      {:error, reason} -> {:error, reason}
    end
  end

  defp shell_escape(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp shell_escape(arg), do: shell_escape(to_string(arg))
end
