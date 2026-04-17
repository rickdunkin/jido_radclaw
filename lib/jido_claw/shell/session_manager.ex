defmodule JidoClaw.Shell.SessionManager do
  @moduledoc """
  Manages persistent shell sessions backed by jido_shell.

  Each workspace holds **two** sessions sharing the same VFS mount table:

    * A **host** session using `JidoClaw.Shell.BackendHost`, cwd = project_dir.
      Executes real `sh -c` invocations (git, mix, pipes, redirects, …) —
      behaviour is unchanged from the pre-VFS SessionManager.

    * A **vfs** session using `Jido.Shell.Backend.Local`, cwd = `/project`.
      Runs only the jido_shell sandbox built-ins (`cat`, `ls`, `cd`, `pwd`,
      `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`) and resolves all
      paths through `Jido.Shell.VFS` with the workspace's mount table.

  `run/4` classifies each command and routes to the appropriate session.
  The caller can force routing with `force: :host | :vfs` in opts.
  """

  use GenServer
  require Logger

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS.MountTable

  @default_timeout 30_000
  @max_output_chars 10_000

  @sandbox_allowlist ~w(cat ls cd pwd mkdir rm cp echo write env bash)

  # Token-level shell metacharacters that the jido_shell parser doesn't model.
  # Any command whose token set intersects this forces host routing.
  @host_forcing_tokens MapSet.new(~w(| || > >> < & 2>&1))

  # Characters that indicate an unmodelled shell operator fused onto another
  # token (e.g. `cat x|head`, `cat x>out`, `foo&bar`). `&&` chains are still
  # acceptable because the rest of the command clears the classifier, so it
  # is carved out in `check_no_metachars/1` below. `;` is deliberately absent:
  # `Jido.Shell.Command.Parser.parse_program/1` already splits on `;`, so a
  # token-embedded `;` means the parser produced multiple clean commands.
  @embedded_forcing_chars ["|", ">", "<", "`", "$(", "${", "&"]

  defstruct sessions: %{}

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run a shell command in the session for `workspace_id`.

  `opts` (keyword):

    * `:project_dir` - required for dual-session bootstrap. `run/3` defaults to
      `File.cwd!/0` for legacy callers.
    * `:force` - `:host | :vfs | nil` — bypass the classifier. Defaults to nil.

  Returns `{:ok, %{output: String.t(), exit_code: integer()}}` or `{:error, reason}`.
  """
  @spec run(String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: non_neg_integer()}} | {:error, term()}
  def run(workspace_id, command, timeout \\ @default_timeout, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :project_dir, &File.cwd!/0)

    GenServer.call(
      __MODULE__,
      {:run, workspace_id, command, timeout, opts},
      timeout + 5_000
    )
  end

  @doc "Return the current working directory for a workspace session (host cwd)."
  @spec cwd(String.t()) :: {:ok, String.t()} | {:error, :no_session}
  def cwd(workspace_id), do: cwd(workspace_id, :host)

  @doc "Return the current working directory for a workspace session (:host or :vfs)."
  @spec cwd(String.t(), :host | :vfs) :: {:ok, String.t()} | {:error, :no_session}
  def cwd(workspace_id, which) when which in [:host, :vfs] do
    GenServer.call(__MODULE__, {:cwd, workspace_id, which})
  end

  @doc """
  Stop and discard the sessions for `workspace_id` and tear down its VFS workspace.
  """
  @spec stop_session(String.t()) :: :ok
  def stop_session(workspace_id) do
    GenServer.call(__MODULE__, {:stop_session, workspace_id})
  end

  @doc """
  Stop and forget the shell sessions for `workspace_id` without tearing down
  the VFS workspace. Used by `JidoClaw.VFS.Workspace.ensure_started/2` on
  drift — the workspace is already being rebuilt by the caller, so this
  avoids the SessionManager → Workspace → SessionManager re-entry loop.
  """
  @spec drop_sessions(String.t()) :: :ok
  def drop_sessions(workspace_id) do
    GenServer.call(__MODULE__, {:drop_sessions, workspace_id})
  end

  # -- Server Callbacks -------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:run, workspace_id, command, timeout, opts}, _from, state) do
    project_dir = Keyword.fetch!(opts, :project_dir)

    case ensure_session(workspace_id, project_dir, state) do
      {:ok, entry, new_state} ->
        target = resolve_target(command, workspace_id, opts)
        session_id = Map.fetch!(entry, target)
        result = execute_command(session_id, command, timeout)
        {:reply, result, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, "Shell session could not be started: #{inspect(reason)}"}, new_state}
    end
  end

  @impl true
  def handle_call({:cwd, workspace_id, which}, _from, state) do
    reply =
      case Map.get(state.sessions, workspace_id) do
        nil ->
          {:error, :no_session}

        %{^which => session_id} ->
          case ShellSessionServer.get_state(session_id) do
            {:ok, session_state} -> {:ok, session_state.cwd}
            {:error, _} -> {:error, :no_session}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:stop_session, workspace_id}, _from, state) do
    new_sessions =
      case Map.pop(state.sessions, workspace_id) do
        {nil, sessions} ->
          sessions

        {%{host: host_id, vfs: vfs_id}, sessions} ->
          _ = ShellSession.stop(host_id)
          _ = ShellSession.stop(vfs_id)
          _ = JidoClaw.VFS.Workspace.teardown(workspace_id)
          sessions
      end

    {:reply, :ok, %{state | sessions: new_sessions}}
  end

  @impl true
  def handle_call({:drop_sessions, workspace_id}, _from, state) do
    new_sessions =
      case Map.pop(state.sessions, workspace_id) do
        {nil, sessions} ->
          sessions

        {%{host: host_id, vfs: vfs_id}, sessions} ->
          _ = ShellSession.stop(host_id)
          _ = ShellSession.stop(vfs_id)
          sessions
      end

    {:reply, :ok, %{state | sessions: new_sessions}}
  end

  # Silently ignore stale session events that arrive outside collect loops
  @impl true
  def handle_info({:jido_shell_session, _session_id, _event}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # -- Session lifecycle ------------------------------------------------------

  defp ensure_session(workspace_id, project_dir, state) do
    case Map.get(state.sessions, workspace_id) do
      nil ->
        start_new_session(workspace_id, project_dir, state)

      %{host: host_id, vfs: vfs_id, project_dir: existing_dir} = entry ->
        cond do
          existing_dir != project_dir ->
            Logger.warning(
              "[SessionManager] project_dir drift for workspace #{workspace_id}: " <>
                "#{existing_dir} -> #{project_dir}; rebuilding sessions"
            )

            _ = ShellSession.stop(host_id)
            _ = ShellSession.stop(vfs_id)
            _ = JidoClaw.VFS.Workspace.teardown(workspace_id)
            new_state = %{state | sessions: Map.delete(state.sessions, workspace_id)}
            start_new_session(workspace_id, project_dir, new_state)

          not session_alive?(host_id) or not session_alive?(vfs_id) ->
            Logger.debug(
              "[SessionManager] Session gone for workspace #{workspace_id}, recreating"
            )

            _ = ShellSession.stop(host_id)
            _ = ShellSession.stop(vfs_id)
            _ = JidoClaw.VFS.Workspace.teardown(workspace_id)
            new_state = %{state | sessions: Map.delete(state.sessions, workspace_id)}
            start_new_session(workspace_id, project_dir, new_state)

          true ->
            {:ok, entry, state}
        end
    end
  end

  defp session_alive?(session_id) do
    match?({:ok, _pid}, ShellSession.lookup(session_id))
  end

  defp start_new_session(workspace_id, project_dir, state) do
    with {:ok, _ws_pid} <- JidoClaw.VFS.Workspace.ensure_started(workspace_id, project_dir),
         {:ok, host_id} <- start_host_session(workspace_id, project_dir),
         {:ok, vfs_id} <- start_vfs_session(workspace_id, host_id) do
      entry = %{host: host_id, vfs: vfs_id, project_dir: project_dir}
      new_state = %{state | sessions: Map.put(state.sessions, workspace_id, entry)}
      Logger.debug("[SessionManager] Started dual sessions for #{workspace_id}")
      {:ok, entry, new_state}
    else
      {:error, reason} ->
        cleanup_failed_start(workspace_id, state)

        Logger.warning(
          "[SessionManager] Failed to start sessions for #{workspace_id}: #{inspect(reason)}"
        )

        {:error, reason, state}
    end
  end

  defp start_host_session(workspace_id, project_dir) do
    ShellSession.start(workspace_id,
      session_id: workspace_id <> ":host",
      cwd: project_dir,
      backend: {JidoClaw.Shell.BackendHost, %{}}
    )
  end

  defp start_vfs_session(workspace_id, host_id_for_cleanup) do
    case ShellSession.start(workspace_id,
           session_id: workspace_id <> ":vfs",
           cwd: "/project",
           backend: {Jido.Shell.Backend.Local, %{}}
         ) do
      {:ok, session_id} ->
        {:ok, session_id}

      {:error, _} = error ->
        _ = ShellSession.stop(host_id_for_cleanup)
        error
    end
  end

  defp cleanup_failed_start(workspace_id, _state) do
    _ = ShellSession.stop(workspace_id <> ":host")
    _ = ShellSession.stop(workspace_id <> ":vfs")
    _ = JidoClaw.VFS.Workspace.teardown(workspace_id)
    :ok
  end

  # -- Classifier -------------------------------------------------------------

  defp resolve_target(command, workspace_id, opts) do
    case Keyword.get(opts, :force) do
      :host -> :host
      :vfs -> :vfs
      _ -> classify(command, workspace_id)
    end
  end

  @doc false
  def classify(command, workspace_id) do
    with {:ok, parsed} <- Jido.Shell.Command.Parser.parse_program(command),
         :ok <- check_allowlist(parsed),
         :ok <- check_no_metachars(command),
         :ok <- check_all_absolute_paths_mount(parsed, workspace_id) do
      :vfs
    else
      _ -> :host
    end
  end

  defp check_allowlist(parsed) do
    if Enum.all?(parsed, fn %{command: cmd} -> cmd in @sandbox_allowlist end) do
      :ok
    else
      :fallback_to_host
    end
  end

  defp check_no_metachars(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce_while(:ok, fn token, :ok ->
      cond do
        token == "&&" ->
          {:cont, :ok}

        MapSet.member?(@host_forcing_tokens, token) ->
          {:halt, :fallback_to_host}

        String.contains?(token, @embedded_forcing_chars) ->
          {:halt, :fallback_to_host}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check_all_absolute_paths_mount(parsed, workspace_id) do
    absolute_args =
      parsed
      |> Enum.flat_map(fn %{args: args} -> args end)
      |> Enum.filter(&String.starts_with?(&1, "/"))

    cond do
      absolute_args == [] ->
        :fallback_to_host

      Enum.all?(absolute_args, fn path ->
        match?({:ok, _, _}, MountTable.resolve(workspace_id, path))
      end) ->
        :ok

      true ->
        :fallback_to_host
    end
  end

  # -- Command execution ------------------------------------------------------

  defp execute_command(session_id, command, timeout) do
    case ShellSessionServer.subscribe(session_id, self()) do
      {:ok, :subscribed} -> :ok
      {:error, reason} -> throw({:subscribe_failed, reason})
    end

    drain_events(session_id)

    result =
      case ShellSessionServer.run_command(session_id, command) do
        {:ok, :accepted} ->
          case collect_output(session_id, timeout) do
            {:timeout, _partial} ->
              # Cancel so the session isn't left busy
              _ = ShellSessionServer.cancel(session_id)
              drain_events(session_id)
              {:error, "Command timed out after #{timeout}ms"}

            other ->
              other
          end

        {:error, reason} ->
          {:error, "Command rejected: #{inspect(reason)}"}
      end

    _ = ShellSessionServer.unsubscribe(session_id, self())
    result
  catch
    {:subscribe_failed, reason} ->
      {:error, "Could not subscribe to session: #{inspect(reason)}"}
  end

  defp collect_output(session_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(session_id, deadline, [], 0)
  end

  defp do_collect(session_id, deadline, acc, exit_code) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      {:timeout, finalize_output(acc)}
    else
      receive do
        {:jido_shell_session, ^session_id, {:output, chunk}} ->
          do_collect(session_id, deadline, [chunk | acc], exit_code)

        {:jido_shell_session, ^session_id, {:exit_status, code}} ->
          do_collect(session_id, deadline, acc, code)

        {:jido_shell_session, ^session_id, :command_done} ->
          {:ok, %{output: finalize_output(acc), exit_code: exit_code}}

        {:jido_shell_session, ^session_id, {:error, _error}} ->
          {:ok, %{output: finalize_output(acc), exit_code: max(exit_code, 1)}}

        {:jido_shell_session, ^session_id, :command_cancelled} ->
          {:error, "Command was cancelled"}

        {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
          {:error, "Command crashed: #{inspect(reason)}"}

        # Ignore lifecycle events (command_started, cwd_changed)
        {:jido_shell_session, ^session_id, _other} ->
          do_collect(session_id, deadline, acc, exit_code)
      after
        remaining ->
          {:timeout, finalize_output(acc)}
      end
    end
  end

  defp finalize_output(acc) do
    acc |> Enum.reverse() |> Enum.join() |> truncate_output()
  end

  defp drain_events(session_id) do
    receive do
      {:jido_shell_session, ^session_id, _} -> drain_events(session_id)
    after
      0 -> :ok
    end
  end

  defp truncate_output(output) when byte_size(output) > @max_output_chars do
    String.slice(output, 0, @max_output_chars) <> "\n... (output truncated)"
  end

  defp truncate_output(output), do: output
end
