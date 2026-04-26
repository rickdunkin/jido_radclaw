defmodule JidoClaw.Shell.SessionManager do
  @moduledoc """
  Manages persistent shell sessions backed by jido_shell.

  Each workspace holds **two** local sessions sharing the same VFS
  mount table, plus zero-or-more **SSH** sessions keyed by server
  name:

    * A **host** session using `JidoClaw.Shell.BackendHost`, cwd = project_dir.
      Executes real `sh -c` invocations (git, mix, pipes, redirects, …) —
      behaviour is unchanged from the pre-VFS SessionManager.

    * A **vfs** session using `Jido.Shell.Backend.Local`, cwd = `/project`.
      Runs only the jido_shell sandbox built-ins (`cat`, `ls`, `cd`, `pwd`,
      `mkdir`, `rm`, `cp`, `echo`, `write`, `env`, `bash`) and resolves all
      paths through `Jido.Shell.VFS` with the workspace's mount table.

    * **SSH** sessions using `Jido.Shell.Backend.SSH`, one per
      `{workspace_id, server_name}`. Lazily created on first
      `run/4` with `backend: :ssh, server: <name>`. Never
      auto-selected by the classifier — SSH is always explicit.

  `run/4` classifies each command and routes to the appropriate
  session. The caller can override routing with `backend: :host | :vfs`
  in opts, or request SSH via `backend: :ssh, server: <name>`.
  """

  use GenServer
  require Logger

  alias Jido.Shell.ShellSession
  alias Jido.Shell.ShellSessionServer
  alias Jido.Shell.VFS.MountTable
  alias JidoClaw.Shell.ServerRegistry
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SSHError

  @default_timeout 30_000
  @max_output_chars 10_000
  # Streaming captures echo a 50 KB preview to the agent (vs. 10 KB
  # for non-streaming) — large enough to be useful, small enough that
  # multi-MB stream into the model context can't blow it up.
  @streaming_capture_preview 50_000
  @default_connect_timeout 10_000

  # Mailbox safety valve for streaming SSH output. Separate from
  # `@max_output_chars` (the 10 KB post-hoc display-truncation cap):
  # chatty-but-finite commands still complete and truncate gracefully;
  # only genuinely runaway streams trip this limit and abort. The SSH
  # backend reads `:output_limit` from exec_opts and emits
  # `%Jido.Shell.Error{code: {:command, :output_limit_exceeded}}` when
  # exceeded, which the collector loop routes through `SSHError.format/2`.
  @max_ssh_output_bytes 1_000_000
  # Streaming SSH bumps the per-command output cap to 10 MB so a long
  # build log can render in real time. Honors a test-only override so
  # cap-overflow tests don't have to generate megabytes.
  @streaming_ssh_output_bytes 10_000_000

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

  defstruct sessions: %{}, ssh_sessions: %{}

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run a shell command in the session for `workspace_id`.

  `opts` (keyword):

    * `:project_dir` - required for dual-session bootstrap. `run/3` defaults to
      `File.cwd!/0` for legacy callers.
    * `:backend` - `:host | :vfs | :ssh | nil` — routing override. `:ssh`
      requires `:server` and bypasses the classifier.
    * `:server` - server name from `.jido/config.yaml` (required when
      `backend: :ssh`).

  Returns `{:ok, %{output: String.t(), exit_code: integer()}}` or `{:error, reason}`.

  The outer `GenServer.call/3` timeout budget is `timeout + 5_000` for
  host/VFS. For SSH the budget includes the server entry's
  `connect_timeout` (default 10s) so a slow-connecting host doesn't
  blow up the call before the backend has a chance to return its own
  start_failed error.
  """
  @spec run(String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, %{output: String.t(), exit_code: non_neg_integer()}} | {:error, term()}
  def run(workspace_id, command, timeout \\ @default_timeout, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :project_dir, &File.cwd!/0)
    call_timeout = timeout + call_timeout_extra(opts)

    GenServer.call(
      __MODULE__,
      {:run, workspace_id, command, timeout, opts},
      call_timeout
    )
  end

  # Budget on top of `timeout` for the outer GenServer call. SSH adds
  # the server's connect_timeout so a slow handshake doesn't time out
  # the caller before the backend can return `start_failed`. Reads the
  # registry on the caller side so the SessionManager handle_call
  # never blocks on ServerRegistry during routing.
  defp call_timeout_extra(opts) do
    case Keyword.get(opts, :backend) do
      :ssh ->
        server = Keyword.get(opts, :server)
        ssh_call_timeout_extra(server)

      _ ->
        5_000
    end
  end

  defp ssh_call_timeout_extra(server) when is_binary(server) do
    case server_connect_timeout(server) do
      {:ok, connect_timeout} -> connect_timeout + 5_000
      :unknown -> @default_connect_timeout + 5_000
    end
  end

  defp ssh_call_timeout_extra(_), do: @default_connect_timeout + 5_000

  defp server_connect_timeout(server) do
    case Process.whereis(ServerRegistry) do
      nil ->
        :unknown

      _pid ->
        case ServerRegistry.get(server) do
          {:ok, %ServerEntry{connect_timeout: timeout}} -> {:ok, timeout}
          {:error, _} -> :unknown
        end
    end
  catch
    :exit, _ -> :unknown
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

  @doc """
  Invalidate cached SSH sessions for the given server names across all
  workspaces. Typically called by `ServerRegistry.reload/0` callers
  after a config reload surfaces added/changed/removed server entries.

  Silently no-ops for server names without a cached session.
  """
  @spec invalidate_ssh_sessions([String.t()]) :: :ok
  def invalidate_ssh_sessions(names) when is_list(names) do
    GenServer.call(__MODULE__, {:invalidate_ssh_sessions, names})
  end

  # -- Server Callbacks -------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:run, workspace_id, command, timeout, opts}, _from, state) do
    project_dir = Keyword.fetch!(opts, :project_dir)

    case Keyword.get(opts, :backend) do
      :ssh ->
        handle_ssh_run(workspace_id, command, timeout, opts, project_dir, state)

      _ ->
        handle_local_run(workspace_id, command, timeout, opts, project_dir, state)
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
    had_local? = Map.has_key?(state.sessions, workspace_id)
    had_ssh_only? = not had_local? and workspace_has_ssh?(state.ssh_sessions, workspace_id)

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

    new_ssh = stop_all_ssh_for_workspace(state.ssh_sessions, workspace_id)

    # SSH-only workspace: still tear down the VFS workspace if the
    # caller implicitly created one (e.g. a later host session). The
    # teardown is a no-op for unknown workspaces.
    if had_ssh_only? do
      _ = JidoClaw.VFS.Workspace.teardown(workspace_id)
    end

    {:reply, :ok, %{state | sessions: new_sessions, ssh_sessions: new_ssh}}
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

    new_ssh = stop_all_ssh_for_workspace(state.ssh_sessions, workspace_id)

    {:reply, :ok, %{state | sessions: new_sessions, ssh_sessions: new_ssh}}
  end

  @impl true
  def handle_call({:invalidate_ssh_sessions, names}, _from, state) do
    targets = MapSet.new(names)

    new_ssh =
      Enum.reduce(state.ssh_sessions, %{}, fn {{_ws, server} = key, entry}, acc ->
        if MapSet.member?(targets, server) do
          _ = ShellSession.stop(entry.session_id)
          acc
        else
          Map.put(acc, key, entry)
        end
      end)

    {:reply, :ok, %{state | ssh_sessions: new_ssh}}
  end

  @impl true
  def handle_call(
        {:update_env, workspace_id, keys_to_drop, new_overlay, opts},
        _from,
        state
      ) do
    {reply, new_state} = do_update_env_impl(workspace_id, keys_to_drop, new_overlay, opts, state)
    {:reply, reply, new_state}
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

  # -- run/4 dispatch --------------------------------------------------------

  defp handle_local_run(workspace_id, command, timeout, opts, project_dir, state) do
    case ensure_session(workspace_id, project_dir, state) do
      {:ok, entry, new_state} ->
        target = resolve_target(command, workspace_id, opts)
        session_id = Map.fetch!(entry, target)

        result =
          with_optional_stream(
            session_id,
            opts,
            &execute_command(session_id, command, timeout, &1, opts)
          )

        {:reply, result, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, "Shell session could not be started: #{inspect(reason)}"}, new_state}
    end
  end

  defp handle_ssh_run(workspace_id, command, timeout, opts, project_dir, state) do
    server = Keyword.get(opts, :server)

    cond do
      not is_binary(server) or server == "" ->
        {:reply, {:error, "SSH requires :server option"}, state}

      true ->
        case ensure_ssh_session(workspace_id, server, project_dir, state) do
          {:ok, session_id, entry, new_state} ->
            result =
              with_optional_stream(session_id, opts, fn streaming? ->
                execute_ssh_command(session_id, command, timeout, entry, streaming?, opts)
              end)

            {:reply, result, new_state}

          {:error, message, new_state} ->
            {:reply, {:error, message}, new_state}
        end
    end
  end

  # Wrap a run with the Display stream lifecycle (start_stream → run →
  # end_stream). Falls back to a non-streaming run if Display is gone
  # or refuses the registration. The `streaming?` flag is passed
  # through to the inner function so it can size caps and finalize
  # output appropriately.
  #
  # Display.end_stream/1 is a cast — the real correctness guarantee
  # comes from Display unsubscribing inside the collector after the
  # final terminal event lands. The cast only flips `end_requested?`.
  defp with_optional_stream(session_id, opts, fun) do
    if Keyword.get(opts, :stream_to_display) == true do
      case start_display_stream(session_id, opts) do
        {:ok, display_pid} ->
          try do
            fun.(true)
          after
            JidoClaw.Display.end_stream(session_id)
            _ = Jido.Shell.ShellSessionServer.unsubscribe(session_id, display_pid)
          end

        :no_stream ->
          fun.(false)
      end
    else
      fun.(false)
    end
  end

  defp start_display_stream(session_id, opts) do
    agent_id = Keyword.get(opts, :agent_id, "main")
    tool_name = Keyword.get(opts, :tool_name, "run_command")

    case GenServer.whereis(JidoClaw.Display) do
      nil ->
        :no_stream

      display_pid ->
        case JidoClaw.Display.start_stream(session_id, agent_id, tool_name) do
          :ok ->
            case ShellSessionServer.subscribe(session_id, display_pid) do
              {:ok, :subscribed} ->
                {:ok, display_pid}

              {:error, reason} ->
                Logger.debug(
                  "[SessionManager] Display subscribe failed for #{session_id}: #{inspect(reason)}"
                )

                JidoClaw.Display.abort_stream(session_id)
                :no_stream
            end

          {:error, reason} ->
            Logger.debug(
              "[SessionManager] Display.start_stream rejected for #{session_id}: #{inspect(reason)}"
            )

            :no_stream
        end
    end
  catch
    :exit, _ -> :no_stream
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

  # -- SSH session lifecycle -------------------------------------------------

  # Fast path: existing session, same project_dir, still alive.
  # Otherwise: look up the server entry, resolve secrets + key path,
  # compose effective env, start a fresh SSH session. All error
  # branches render through `SSHError.format/2` so callers see a
  # user-facing string, never a raw `%Jido.Shell.Error{}`.
  defp ensure_ssh_session(workspace_id, server_name, project_dir, state) do
    key = {workspace_id, server_name}

    case Map.get(state.ssh_sessions, key) do
      %{
        session_id: session_id,
        project_dir: ^project_dir,
        server_entry: entry
      } ->
        if session_alive?(session_id) do
          {:ok, session_id, entry, state}
        else
          _ = ShellSession.stop(session_id)
          cleared = %{state | ssh_sessions: Map.delete(state.ssh_sessions, key)}
          build_ssh_session(workspace_id, server_name, project_dir, cleared)
        end

      %{session_id: session_id, project_dir: existing_dir} ->
        Logger.debug(
          "[SessionManager] SSH project_dir drift for #{workspace_id}/#{server_name}: " <>
            "#{existing_dir} -> #{project_dir}; rebuilding"
        )

        _ = ShellSession.stop(session_id)
        cleared = %{state | ssh_sessions: Map.delete(state.ssh_sessions, key)}
        build_ssh_session(workspace_id, server_name, project_dir, cleared)

      nil ->
        build_ssh_session(workspace_id, server_name, project_dir, state)
    end
  end

  defp build_ssh_session(workspace_id, server_name, project_dir, state) do
    with {:ok, entry} <- lookup_server(server_name),
         {:ok, _secrets} <- resolve_server_secrets(entry),
         effective_env = Map.merge(entry.env, profile_env(workspace_id)),
         {:ok, ssh_config} <- ServerRegistry.build_ssh_config(entry, project_dir, effective_env),
         session_id = ssh_session_id(workspace_id, server_name),
         {:ok, session_id} <- start_ssh_session(workspace_id, session_id, entry, ssh_config) do
      cache_entry = %{
        session_id: session_id,
        server_entry: entry,
        project_dir: project_dir
      }

      new_state = %{
        state
        | ssh_sessions: Map.put(state.ssh_sessions, {workspace_id, server_name}, cache_entry)
      }

      {:ok, session_id, entry, new_state}
    else
      {:error, :server_not_found} ->
        {:error, "SSH server '#{server_name}' not declared in .jido/config.yaml", state}

      {:error, {:missing_env, _} = reason} ->
        fake_entry = fake_entry_for_error(server_name)
        {:error, SSHError.format(reason, fake_entry), state}

      {:error, %Jido.Shell.Error{} = err, entry} ->
        {:error, SSHError.format(err, entry), state}

      {:error, %Jido.Shell.Error{} = err} ->
        {:error, SSHError.format(err, fake_entry_for_error(server_name)), state}

      {:error, reason} ->
        {:error, "SSH session start failed: #{inspect(reason)}", state}
    end
  end

  defp lookup_server(server_name) do
    case ServerRegistry.get(server_name) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :server_not_found}
    end
  catch
    :exit, _ -> {:error, :server_not_found}
  end

  defp resolve_server_secrets(entry) do
    case ServerRegistry.resolve_secrets(entry) do
      {:ok, secrets} -> {:ok, secrets}
      {:error, _} = error -> error
    end
  end

  defp start_ssh_session(workspace_id, session_id, entry, ssh_config) do
    case ShellSession.start(workspace_id,
           session_id: session_id,
           cwd: entry.cwd,
           env: Map.get(ssh_config, :env, %{}),
           backend: {Jido.Shell.Backend.SSH, ssh_config}
         ) do
      {:ok, sid} ->
        {:ok, sid}

      {:error, {:shutdown, %Jido.Shell.Error{} = err}} ->
        {:error, err, entry}

      {:error, %Jido.Shell.Error{} = err} ->
        {:error, err, entry}

      {:error, {:already_started, _}} ->
        # A previous collapse left the session alive — reuse it.
        {:ok, session_id}

      {:error, reason} ->
        {:error, "SSH session start failed: #{inspect(reason)}"}
    end
  end

  defp ssh_session_id(workspace_id, server_name) do
    workspace_id <> ":ssh:" <> server_name
  end

  # Used only when we hit an error *before* we have a real ServerEntry
  # to interpolate — `{:missing_env, var}` happens during secret
  # resolution, but the error message only needs the name, so a stub
  # entry is fine.
  defp fake_entry_for_error(server_name) do
    %ServerEntry{
      name: server_name,
      host: "",
      user: "",
      port: 0,
      auth_kind: :default,
      cwd: "/",
      env: %{},
      shell: "sh",
      connect_timeout: @default_connect_timeout
    }
  end

  defp stop_all_ssh_for_workspace(ssh_sessions, workspace_id) do
    Enum.reduce(ssh_sessions, %{}, fn {{ws, _server} = key, entry}, acc ->
      if ws == workspace_id do
        _ = ShellSession.stop(entry.session_id)
        acc
      else
        Map.put(acc, key, entry)
      end
    end)
  end

  defp workspace_has_ssh?(ssh_sessions, workspace_id) do
    Enum.any?(ssh_sessions, fn {{ws, _}, _} -> ws == workspace_id end)
  end

  # -- update_env flow -------------------------------------------------------

  # Handles host+VFS atomic drop+merge (existing behavior) **and** SSH
  # full-env replace (new in v0.5.3). Returns `{reply, new_state}`.
  # SSH writes run best-effort: a failure evicts that session from
  # the cache and logs a warning, never rolls the host+VFS update
  # back (which has already succeeded).
  #
  # SSH-only workspaces (no host+VFS): host/VFS step is skipped
  # entirely and we only apply SSH env updates.
  defp do_update_env_impl(workspace_id, keys_to_drop, new_overlay, opts, state) do
    host_writer = Keyword.get(opts, :host_writer, &ShellSession.update_env/2)
    vfs_writer = Keyword.get(opts, :vfs_writer, &ShellSession.update_env/2)
    ssh_writer = Keyword.get(opts, :ssh_writer, &ShellSession.update_env/2)

    has_ssh = Enum.any?(state.ssh_sessions, fn {{ws, _}, _} -> ws == workspace_id end)

    case Map.get(state.sessions, workspace_id) do
      nil when not has_ssh ->
        {:ok, state}

      nil ->
        # SSH-only workspace — no host/VFS to update.
        new_state = apply_ssh_env_update(workspace_id, new_overlay, ssh_writer, state)
        {:ok, new_state}

      %{host: host_id, vfs: vfs_id} ->
        case apply_host_vfs_update(
               host_id,
               vfs_id,
               keys_to_drop,
               new_overlay,
               host_writer,
               vfs_writer
             ) do
          :ok ->
            new_state = apply_ssh_env_update(workspace_id, new_overlay, ssh_writer, state)
            {:ok, new_state}

          other ->
            # Host/VFS failed (or rolled back) — leave SSH sessions alone.
            {other, state}
        end
    end
  end

  defp apply_host_vfs_update(host_id, vfs_id, keys_to_drop, new_overlay, host_writer, vfs_writer) do
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

  # `new_overlay` is the fully composed target profile env (default +
  # active profile overrides) — *not* a delta. For SSH we recompose
  # effective env from scratch: server-declared vars overlaid with
  # the new profile env. Full-env replace (no drop+merge) because we
  # can always recompute the target deterministically — dropping
  # server-declared vars that overlap with the old profile would
  # violate the "server invariants survive a profile switch" guarantee.
  defp apply_ssh_env_update(workspace_id, new_overlay, ssh_writer, state) do
    entries_for_workspace =
      Enum.filter(state.ssh_sessions, fn {{ws, _}, _} -> ws == workspace_id end)

    Enum.reduce(entries_for_workspace, state, fn {{_ws, server} = key, entry}, acc ->
      effective_env = Map.merge(entry.server_entry.env, new_overlay)

      case ssh_writer.(entry.session_id, effective_env) do
        {:ok, _} ->
          acc

        {:error, reason} ->
          Logger.warning(
            "[SessionManager] SSH env update failed for #{workspace_id}/#{server}: " <>
              "#{inspect(reason)} — evicting cache entry"
          )

          _ = ShellSession.stop(entry.session_id)
          %{acc | ssh_sessions: Map.delete(acc.ssh_sessions, key)}
      end
    end)
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
    case Keyword.get(opts, :backend) do
      target when target in [:host, :vfs] -> target
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

  defp execute_command(session_id, command, timeout, streaming?, opts) do
    case ShellSessionServer.subscribe(session_id, self()) do
      {:ok, :subscribed} -> :ok
      {:error, reason} -> throw({:subscribe_failed, reason})
    end

    drain_events(session_id)

    run_opts = local_run_opts(streaming?, opts)

    result =
      case ShellSessionServer.run_command(session_id, command, run_opts) do
        {:ok, :accepted} ->
          case collect_output(session_id, timeout, streaming?) do
            {:timeout, _partial} ->
              # Cancel so the session isn't left busy
              _ = ShellSessionServer.cancel(session_id)
              drain_events(session_id)
              {:error, "Command timed out after #{timeout}ms"}

            other ->
              other
          end

        {:error, reason} ->
          # Run rejected — no events will fire. Force-drop the
          # Display registration so it doesn't leak; the outer
          # try/after's end_stream cast becomes a no-op.
          if streaming?, do: JidoClaw.Display.abort_stream(session_id)
          {:error, "Command rejected: #{inspect(reason)}"}
      end

    _ = ShellSessionServer.unsubscribe(session_id, self())
    result
  catch
    {:subscribe_failed, reason} ->
      if streaming?, do: JidoClaw.Display.abort_stream(session_id)
      {:error, "Could not subscribe to session: #{inspect(reason)}"}
  end

  # Local/VFS limit threading: `Backend.Local` drops `:output_limit`,
  # so streaming-mode caps land in `execution_context.limits` —
  # that's where the patched ShellSessionServer reads them. Host
  # backend sees both `:streaming` (for its own internal cap function)
  # and `:execution_context.limits.max_output_bytes` (passes through).
  defp local_run_opts(false, _opts), do: []

  defp local_run_opts(true, _opts) do
    cap = streaming_local_max_output_bytes()

    [
      streaming: true,
      execution_context: %{limits: %{max_output_bytes: cap}}
    ]
  end

  defp streaming_local_max_output_bytes do
    Application.get_env(:jido_claw, :test_streaming_max_output_bytes_override) ||
      10_000_000
  end

  defp collect_output(session_id, timeout, streaming?) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(session_id, deadline, [], 0, streaming?)
  end

  defp do_collect(session_id, deadline, acc, exit_code, streaming?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      {:timeout, finalize_output(acc, streaming?)}
    else
      receive do
        {:jido_shell_session, ^session_id, {:output, chunk}} ->
          do_collect(session_id, deadline, [chunk | acc], exit_code, streaming?)

        {:jido_shell_session, ^session_id, {:exit_status, code}} ->
          do_collect(session_id, deadline, acc, code, streaming?)

        {:jido_shell_session, ^session_id, :command_done} ->
          {:ok, %{output: finalize_output(acc, streaming?), exit_code: exit_code}}

        {:jido_shell_session, ^session_id,
         {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}} = error}} ->
          # Output cap exceeded mid-stream. Surface the error directly
          # so callers can react (e.g. RunCommand can render the
          # streamed preview alongside the cap-overflow message).
          preview = finalize_output(acc, streaming?)
          new_context = Map.put(error.context || %{}, :preview, preview)
          {:error, %{error | context: new_context}}

        {:jido_shell_session, ^session_id, {:error, _error}} ->
          {:ok, %{output: finalize_output(acc, streaming?), exit_code: max(exit_code, 1)}}

        {:jido_shell_session, ^session_id, :command_cancelled} ->
          {:error, "Command was cancelled"}

        {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
          {:error, "Command crashed: #{inspect(reason)}"}

        # Ignore lifecycle events (command_started, cwd_changed)
        {:jido_shell_session, ^session_id, _other} ->
          do_collect(session_id, deadline, acc, exit_code, streaming?)
      after
        remaining ->
          {:timeout, finalize_output(acc, streaming?)}
      end
    end
  end

  # SSH-specific execute path: subscribe, run, collect, unsubscribe.
  # Uses `do_collect_ssh/5` which preserves remote non-zero exit codes
  # (a normal success-but-failed outcome, unlike host/VFS where
  # `{:command, :exit_code}` is treated as opaque error) and routes
  # timeouts/output-limit-exceeded through `SSHError.format/2`.
  defp execute_ssh_command(session_id, command, timeout, entry, streaming?, _opts) do
    case ShellSessionServer.subscribe(session_id, self()) do
      {:ok, :subscribed} -> :ok
      {:error, reason} -> throw({:subscribe_failed, reason})
    end

    drain_events(session_id)

    result =
      case ShellSessionServer.run_command(session_id, command,
             output_limit: ssh_output_limit(streaming?)
           ) do
        {:ok, :accepted} ->
          case collect_ssh_output(session_id, timeout, entry, streaming?) do
            {:timeout, _partial} ->
              _ = ShellSessionServer.cancel(session_id)
              drain_events(session_id)
              {:error, "SSH to #{entry.name} command timed out after #{timeout}ms"}

            other ->
              other
          end

        {:error, reason} ->
          # Run rejected — no events will fire. Force-drop the
          # Display registration so it doesn't leak; the outer
          # try/after's end_stream cast becomes a no-op.
          if streaming?, do: JidoClaw.Display.abort_stream(session_id)
          {:error, SSHError.format(reason, entry)}
      end

    _ = ShellSessionServer.unsubscribe(session_id, self())
    result
  catch
    {:subscribe_failed, reason} ->
      if streaming?, do: JidoClaw.Display.abort_stream(session_id)
      {:error, "Could not subscribe to SSH session: #{inspect(reason)}"}
  end

  defp ssh_output_limit(false), do: @max_ssh_output_bytes

  defp ssh_output_limit(true) do
    Application.get_env(:jido_claw, :test_streaming_max_output_bytes_override) ||
      @streaming_ssh_output_bytes
  end

  defp collect_ssh_output(session_id, timeout, entry, streaming?) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_ssh(session_id, deadline, [], 0, entry, streaming?)
  end

  defp do_collect_ssh(session_id, deadline, acc, exit_code, entry, streaming?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining <= 0 do
      {:timeout, finalize_output(acc, streaming?)}
    else
      receive do
        {:jido_shell_session, ^session_id, {:output, chunk}} ->
          do_collect_ssh(session_id, deadline, [chunk | acc], exit_code, entry, streaming?)

        {:jido_shell_session, ^session_id, {:exit_status, code}} ->
          do_collect_ssh(session_id, deadline, acc, code, entry, streaming?)

        {:jido_shell_session, ^session_id, :command_done} ->
          {:ok, %{output: finalize_output(acc, streaming?), exit_code: exit_code}}

        # Remote non-zero exit — surfaced by the SSH backend as an
        # Error struct but semantically a successful command completion
        # with a non-zero code. Preserve the code so the caller sees
        # `{:ok, %{exit_code: <n>}}` instead of a terminal error.
        {:jido_shell_session, ^session_id,
         {:error, %Jido.Shell.Error{code: {:command, :exit_code}, context: %{code: code}}}} ->
          {:ok, %{output: finalize_output(acc, streaming?), exit_code: code}}

        # Output cap exceeded mid-stream — surface the structured
        # error with preview folded into context so callers (RunCommand)
        # can render the streamed preview alongside the cap message.
        {:jido_shell_session, ^session_id,
         {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}} = error}} ->
          preview = finalize_output(acc, streaming?)
          new_context = Map.put(error.context || %{}, :preview, preview)
          {:error, %{error | context: new_context}}

        # Timeout / start_failed / other command errors — terminal
        # failure; format via SSHError.
        {:jido_shell_session, ^session_id, {:error, %Jido.Shell.Error{} = error}} ->
          {:error, SSHError.format(error, entry)}

        {:jido_shell_session, ^session_id, {:error, reason}} ->
          {:error, SSHError.format(reason, entry)}

        {:jido_shell_session, ^session_id, :command_cancelled} ->
          {:error, "Command was cancelled"}

        {:jido_shell_session, ^session_id, {:command_crashed, reason}} ->
          {:error, "Command crashed: #{inspect(reason)}"}

        {:jido_shell_session, ^session_id, _other} ->
          do_collect_ssh(session_id, deadline, acc, exit_code, entry, streaming?)
      after
        remaining ->
          {:timeout, finalize_output(acc, streaming?)}
      end
    end
  end

  defp finalize_output(acc, streaming?) do
    output = acc |> Enum.reverse() |> Enum.join()
    cap = if streaming?, do: @streaming_capture_preview, else: @max_output_chars

    if byte_size(output) > cap do
      note =
        if streaming?,
          do: "\n... (output truncated; full output streamed live)\n",
          else: "\n... (output truncated)"

      truncate_utf8(output, cap) <> note
    else
      output
    end
  end

  # Cut at most `cap` bytes from `binary` along a UTF-8 codepoint
  # boundary so the result is always valid UTF-8 — `binary_part/3`
  # alone can split a multibyte codepoint and break JSON/tool-result
  # encoding for otherwise normal output.
  defp truncate_utf8(binary, cap) do
    raw = binary_part(binary, 0, cap)

    case :unicode.characters_to_binary(raw) do
      bin when is_binary(bin) -> bin
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp drain_events(session_id) do
    receive do
      {:jido_shell_session, ^session_id, _} -> drain_events(session_id)
    after
      0 -> :ok
    end
  end
end
