defmodule JidoClaw.VFS.Workspace do
  @moduledoc """
  Per-workspace VFS state: owns the mount table for a given workspace_id and
  bootstraps the default `/project` mount plus any config-declared mounts.

  Semantics:

    * The default `/project -> Local(project_dir)` mount is **fail-fast**.
      If it cannot be established the workspace init errors out —
      without `/project` the VFS session has no useful state.

    * All other (`vfs.mounts` in `.jido/config.yaml`) mounts are
      **fail-soft**: a failure in any one mount is logged and skipped,
      and the rest of the workspace continues to come up. Some
      `jido_vfs` adapters (e.g. `Jido.VFS.Adapter.Git`) can raise from
      `configure/1`, so the mount call is wrapped in `try/rescue` for
      non-default mounts only.

    * `MountTable` state is global ETS keyed by `workspace_id`. Tests must
      use unique workspace_ids and call `teardown/1` on exit to avoid
      cross-contamination.
  """

  use GenServer
  require Logger

  alias Jido.Shell.VFS

  @registry JidoClaw.VFS.WorkspaceRegistry
  @supervisor JidoClaw.VFS.WorkspaceSupervisor

  # -- Public API -------------------------------------------------------------

  @doc """
  Idempotently start a workspace for `workspace_id` bootstrapped from
  `project_dir`. If the workspace is already running with the same
  `project_dir`, returns `{:ok, pid}` without re-running bootstrap.

  If the stored `project_dir` differs from the incoming one, the workspace
  is torn down and rebuilt against the new `project_dir` — and any shell
  sessions held by `JidoClaw.Shell.SessionManager` for the workspace are
  dropped first so the mount table, host cwd, and VFS cwd never disagree.
  """
  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(workspace_id, project_dir)
      when is_binary(workspace_id) and is_binary(project_dir) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] ->
        # The registry entry may be stale — a previous teardown could have
        # terminated the process milliseconds ago and the Registry cleanup
        # is asynchronous. Wrap the call so a dead pid falls through to
        # start_fresh/2 rather than crashing the caller.
        try do
          case GenServer.call(pid, :get_project_dir) do
            {:ok, ^project_dir} ->
              {:ok, pid}

            {:ok, old} ->
              Logger.warning(
                "[VFS.Workspace] project_dir drift for #{workspace_id}: " <>
                  "#{old} -> #{project_dir}; " <>
                  "rebuilding workspace and invalidating shell sessions"
              )

              :ok = invalidate_shell_sessions(workspace_id)
              :ok = teardown(workspace_id)
              start_fresh(workspace_id, project_dir)
          end
        catch
          :exit, _reason ->
            # Stale registry entry. `start_fresh/2` clears lingering
            # mount-table state before re-starting the workspace.
            start_fresh(workspace_id, project_dir)
        end

      [] ->
        start_fresh(workspace_id, project_dir)
    end
  end

  defp start_fresh(workspace_id, project_dir) do
    # Clear any stale mount-table entries that may have outlived a prior
    # workspace process — e.g. a process killed without going through
    # `teardown/1`. Mounts are global ETS keyed by `workspace_id`, so a
    # fresh workspace init will hit `{:vfs, :already_exists}` on `/project`
    # without this. No-op when there's nothing to clear.
    _ = VFS.unmount_workspace(workspace_id)

    spec = %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [[workspace_id: workspace_id, project_dir: project_dir]]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Drop any live shell sessions SessionManager is holding for this
  # workspace. Returns :ok without doing anything in two cases:
  #
  #   1. SessionManager isn't running (nothing to invalidate).
  #   2. We're *inside* the SessionManager GenServer — calling back in via
  #      GenServer.call would be a self-call and deadlock. This happens when
  #      `SessionManager.start_new_session/3` itself invokes `ensure_started/2`
  #      for a workspace that was previously bootstrapped by a file tool
  #      with a different project_dir. SessionManager's own drift branch in
  #      `ensure_session/3` already tears down its sessions before reaching
  #      this point; if we got here from the `nil`-entry branch of
  #      `ensure_session/3`, there are no sessions for this workspace_id
  #      in SessionManager's state and the call would be a no-op anyway.
  defp invalidate_shell_sessions(workspace_id) do
    case Process.whereis(JidoClaw.Shell.SessionManager) do
      nil ->
        :ok

      pid when pid == self() ->
        :ok

      _pid ->
        JidoClaw.Shell.SessionManager.drop_sessions(workspace_id)
    end
  end

  @doc "Returns mounts for `workspace_id` via `Jido.Shell.VFS.list_mounts/1`."
  @spec mounts(String.t()) :: [Jido.Shell.VFS.Mount.t()]
  def mounts(workspace_id), do: VFS.list_mounts(workspace_id)

  @doc """
  Config-driven mount API. Translates a user-facing adapter key
  (`:local`, `:in_memory`, `:github`, `:s3`, `:git`) + opts map into the
  real `jido_vfs` adapter option shape, then calls `Jido.Shell.VFS.mount/4`.

  Non-default mounts are fail-soft: any raise or `{:error, _}` is logged and
  the function returns `:ok` anyway so the workspace bootstrap keeps going.
  """
  @spec mount(String.t(), String.t(), atom(), map() | keyword()) :: :ok | {:error, term()}
  def mount(workspace_id, path, adapter_key, user_opts) do
    GenServer.call(via(workspace_id), {:mount, path, adapter_key, user_opts})
  end

  @doc "Unmount everything in `workspace_id` and stop the workspace GenServer."
  @spec teardown(String.t()) :: :ok
  def teardown(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] ->
        _ = VFS.unmount_workspace(workspace_id)
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      [] ->
        _ = VFS.unmount_workspace(workspace_id)
        :ok
    end
  end

  # -- GenServer --------------------------------------------------------------

  @doc false
  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    GenServer.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    project_dir = Keyword.fetch!(opts, :project_dir)

    with :ok <- mount_default_project(workspace_id, project_dir) do
      _ = mount_from_config(workspace_id, project_dir)

      {:ok,
       %{
         workspace_id: workspace_id,
         project_dir: project_dir
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:mount, path, adapter_key, user_opts}, _from, state) do
    result = do_mount(state.workspace_id, path, adapter_key, user_opts, fail_soft?: true)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_project_dir, _from, state) do
    {:reply, {:ok, state.project_dir}, state}
  end

  # -- Default mount ----------------------------------------------------------

  defp mount_default_project(workspace_id, project_dir) do
    case to_adapter_spec(:local, %{"path" => project_dir}) do
      {:ok, {adapter, adapter_opts}} ->
        case VFS.mount(workspace_id, "/project", adapter, adapter_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, {:default_mount_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:default_mount_failed, reason}}
    end
  end

  # -- Config-driven mounts ---------------------------------------------------

  defp mount_from_config(workspace_id, project_dir) do
    config = JidoClaw.Config.load(project_dir)

    config
    |> get_in(["vfs", "mounts"])
    |> List.wrap()
    |> Enum.each(fn entry ->
      path = Map.get(entry, "path") || Map.get(entry, :path)
      adapter = Map.get(entry, "adapter") || Map.get(entry, :adapter)

      cond do
        not is_binary(path) or path == "" ->
          Logger.warning("[VFS.Workspace] Skipping mount with invalid path: #{inspect(entry)}")

        adapter in [nil, ""] ->
          Logger.warning("[VFS.Workspace] Skipping mount #{path}: missing :adapter key")

        true ->
          adapter_key = adapter |> to_string() |> String.to_atom()
          _ = do_mount(workspace_id, path, adapter_key, entry, fail_soft?: true)
      end
    end)
  end

  # -- Adapter translation + mount --------------------------------------------

  defp do_mount(workspace_id, path, adapter_key, user_opts, fail_soft?: soft?) do
    with {:ok, {adapter, adapter_opts}} <- to_adapter_spec(adapter_key, user_opts) do
      do_vfs_mount(workspace_id, path, adapter, adapter_opts, soft?)
    else
      {:error, reason} ->
        log_mount_warning(path, adapter_key, reason)
        if soft?, do: :ok, else: {:error, reason}
    end
  end

  defp do_vfs_mount(workspace_id, path, adapter, adapter_opts, soft?) do
    try do
      case VFS.mount(workspace_id, path, adapter, adapter_opts) do
        :ok ->
          maybe_hint_github(path, adapter_opts)
          :ok

        {:error, reason} ->
          log_mount_warning(path, adapter, reason)
          if soft?, do: :ok, else: {:error, reason}
      end
    rescue
      e ->
        log_mount_warning(path, adapter, Exception.message(e))
        if soft?, do: :ok, else: {:error, Exception.message(e)}
    end
  end

  defp log_mount_warning(path, adapter, reason) do
    Logger.warning(
      "[VFS.Workspace] Mount #{path} (#{inspect(adapter)}) failed: #{inspect(reason)}"
    )
  end

  defp maybe_hint_github(_path, _opts), do: :ok

  # Translation table: config key -> {module, opts for Jido.Shell.VFS.mount/4}
  defp to_adapter_spec(:local, user_opts) do
    case fetch_string(user_opts, "path") do
      nil -> {:error, :local_missing_path}
      path -> {:ok, {Jido.VFS.Adapter.Local, [prefix: path]}}
    end
  end

  defp to_adapter_spec(:in_memory, user_opts) do
    name =
      fetch_string(user_opts, "name") ||
        "jido_claw_inmem_#{System.unique_integer([:positive])}"

    {:ok, {Jido.VFS.Adapter.InMemory, [name: name]}}
  end

  defp to_adapter_spec(:github, user_opts) do
    owner = fetch_string(user_opts, "owner")
    repo = fetch_string(user_opts, "repo")
    ref = fetch_string(user_opts, "ref") || "main"

    cond do
      owner in [nil, ""] -> {:error, :github_missing_owner}
      repo in [nil, ""] -> {:error, :github_missing_repo}
      true -> {:ok, {Jido.VFS.Adapter.GitHub, github_opts(owner, repo, ref)}}
    end
  end

  defp to_adapter_spec(:s3, user_opts) do
    case fetch_string(user_opts, "bucket") do
      nil ->
        {:error, :s3_missing_bucket}

      bucket ->
        region =
          fetch_string(user_opts, "region") ||
            System.get_env("AWS_REGION") ||
            Application.get_env(:ex_aws, :region, "us-east-1")

        {:ok, {Jido.VFS.Adapter.S3, [bucket: bucket, config: [region: region]]}}
    end
  end

  defp to_adapter_spec(:git, user_opts) do
    case fetch_string(user_opts, "path") do
      nil -> {:error, :git_missing_path}
      path -> {:ok, {Jido.VFS.Adapter.Git, [path: path]}}
    end
  end

  defp to_adapter_spec(other, _opts) do
    {:error, {:unknown_adapter, other}}
  end

  defp github_opts(owner, repo, ref) do
    base = [owner: owner, repo: repo, ref: ref]

    case System.get_env("GITHUB_TOKEN") do
      nil -> base
      "" -> base
      token -> Keyword.put(base, :auth, %{access_token: token})
    end
  end

  defp fetch_string(opts, key) when is_map(opts) do
    case Map.get(opts, key) || Map.get(opts, to_existing_atom_safe(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp fetch_string(opts, key) when is_list(opts) do
    case Keyword.get(opts, to_existing_atom_safe(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp to_existing_atom_safe(s) when is_atom(s), do: s

  defp to_existing_atom_safe(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :__no_such_atom__
  end

  defp via(workspace_id), do: {:via, Registry, {@registry, workspace_id}}
end
