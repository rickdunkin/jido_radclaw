defmodule JidoClaw.Forge do
  @moduledoc """
  Public API for the Forge subsystem — sandboxed execution of agent sessions.

  Forge manages long-running sessions that run commands and iterations inside
  isolated sandboxes (local or Docker). This module exposes session lifecycle
  (`start_session/2`, `wake/1`, `stop_session/2`), control (`run_iteration/2`,
  `exec/3`, `apply_input/2`), and sandbox attachment helpers delegating to the
  `Manager`, `Harness`, and `Persistence` collaborators.
  """

  alias JidoClaw.Forge.{Harness, Manager, Persistence, ReadyStart, RecoveredSpec}

  defmodule SessionHandle do
    @moduledoc false
    defstruct [:session_id, :pid]

    @type t :: %__MODULE__{session_id: String.t(), pid: pid() | nil}
  end

  @spec start_session(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_session(session_id, spec) when is_binary(session_id) and is_map(spec) do
    Manager.start_session(session_id, spec)
  end

  @doc """
  Race-safe combined start: `subscribe → start_session → await-ready →
  status-assert`, returning only once the session is `:ready` AND usable by the
  bridge, or on a bounded failure (any partial session torn down). The caller
  mints + owns `session_id` (it is the `forge_session_key`, AR-8b-2 F2 D5), so it
  always holds a handle to clean up. See `JidoClaw.Forge.ReadyStart`.
  """
  @spec start_session_ready(String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_session_ready(session_id, spec, opts \\ [])
      when is_binary(session_id) and is_map(spec) do
    ReadyStart.start(session_id, spec, opts)
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
         checkpoint when not is_nil(checkpoint) <- Persistence.latest_checkpoint(session_id),
         # AR-8b-2 F2 (1.4): a recovered spec round-trips through jsonb to string
         # keys/values; re-atomize its known fields (and fail closed on an
         # un-normalizable docker spec / invalid mount) BEFORE handing it to the
         # Manager, so a recovered `:docker_sandbox` session re-provisions the real
         # Docker backend + no-egress + mount rather than silently falling to
         # `:default` (HostShell, no isolation).
         {:ok, normalized} <- RecoveredSpec.normalize(db_session.spec) do
      spec =
        normalized
        |> Map.put(:resume_checkpoint_id, checkpoint.id)
        |> Map.put(:tenant_id, db_session.tenant_id)
        |> Map.put(:workspace_id, db_session.workspace_id)

      Manager.start_session(session_id, spec)
    else
      nil -> {:error, :no_checkpoint}
      false -> {:error, :session_terminal}
      {:error, reason} -> {:error, {:unrecoverable_spec, reason}}
    end
  end

  @spec stop_session(String.t(), term()) :: :ok | {:error, :not_found}
  def stop_session(session_id, reason \\ :normal) do
    Manager.stop_session(session_id, reason)
  end

  @doc """
  Completion-aware close (AR-8b-2 F2 1.3): land the session **`:completed`** (with
  `completed_at`) — distinct from `stop_session/2`'s `:cancelled`, so a converged
  sketch run isn't misread as cancelled. Idiomatic `/1`: "complete" always means a
  clean `:normal` close, so there is no meaningful second arg. Delegates to
  `Harness.complete/1` (a `reason: :normal` self-stop; see its docs for the
  stamp-failure → `:completed` fallback).
  """
  @spec complete_session(String.t()) :: :ok | {:error, term()}
  def complete_session(session_id) do
    Harness.complete(session_id)
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

  # Single source of truth for the Forge exec timeout cushion (AR-8b-2 F2 C3).
  #
  # Two independent consumers read this so they can never drift:
  #
  #   * `JidoClaw.Forge.Harness.exec_call_timeout/1` sizes the OUTER
  #     `GenServer.call` deadline to `inner + cushion`, so a real in-container
  #     timeout returns the backend's manufactured `{_, 124}` (which the bridge
  #     taints on) instead of an uncaught caller `:exit, {:timeout, _}`; and
  #   * `JidoClaw.Tools.RunCommand.ForgeBridge` folds it into the timeout-budget
  #     `margin` it derives from the outer `Jido.Exec` deadline, so the ordering
  #     `inner_OsCmd < harness_outer (inner + cushion) < jido_deadline` holds.
  @exec_timeout_cushion_ms 5_000

  @doc false
  @spec exec_timeout_cushion_ms() :: non_neg_integer()
  def exec_timeout_cushion_ms, do: @exec_timeout_cushion_ms

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
