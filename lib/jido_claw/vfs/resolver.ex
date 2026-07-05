defmodule JidoClaw.VFS.Resolver do
  @moduledoc """
  VFS abstraction layer that routes file operations to the appropriate backend.

  Path routing:
    * `github://owner/repo/path` — `Jido.VFS.Adapter.GitHub`
    * `s3://bucket/key`          — `Jido.VFS.Adapter.S3`
    * `git://repo-path/file`     — `Jido.VFS.Adapter.Git`
    * Absolute path under a workspace mount — `Jido.Shell.VFS.*` (requires
      `:workspace_id` opt)
    * All other paths            — local filesystem via `File.*`; when
      `:project_dir` is supplied, local paths are jailed to that directory.

  Remote paths require credentials supplied via application config or
  environment variables. If no credentials are available the operation
  returns `{:error, :credentials_required}`.

  All functions mirror the `File` module signatures for drop-in
  compatibility in tool modules.
  """

  alias Jido.Shell.VFS, as: ShellVFS
  alias Jido.Shell.VFS.MountTable
  alias Jido.VFS, as: JidoVFS
  alias JidoClaw.VFS.Workspace

  @max_symlink_depth 40

  # -- Public API -------------------------------------------------------------

  @doc """
  Read file contents.

  Returns `{:ok, binary()}` or `{:error, reason}`.

  Options:
    * `:workspace_id` — when set, absolute paths are checked against the
      workspace's VFS mount table before falling back to the local filesystem.
    * `:project_dir` — when set alongside `:workspace_id`, the workspace is
      auto-bootstrapped via `Workspace.ensure_started/2`
      before consulting the mount table. Bootstrap failures surface as
      `{:error, {:workspace_bootstrap_failed, reason}}` rather than silently
      falling through to the local filesystem.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read(path, opts \\ []) do
    with :ok <- maybe_ensure_workspace(path, opts) do
      case parse_path(path, opts, :read) do
        {:vfs, workspace_id, vfs_path} ->
          ShellVFS.read_file(workspace_id, vfs_path)

        {:local, local_path} ->
          File.read(local_path)

        {:github, owner, repo, ref, file_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref) do
            JidoVFS.read(fs, file_path)
          end

        {:s3, bucket, key} ->
          with {:ok, fs} <- s3_filesystem(bucket) do
            JidoVFS.read(fs, key)
          end

        {:git, repo_path, file_path} ->
          with {:ok, fs} <- git_filesystem(repo_path) do
            JidoVFS.read(fs, file_path)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Write content to a file, creating parent directories as needed.

  Returns `:ok` or `{:error, reason}`.

  Accepts the same `:workspace_id` / `:project_dir` opts as `read/2`.
  """
  @spec write(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write(path, content, opts \\ []) do
    with :ok <- maybe_ensure_workspace(path, opts) do
      case parse_path(path, opts, :write) do
        {:vfs, workspace_id, vfs_path} ->
          ShellVFS.write_file(workspace_id, vfs_path, content)

        {:local, local_path} ->
          local_path
          |> Path.dirname()
          |> File.mkdir_p!()

          File.write(local_path, content)

        {:github, owner, repo, ref, file_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref) do
            JidoVFS.write(fs, file_path, content)
          end

        {:s3, bucket, key} ->
          with {:ok, fs} <- s3_filesystem(bucket) do
            JidoVFS.write(fs, key, content)
          end

        {:git, repo_path, file_path} ->
          with {:ok, fs} <- git_filesystem(repo_path) do
            JidoVFS.write(fs, file_path, content)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Atomically write content to a file when the selected backend supports it.

  Local filesystem writes are staged in the destination directory and committed
  with `File.rename/2`. VFS and remote writes use the underlying `Jido.VFS`
  `write` + `move` operations on the same filesystem.
  """
  @spec atomic_write(String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def atomic_write(path, content, opts \\ []) do
    with :ok <- maybe_ensure_workspace(path, opts) do
      case parse_path(path, opts, :write) do
        {:vfs, workspace_id, vfs_path} ->
          vfs_atomic_write(workspace_id, vfs_path, content)

        {:local, local_path} ->
          local_atomic_write(local_path, content)

        {:github, owner, repo, ref, file_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref) do
            jido_vfs_atomic_write(fs, file_path, content)
          end

        {:s3, bucket, key} ->
          with {:ok, fs} <- s3_filesystem(bucket) do
            jido_vfs_atomic_write(fs, key, content)
          end

        {:git, repo_path, file_path} ->
          with {:ok, fs} <- git_filesystem(repo_path) do
            jido_vfs_atomic_write(fs, file_path, content)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  List directory contents.

  Returns `{:ok, [String.t()]}` or `{:error, reason}`.

  Accepts the same `:workspace_id` / `:project_dir` opts as `read/2`.
  """
  @spec ls(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(path, opts \\ []) do
    with :ok <- maybe_ensure_workspace(path, opts) do
      case parse_path(path, opts, :read) do
        {:vfs, workspace_id, vfs_path} ->
          with {:ok, entries} <- ShellVFS.list_dir(workspace_id, vfs_path) do
            {:ok, Enum.map(entries, & &1.name)}
          end

        {:local, local_path} ->
          File.ls(local_path)

        {:github, owner, repo, ref, dir_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref),
               {:ok, contents} <- JidoVFS.list_contents(fs, dir_path) do
            names = Enum.map(contents, & &1.name)
            {:ok, names}
          end

        {:s3, bucket, prefix} ->
          with {:ok, fs} <- s3_filesystem(bucket),
               {:ok, contents} <- JidoVFS.list_contents(fs, prefix) do
            names = Enum.map(contents, & &1.name)
            {:ok, names}
          end

        {:git, repo_path, dir_path} ->
          with {:ok, fs} <- git_filesystem(repo_path),
               {:ok, contents} <- JidoVFS.list_contents(fs, dir_path) do
            names = Enum.map(contents, & &1.name)
            {:ok, names}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns true when `path` uses a remote scheme (github://, s3://, git://).
  """
  @spec remote?(String.t()) :: boolean()
  def remote?(path) do
    String.starts_with?(path, ["github://", "s3://", "git://"])
  end

  @doc """
  Bootstrap the workspace for `path` when `:workspace_id` + `:project_dir`
  are present in `opts`. Safe to call even for remote URIs or relative
  paths — it only bootstraps for absolute local-style paths.

    * `:ok` — bootstrap not needed or succeeded.
    * `{:error, {:workspace_bootstrap_failed, reason}}` — bootstrap was
      attempted and failed. Callers routing paths conditionally should
      surface this rather than falling back to local filesystem access.

  Typical pattern:

      with :ok <- Resolver.ensure_workspace_ready(path, opts),
           true <- Resolver.under_workspace_mount?(path, opts) do
        Resolver.ls(path, opts)
      else
        false -> local_path_fallback(...)
        {:error, _} = err -> err
      end
  """
  @spec ensure_workspace_ready(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_workspace_ready(path, opts), do: maybe_ensure_workspace(path, opts)

  @doc """
  Pure predicate: returns true when `path` resolves under a mount in the
  workspace's `MountTable`. Does **not** bootstrap — callers should call
  `ensure_workspace_ready/2` first if the workspace may not yet be started.
  """
  @spec under_workspace_mount?(String.t(), keyword()) :: boolean()
  def under_workspace_mount?(path, opts) do
    with ws when is_binary(ws) and ws != "" <- Keyword.get(opts, :workspace_id),
         true <- String.starts_with?(path, "/") do
      match?({:ok, _, _}, MountTable.resolve(ws, path))
    else
      _ -> false
    end
  end

  @doc """
  Resolve a local filesystem path using the same project-dir jail as
  `read/2`, `write/3`, and `ls/2`.

  This is intended for callers that need local filesystem metadata after the
  resolver has chosen the local backend. Remote URIs and mounted VFS paths are
  not translated here.

  With `local_only: true` in `opts`, a remote-scheme `path` is rejected with
  `{:error, {:remote_forbidden_in_sandbox, path}}` rather than passed through —
  this entry point bypasses `parse_path/3`, so the gate is applied here too
  (AR-8b sketch jail).
  """
  @spec local_path(String.t(), keyword(), :read | :write) :: {:ok, String.t()} | {:error, term()}
  def local_path(path, opts \\ [], mode \\ :read) when mode in [:read, :write] do
    if local_only_violation?(path, opts) do
      {:error, {:remote_forbidden_in_sandbox, path}}
    else
      case resolve_local_path(path, opts, mode) do
        {:local, local_path} -> {:ok, local_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Workspace bootstrap ----------------------------------------------------

  # Returns :ok when bootstrap was not needed or succeeded, or
  # {:error, {:workspace_bootstrap_failed, reason}} when the caller gave us
  # enough info to bootstrap but it failed. A plain :ok lets callers proceed
  # to `parse_path/2`; an `{:error, _}` short-circuits the with-pipeline in
  # read/write/ls so we never silently fall through to `File.*`.
  defp maybe_ensure_workspace(path, opts) do
    cond do
      remote?(path) ->
        :ok

      not String.starts_with?(path, "/") ->
        :ok

      true ->
        ws = Keyword.get(opts, :workspace_id)
        pd = Keyword.get(opts, :project_dir)

        # A binary `pd` is the signal for "bootstrap intent". `""` is
        # invalid and surfaces as `:local_missing_path` rather than a
        # silent fall-through — that's how callers learn the workspace
        # isn't usable. `nil` means "no bootstrap intent, use legacy
        # mount-check behavior".
        if is_binary(ws) and ws != "" and is_binary(pd) do
          case Workspace.ensure_started(ws, pd) do
            {:ok, _pid} -> :ok
            {:error, reason} -> {:error, {:workspace_bootstrap_failed, reason}}
          end
        else
          :ok
        end
    end
  end

  # -- Path Parsing -----------------------------------------------------------

  # The funnel above the prefix-matched clauses: `read/2`, `write/3`,
  # `atomic_write/3`, and `ls/2` all route through `parse_path/3`, so the
  # `local_only:` sandbox gate (AR-8b) catches a remote scheme here before it
  # can reach any backend. `local_path/3` bypasses this funnel and re-checks
  # the same predicate at its own entry. The `{:error, _}` is already in
  # contract — every caller's `case`/`with` handles a parse error.
  defp parse_path(path, opts, mode) do
    if local_only_violation?(path, opts),
      do: {:error, {:remote_forbidden_in_sandbox, path}},
      else: do_parse_path(path, opts, mode)
  end

  # A `local_only` sandbox turn (the sketch worker) must never resolve a remote
  # scheme — the local project jail does not cover `github://`/`s3://`/`git://`.
  defp local_only_violation?(path, opts),
    do: Keyword.get(opts, :local_only, false) and remote?(path)

  # github://owner/repo[@ref]/path/to/file
  # ref defaults to "main" when omitted
  defp do_parse_path("github://" <> rest, _opts, _mode) do
    case String.split(rest, "/", parts: 3) do
      [owner_repo_ref, repo, file_path] when repo != "" ->
        {owner, ref} = split_owner_ref(owner_repo_ref)
        {:github, owner, repo, ref, file_path}

      [owner_ref, repo] when repo != "" ->
        {owner, ref} = split_owner_ref(owner_ref)
        {:github, owner, repo, ref, ""}

      _ ->
        {:error, "Invalid github:// path: github://#{rest}"}
    end
  end

  defp do_parse_path("s3://" <> rest, _opts, _mode) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] -> {:s3, bucket, key}
      [bucket] -> {:s3, bucket, ""}
      _ -> {:error, "Invalid s3:// path: s3://#{rest}"}
    end
  end

  defp do_parse_path("git://" <> rest, _opts, _mode) do
    case String.split(rest, "//", parts: 2) do
      [repo_path, file_path] -> {:git, repo_path, file_path}
      [repo_path] -> {:git, repo_path, ""}
      _ -> {:error, "Invalid git:// path: git://#{rest}"}
    end
  end

  defp do_parse_path(path, opts, mode) do
    workspace_id = Keyword.get(opts, :workspace_id)

    if is_binary(workspace_id) and workspace_id != "" and String.starts_with?(path, "/") do
      case MountTable.resolve(workspace_id, path) do
        {:ok, _mount, _rel} -> {:vfs, workspace_id, path}
        {:error, :no_mount} -> resolve_local_path(path, opts, mode)
      end
    else
      resolve_local_path(path, opts, mode)
    end
  end

  defp resolve_local_path(path, opts, mode) do
    case Keyword.fetch(opts, :project_dir) do
      {:ok, project_dir} when is_binary(project_dir) and project_dir != "" ->
        resolve_project_path(path, project_dir, mode)

      _ ->
        {:local, path}
    end
  end

  defp resolve_project_path(path, project_dir, mode) do
    expanded_root = Path.expand(project_dir)

    with {:ok, real_root} <- real_project_root(expanded_root),
         candidate <- expand_candidate(path, expanded_root),
         :ok <- ensure_under_project(candidate, expanded_root, real_root),
         :ok <- ensure_safe_project_path(candidate, expanded_root, real_root, mode) do
      {:local, candidate}
    end
  end

  defp real_project_root(expanded_root) do
    case realpath(expanded_root) do
      {:ok, real_root} -> {:ok, real_root}
      {:error, reason} -> {:error, {:invalid_project_dir, reason}}
    end
  end

  defp expand_candidate(path, project_dir) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(path, project_dir)
    end
  end

  defp ensure_safe_project_path(candidate, _expanded_root, real_root, :read) do
    case realpath(candidate) do
      {:ok, real_candidate} -> ensure_under_real_root(real_candidate, real_root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_safe_project_path(candidate, expanded_root, real_root, :write) do
    case File.lstat(candidate) do
      {:ok, _stat} ->
        with {:ok, real_candidate} <- realpath(candidate) do
          ensure_under_real_root(real_candidate, real_root)
        end

      {:error, :enoent} ->
        candidate
        |> Path.dirname()
        |> nearest_existing_ancestor(expanded_root, real_root)
        |> case do
          {:ok, ancestor} ->
            with {:ok, real_ancestor} <- realpath(ancestor) do
              ensure_under_real_root(real_ancestor, real_root)
            end

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp nearest_existing_ancestor(path, expanded_root, real_root) do
    cond do
      File.exists?(path) ->
        {:ok, path}

      under_path?(path, expanded_root) or under_path?(path, real_root) ->
        path
        |> Path.dirname()
        |> nearest_existing_ancestor(expanded_root, real_root)

      true ->
        {:error, {:path_outside_project, path}}
    end
  end

  defp ensure_under_project(candidate, expanded_root, real_root) do
    if under_path?(candidate, expanded_root) or under_path?(candidate, real_root) do
      :ok
    else
      {:error, {:path_outside_project, candidate}}
    end
  end

  defp ensure_under_real_root(real_candidate, real_root) do
    if under_path?(real_candidate, real_root) do
      :ok
    else
      {:error, {:path_outside_project, real_candidate}}
    end
  end

  @doc """
  True when `path` is at or below `root` (never an escaping `../`).

  Exposed for `JidoClaw.VFS.Sandbox`, which reuses this containment check to
  validate a `.prototypes/<uuid>/` sandbox root rather than re-implement path
  safety (AR-8b).
  """
  @spec under_path?(String.t(), String.t()) :: boolean()
  def under_path?(path, root) do
    relative = Path.relative_to(path, root)

    relative == "." or
      (relative != path and relative != ".." and not String.starts_with?(relative, "../"))
  end

  @doc """
  Fully resolve symlinks in `path` (depth-capped at `#{@max_symlink_depth}`).

  Returns `{:ok, resolved}` or `{:error, reason}`. Exposed for
  `JidoClaw.VFS.Sandbox`, which reuses this tested, depth-capped walk to
  validate a `.prototypes/<uuid>/` sandbox root rather than re-implement path
  safety (AR-8b).
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
  def realpath(path), do: realpath(path, 0)

  defp realpath(_path, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp realpath(path, depth) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_realpath_parts(depth)
  end

  defp resolve_realpath_parts(["/" | parts], depth), do: resolve_realpath_parts("/", parts, depth)
  defp resolve_realpath_parts(parts, depth), do: resolve_realpath_parts(File.cwd!(), parts, depth)

  defp resolve_realpath_parts(current, [], _depth), do: {:ok, current}

  defp resolve_realpath_parts(current, [part | rest], depth) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
          target
          |> symlink_target_path(current)
          |> join_parts(rest)
          |> realpath(depth + 1)
        end

      {:ok, _stat} ->
        resolve_realpath_parts(next, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp symlink_target_path(target, parent) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      _ -> Path.expand(target, parent)
    end
  end

  defp join_parts(path, parts), do: Enum.reduce(parts, path, &Path.join(&2, &1))

  defp split_owner_ref(owner_ref) do
    case String.split(owner_ref, "@", parts: 2) do
      [owner, ref] -> {owner, ref}
      [owner] -> {owner, "main"}
    end
  end

  defp local_atomic_write(local_path, content) do
    local_path
    |> Path.dirname()
    |> File.mkdir_p!()

    tmp_path = tmp_path_for(local_path)

    case File.write(tmp_path, content, [:binary]) do
      :ok ->
        case File.rename(tmp_path, local_path) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(tmp_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp vfs_atomic_write(workspace_id, path, content) do
    with {:ok, mount, relative_path} <- MountTable.resolve(workspace_id, path) do
      jido_vfs_atomic_write(mount.filesystem, relative_path, content)
    end
  end

  defp jido_vfs_atomic_write(filesystem, path, content) do
    tmp_path = tmp_path_for(path)

    case JidoVFS.write(filesystem, tmp_path, content) do
      :ok ->
        case JidoVFS.move(filesystem, tmp_path, path) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = JidoVFS.delete(filesystem, tmp_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tmp_path_for(path) do
    "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"
  end

  # -- Filesystem Builders ----------------------------------------------------

  defp github_filesystem(owner, repo, ref) do
    token =
      System.get_env("GITHUB_TOKEN") || Application.get_env(:jido_vfs, :github, [])[:access_token]

    auth =
      if token do
        %{access_token: token}
      else
        nil
      end

    case JidoVFS.safe_configure(JidoVFS.Adapter.GitHub,
           owner: owner,
           repo: repo,
           ref: ref,
           auth: auth
         ) do
      {:ok, fs} -> {:ok, fs}
      {:error, reason} -> {:error, {:github_configure_failed, reason}}
    end
  end

  defp s3_filesystem(bucket) do
    region = System.get_env("AWS_REGION") || Application.get_env(:ex_aws, :region, "us-east-1")

    case JidoVFS.safe_configure(JidoVFS.Adapter.S3, bucket: bucket, region: region) do
      {:ok, fs} -> {:ok, fs}
      {:error, reason} -> {:error, {:s3_configure_failed, reason}}
    end
  end

  defp git_filesystem(repo_path) do
    case JidoVFS.safe_configure(JidoVFS.Adapter.Git, path: repo_path) do
      {:ok, fs} -> {:ok, fs}
      {:error, reason} -> {:error, {:git_configure_failed, reason}}
    end
  end
end
