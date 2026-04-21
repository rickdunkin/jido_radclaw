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

  @doc """
  Drop `keys_to_drop` and merge `new_overlay` into both the host and
  VFS session's `state.env` for `workspace_id`. Atomic across both
  sessions — on VFS failure after host has succeeded, host is rolled
  back to its pre-call env.

  Returns `:ok` (possibly a no-op when no sessions exist).
  """
  @spec update_env(String.t(), [String.t()], map()) ::
          :ok
          | {:error, :host_update_failed, term()}
          | {:error, :vfs_update_failed, :ok | :stuck, term()}
  def update_env(workspace_id, keys_to_drop, new_overlay)
      when is_binary(workspace_id) and is_list(keys_to_drop) and is_map(new_overlay) do
    do_update_env(workspace_id, keys_to_drop, new_overlay, [])
  end

  @doc false
  # Internal test-injection seam: `:host_writer` and `:vfs_writer` opts
  # default to `&Jido.Shell.ShellSession.update_env/2`; tests override
  # the VFS writer to induce a post-host failure and assert rollback.
  @spec do_update_env(String.t(), [String.t()], map(), keyword()) ::
          :ok
          | {:error, :host_update_failed, term()}
          | {:error, :vfs_update_failed, :ok | :stuck, term()}
  def do_update_env(workspace_id, keys_to_drop, new_overlay, opts) do
    GenServer.call(
      __MODULE__,
      {:update_env, workspace_id, keys_to_drop, new_overlay, opts}
    )
  end

  @doc false
  # Test seam — reads the host session's `state.env` for inspection in
  # rollback tests. Returns `{:ok, env}` | `{:error, :no_session}`.
  @spec __host_env_for_test__(String.t()) :: {:ok, map()} | {:error, term()}
  def __host_env_for_test__(workspace_id) do
    GenServer.call(__MODULE__, {:host_env_for_test, workspace_id})
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

  @impl true
  def handle_call(
        {:update_env, workspace_id, keys_to_drop, new_overlay, opts},
        _from,
        state
      ) do
    reply = do_update_env_impl(workspace_id, keys_to_drop, new_overlay, opts, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:host_env_for_test, workspace_id}, _from, state) do
    reply =
      case Map.get(state.sessions, workspace_id) do
        %{host: host_id} -> read_env(host_id)
        nil -> {:error, :no_session}
      end

    {:reply, reply, state}
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
    initial_env = profile_env(workspace_id)

    with {:ok, _ws_pid} <- JidoClaw.VFS.Workspace.ensure_started(workspace_id, project_dir),
         {:ok, host_id} <- start_host_session(workspace_id, project_dir, initial_env),
         {:ok, vfs_id} <- start_vfs_session(workspace_id, host_id, initial_env) do
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

  # Read the ProfileManager-owned ETS mirror directly to avoid a
  # SessionManager → ProfileManager GenServer call. Without this, the
  # PM → SM → PM path (PM.switch calls SM.update_env while SM.run
  # calls PM.active_env for a fresh session) forms a mutual-call
  # cycle that can deadlock both sides. Falls back to %{} when the
  # table isn't present — e.g. isolated unit tests that start SM
  # standalone, or a test PM started without `ets_mirror: true`.
  #
  # Tuple shape is `{key, profile_name, env}` so PM.current/1 can read
  # the same rows without a GenServer hop; we only need the env here.
  defp profile_env(workspace_id) do
    table = JidoClaw.Shell.ProfileManager.ets_table()

    case :ets.whereis(table) do
      :undefined ->
        %{}

      _ref ->
        case :ets.lookup(table, workspace_id) do
          [{^workspace_id, _name, overlay}] ->
            overlay

          [] ->
            case :ets.lookup(table, :__default__) do
              [{:__default__, _name, env}] -> env
              [] -> %{}
            end
        end
    end
  end

  defp start_host_session(workspace_id, project_dir, env) do
    ShellSession.start(workspace_id,
      session_id: workspace_id <> ":host",
      cwd: project_dir,
      env: env,
      backend: {JidoClaw.Shell.BackendHost, %{}}
    )
  end

  defp start_vfs_session(workspace_id, host_id_for_cleanup, env) do
    case ShellSession.start(workspace_id,
           session_id: workspace_id <> ":vfs",
           cwd: "/project",
           env: env,
           backend: {Jido.Shell.Backend.Local, %{}}
         ) do
      {:ok, session_id} ->
        {:ok, session_id}

      {:error, _} = error ->
        _ = ShellSession.stop(host_id_for_cleanup)
        error
    end
  end

  # -- update_env flow -------------------------------------------------------

  defp do_update_env_impl(workspace_id, keys_to_drop, new_overlay, opts, state) do
    host_writer = Keyword.get(opts, :host_writer, &ShellSession.update_env/2)
    vfs_writer = Keyword.get(opts, :vfs_writer, &ShellSession.update_env/2)

    case Map.get(state.sessions, workspace_id) do
      nil ->
        :ok

      %{host: host_id, vfs: vfs_id} ->
        with {:ok, host_pre} <- read_env(host_id),
             {:ok, vfs_pre} <- read_env(vfs_id) do
          host_new = apply_drop_merge(host_pre, keys_to_drop, new_overlay)
          vfs_new = apply_drop_merge(vfs_pre, keys_to_drop, new_overlay)

          case host_writer.(host_id, host_new) do
            {:ok, _} ->
              case vfs_writer.(vfs_id, vfs_new) do
                {:ok, _} ->
                  :ok

                {:error, reason} ->
                  # Host already mutated; roll back to host_pre.
                  rollback = rollback_host(host_writer, host_id, host_pre)
                  {:error, :vfs_update_failed, rollback, reason}
              end

            {:error, reason} ->
              {:error, :host_update_failed, reason}
          end
        else
          {:error, reason} -> {:error, :host_update_failed, reason}
        end
    end
  end

  defp read_env(session_id) do
    case ShellSessionServer.get_state(session_id) do
      {:ok, %{env: env}} -> {:ok, env}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_drop_merge(env, keys_to_drop, overlay) do
    env
    |> Map.drop(keys_to_drop)
    |> Map.merge(overlay)
  end

  defp rollback_host(writer, host_id, host_pre) do
    case writer.(host_id, host_pre) do
      {:ok, _} -> :ok
      {:error, _} -> :stuck
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
    # v0.5.1: `check_allowlist_or_extension/1` admits registry-extension
    # commands and `help`, and `check_extension_only_or_paths_mount/2`
    # short-circuits when the whole program is extension/help (no workspace
    # paths to validate). Baseline sandbox commands still flow through the
    # existing absolute-path mount check.
    with {:ok, parsed} <- Jido.Shell.Command.Parser.parse_program(command),
         :ok <- check_allowlist_or_extension(parsed),
         :ok <- check_no_metachars(command),
         :ok <- check_extension_only_or_paths_mount(parsed, workspace_id) do
      :vfs
    else
      _ -> :host
    end
  end

  defp check_allowlist_or_extension(parsed) do
    # Re-read extras on every call: test suites (and any future runtime
    # extender) mutate `:extra_commands` with `put_env`, so a cached
    # snapshot would go stale.
    extension_names = extension_command_names()
    allowed = MapSet.union(MapSet.new(@sandbox_allowlist), extension_names)

    if Enum.all?(parsed, fn %{command: cmd} -> MapSet.member?(allowed, cmd) end) do
      :ok
    else
      :fallback_to_host
    end
  end

  defp extension_command_names do
    # Use `Registry.extra_commands/0` (extras minus built-in-shadowed keys)
    # so a consumer that registers under a built-in name — which
    # `Registry.commands/0` correctly overrides with the built-in — does
    # not cause the classifier to skip the absolute-path mount check for
    # that now-built-in-backed command. `help` is added explicitly because
    # it's a built-in that doesn't touch workspace paths.
    Jido.Shell.Command.Registry.extra_commands()
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.put("help")
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

  # v0.5.1: if every parsed command is an extension or `help`, skip the
  # absolute-path mount check — those commands don't touch the workspace
  # filesystem, so there are no paths to validate.
  defp check_extension_only_or_paths_mount(parsed, workspace_id) do
    extension_names = extension_command_names()

    if Enum.all?(parsed, fn %{command: cmd} -> MapSet.member?(extension_names, cmd) end) do
      :ok
    else
      check_all_absolute_paths_mount(parsed, workspace_id)
    end
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
