defmodule JidoClaw.VFS.Resolver do
  @moduledoc """
  VFS abstraction layer that routes file operations to the appropriate backend.

  Path routing:
  - `github://owner/repo/path` — `Jido.VFS.Adapter.GitHub`
  - `s3://bucket/key`          — `Jido.VFS.Adapter.S3`
  - `git://repo-path/file`     — `Jido.VFS.Adapter.Git`
  - All other paths             — local filesystem via `File.*`

  Remote paths require credentials supplied via application config or
  environment variables. If no credentials are available the operation
  returns `{:error, :credentials_required}`.

  All functions mirror the `File` module signatures for drop-in
  compatibility in tool modules.
  """

  require Logger

  # -- Public API -------------------------------------------------------------

  @doc """
  Read file contents.

  Returns `{:ok, binary()}` or `{:error, reason}`.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(path) do
    case parse_path(path) do
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

  @doc """
  Write content to a file, creating parent directories as needed.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write(String.t(), binary()) :: :ok | {:error, term()}
  def write(path, content) do
    case parse_path(path) do
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

  @doc """
  List directory contents.

  Returns `{:ok, [String.t()]}` or `{:error, reason}`.
  For remote adapters the names are returned as strings (no type annotation).
  For local paths the native `File.ls/1` output is preserved.
  """
  @spec ls(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def ls(path) do
    case parse_path(path) do
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

  @doc """
  Returns true when `path` uses a remote scheme (github://, s3://, git://).
  """
  @spec remote?(String.t()) :: boolean()
  def remote?(path) do
    String.starts_with?(path, ["github://", "s3://", "git://"])
  end

  # -- Path Parsing -----------------------------------------------------------

  # github://owner/repo[@ref]/path/to/file
  # ref defaults to "main" when omitted
  defp parse_path("github://" <> rest) do
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

  defp parse_path("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] -> {:s3, bucket, key}
      [bucket] -> {:s3, bucket, ""}
      _ -> {:error, "Invalid s3:// path: s3://#{rest}"}
    end
  end

  defp parse_path("git://" <> rest) do
    case String.split(rest, "//", parts: 2) do
      [repo_path, file_path] -> {:git, repo_path, file_path}
      [repo_path] -> {:git, repo_path, ""}
      _ -> {:error, "Invalid git:// path: git://#{rest}"}
    end
  end

  defp parse_path(path), do: {:local, path}

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
