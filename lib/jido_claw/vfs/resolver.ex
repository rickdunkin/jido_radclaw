defmodule JidoClaw.VFS.Resolver do
  @moduledoc """
  VFS abstraction layer that routes file operations to the appropriate backend.

  Path routing:
    * `github://owner/repo/path` — `Jido.VFS.Adapter.GitHub`
    * `s3://bucket/key`          — `Jido.VFS.Adapter.S3`
    * `git://repo-path/file`     — `Jido.VFS.Adapter.Git`
    * Absolute path under a workspace mount — `Jido.Shell.VFS.*` (requires
      `:workspace_id` opt)
    * All other paths            — local filesystem via `File.*`

  Remote paths require credentials supplied via application config or
  environment variables. If no credentials are available the operation
  returns `{:error, :credentials_required}`.

  All functions mirror the `File` module signatures for drop-in
  compatibility in tool modules.
  """

  require Logger

  alias Jido.Shell.VFS, as: ShellVFS
  alias Jido.Shell.VFS.MountTable

  # -- Public API -------------------------------------------------------------

  @doc """
  Read file contents.

  Returns `{:ok, binary()}` or `{:error, reason}`.

  Options:
    * `:workspace_id` — when set, absolute paths are checked against the
      workspace's VFS mount table before falling back to the local filesystem.
    * `:project_dir` — when set alongside `:workspace_id`, the workspace is
      auto-bootstrapped via `JidoClaw.VFS.Workspace.ensure_started/2`
      before consulting the mount table. Bootstrap failures surface as
      `{:error, {:workspace_bootstrap_failed, reason}}` rather than silently
      falling through to the local filesystem.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read(path, opts \\ []) do
    with :ok <- maybe_ensure_workspace(path, opts) do
      case parse_path(path, opts) do
        {:vfs, workspace_id, vfs_path} ->
          ShellVFS.read_file(workspace_id, vfs_path)

        {:local, local_path} ->
          File.read(local_path)

        {:github, owner, repo, ref, file_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref) do
            Jido.VFS.read(fs, file_path)
          end

        {:s3, bucket, key} ->
          with {:ok, fs} <- s3_filesystem(bucket) do
            Jido.VFS.read(fs, key)
          end

        {:git, repo_path, file_path} ->
          with {:ok, fs} <- git_filesystem(repo_path) do
            Jido.VFS.read(fs, file_path)
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
      case parse_path(path, opts) do
        {:vfs, workspace_id, vfs_path} ->
          ShellVFS.write_file(workspace_id, vfs_path, content)

        {:local, local_path} ->
          local_path |> Path.dirname() |> File.mkdir_p!()
          File.write(local_path, content)

        {:github, owner, repo, ref, file_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref) do
            Jido.VFS.write(fs, file_path, content)
          end

        {:s3, bucket, key} ->
          with {:ok, fs} <- s3_filesystem(bucket) do
            Jido.VFS.write(fs, key, content)
          end

        {:git, repo_path, file_path} ->
          with {:ok, fs} <- git_filesystem(repo_path) do
            Jido.VFS.write(fs, file_path, content)
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
      case parse_path(path, opts) do
        {:vfs, workspace_id, vfs_path} ->
          with {:ok, entries} <- ShellVFS.list_dir(workspace_id, vfs_path) do
            {:ok, Enum.map(entries, & &1.name)}
          end

        {:local, local_path} ->
          File.ls(local_path)

        {:github, owner, repo, ref, dir_path} ->
          with {:ok, fs} <- github_filesystem(owner, repo, ref),
               {:ok, contents} <- Jido.VFS.list_contents(fs, dir_path) do
            names = Enum.map(contents, & &1.name)
            {:ok, names}
          end

        {:s3, bucket, prefix} ->
          with {:ok, fs} <- s3_filesystem(bucket),
               {:ok, contents} <- Jido.VFS.list_contents(fs, prefix) do
            names = Enum.map(contents, & &1.name)
            {:ok, names}
          end

        {:git, repo_path, dir_path} ->
          with {:ok, fs} <- git_filesystem(repo_path),
               {:ok, contents} <- Jido.VFS.list_contents(fs, dir_path) do
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
          case JidoClaw.VFS.Workspace.ensure_started(ws, pd) do
            {:ok, _pid} -> :ok
            {:error, reason} -> {:error, {:workspace_bootstrap_failed, reason}}
          end
        else
          :ok
        end
    end
  end

  # -- Path Parsing -----------------------------------------------------------

  # github://owner/repo[@ref]/path/to/file
  # ref defaults to "main" when omitted
  defp parse_path("github://" <> rest, _opts) do
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

  defp parse_path("s3://" <> rest, _opts) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] -> {:s3, bucket, key}
      [bucket] -> {:s3, bucket, ""}
      _ -> {:error, "Invalid s3:// path: s3://#{rest}"}
    end
  end

  defp parse_path("git://" <> rest, _opts) do
    case String.split(rest, "//", parts: 2) do
      [repo_path, file_path] -> {:git, repo_path, file_path}
      [repo_path] -> {:git, repo_path, ""}
      _ -> {:error, "Invalid git:// path: git://#{rest}"}
    end
  end

  defp parse_path(path, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      is_binary(workspace_id) and workspace_id != "" and String.starts_with?(path, "/") ->
        case MountTable.resolve(workspace_id, path) do
          {:ok, _mount, _rel} -> {:vfs, workspace_id, path}
          {:error, :no_mount} -> {:local, path}
        end

      true ->
        {:local, path}
    end
  end

  defp split_owner_ref(owner_ref) do
    case String.split(owner_ref, "@", parts: 2) do
      [owner, ref] -> {owner, ref}
      [owner] -> {owner, "main"}
    end
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

    case Jido.VFS.safe_configure(Jido.VFS.Adapter.GitHub,
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

    case Jido.VFS.safe_configure(Jido.VFS.Adapter.S3, bucket: bucket, region: region) do
      {:ok, fs} -> {:ok, fs}
      {:error, reason} -> {:error, {:s3_configure_failed, reason}}
    end
  end

  defp git_filesystem(repo_path) do
    case Jido.VFS.safe_configure(Jido.VFS.Adapter.Git, path: repo_path) do
      {:ok, fs} -> {:ok, fs}
      {:error, reason} -> {:error, {:git_configure_failed, reason}}
    end
  end
end
