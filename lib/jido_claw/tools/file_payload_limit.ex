defmodule JidoClaw.Tools.FilePayloadLimit do
  @moduledoc false

  alias JidoClaw.Error
  alias JidoClaw.VFS.Resolver

  @max_bytes 5 * 1024 * 1024

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec validate(atom(), binary()) :: :ok | {:error, String.t()}
  def validate(_field, content) when is_binary(content) and byte_size(content) <= @max_bytes do
    :ok
  end

  def validate(field, content) when is_binary(content) do
    {:error, "#{field} exceeds #{@max_bytes} byte limit (#{byte_size(content)} bytes)."}
  end

  @doc """
  Pre-read type + size guard: `lstat`s the locally-resolved target, follows an
  admitted symlink with `stat`, and accepts only a regular file under the cap
  *before* bytes are materialized on the heap. FIFOs, sockets, devices, and
  directories are rejected before `File.read/1` can block or cross an I/O
  boundary with no deadline.

  Best-effort by design — paths that don't resolve locally (remote
  URIs, VFS mounts) and stat failures return `:ok` so the read itself
  surfaces the real error; `validate_read_content/2` is the
  unconditional backstop on every branch.
  """
  @spec validate_read(String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def validate_read(path, opts) do
    case Resolver.local_path(path, opts, :read) do
      {:ok, local} -> check_local_file(path, local)
      {:error, _not_locally_resolvable} -> :ok
    end
  end

  defp check_local_file(path, local) do
    case File.lstat(local) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        check_size(path, size)

      {:ok, %File.Stat{type: :symlink}} ->
        check_symlink_target(path, local)

      {:ok, %File.Stat{type: type}} ->
        {:error, non_regular_read_error(path, type)}

      {:error, _reason} ->
        :ok
    end
  end

  defp check_symlink_target(path, local) do
    case File.stat(local) do
      {:ok, %File.Stat{type: :regular, size: size}} -> check_size(path, size)
      {:ok, %File.Stat{type: type}} -> {:error, non_regular_read_error(path, type)}
      {:error, _reason} -> :ok
    end
  end

  defp check_size(path, size) when size > @max_bytes, do: {:error, read_cap_error(path, size)}
  defp check_size(_path, _size), do: :ok

  @doc """
  Post-read size guard: bounds content that already reached the heap.

  Closes the stat→read race on local files and covers remote/VFS
  branches uniformly. For remote schemes the bytes are necessarily
  materialized before this check — bounding the fetch itself would
  need backend streaming support.
  """
  @spec validate_read_content(String.t(), binary()) :: :ok | {:error, Exception.t()}
  def validate_read_content(path, content) when is_binary(content) do
    if byte_size(content) > @max_bytes do
      {:error, read_cap_error(path, byte_size(content))}
    else
      :ok
    end
  end

  defp read_cap_error(path, size) do
    Error.validation_error(
      "#{path} is #{size} bytes, exceeds the #{@max_bytes}-byte read cap; " <>
        "use run_command (e.g. sed -n 'START,ENDp') for large files",
      details: %{path: path, size: size, max_bytes: @max_bytes}
    )
  end

  defp non_regular_read_error(path, type) do
    Error.validation_error(
      "#{path} is a non-regular local file (#{type}); refusing a potentially blocking read",
      details: %{path: path, type: type}
    )
  end
end
