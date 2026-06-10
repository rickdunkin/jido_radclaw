defmodule JidoClaw.Forge do
  @moduledoc """
  Public API for the Forge subsystem — sandboxed execution of agent sessions.

  Forge manages long-running sessions that run commands and iterations inside
  isolated sandboxes (local or Docker). This module exposes session lifecycle
  (`start_session/2`, `wake/1`, `stop_session/2`), control (`run_iteration/2`,
  `exec/3`, `apply_input/2`), and sandbox attachment helpers delegating to the
  `Manager`, `Harness`, and `Persistence` collaborators.
  """

  alias JidoClaw.Forge.{Harness, Manager, Persistence}

  defmodule SessionHandle do
    @moduledoc false
    defstruct [:session_id, :pid]

    @type t :: %__MODULE__{session_id: String.t(), pid: pid() | nil}
  end

  @spec start_session(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_session(session_id, spec) when is_binary(session_id) and is_map(spec) do
    Manager.start_session(session_id, spec)
  end

  @spec get_handle(String.t()) :: {:ok, SessionHandle.t()} | {:error, term()}
  def get_handle(session_id) do
    case Manager.get_session_cluster(session_id) do
      {:ok, pid} -> {:ok, %SessionHandle{session_id: session_id, pid: pid}}
      error -> error
    end
  end

  @spec wake(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wake(session_id, opts \\ []) do
    with db_session when not is_nil(db_session) <- find_session_for_wake(session_id, opts),
         true <- db_session.phase not in [:completed, :cancelled],
         checkpoint when not is_nil(checkpoint) <- Persistence.latest_checkpoint(session_id) do
      spec =
        db_session.spec
        |> Map.put(:resume_checkpoint_id, checkpoint.id)
        |> Map.put(:tenant_id, db_session.tenant_id)
        |> Map.put(:workspace_id, db_session.workspace_id)

      Manager.start_session(session_id, spec)
    else
      nil -> {:error, :no_checkpoint}
      false -> {:error, :session_terminal}
    end
  end

  @spec stop_session(String.t(), term()) :: :ok | {:error, :not_found}
  def stop_session(session_id, reason \\ :normal) do
    Manager.stop_session(session_id, reason)
  end

  @spec list_sessions() :: [String.t()]
  def list_sessions, do: Manager.list_sessions()

  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(session_id), do: Harness.status(session_id)

  @spec run_iteration(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_iteration(session_id, opts \\ []) do
    Harness.run_iteration(session_id, opts)
  end

  @spec exec(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def exec(session_id, command, opts \\ []) do
    Harness.exec(session_id, command, opts)
  end

  @spec cmd(SessionHandle.t(), String.t(), [term()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def cmd(%SessionHandle{session_id: sid}, command, args, opts \\ []) when is_list(args) do
    escaped = Enum.map_join(args, " ", &shell_escape/1)
    full_command = "#{command} #{escaped}"
    exec(sid, full_command, opts)
  end

  @spec apply_input(String.t(), term()) :: :ok | {:error, term()}
  def apply_input(session_id, input) do
    Harness.apply_input(session_id, input)
  end

  @spec attach_sandbox(String.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  def attach_sandbox(session_id, name, sandbox_spec)
      when is_atom(name) and is_map(sandbox_spec) do
    Harness.attach_sandbox(session_id, name, sandbox_spec)
  end

  @spec detach_sandbox(String.t(), atom()) :: :ok | {:error, term()}
  def detach_sandbox(session_id, name) when is_atom(name) do
    Harness.detach_sandbox(session_id, name)
  end

  @spec run_loop(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
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

  defp find_session_for_wake(session_id, []), do: Persistence.find_session(session_id)
  defp find_session_for_wake(session_id, opts), do: Persistence.find_session(session_id, opts)
end
