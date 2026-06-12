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
  Pre-read size guard: stats the locally-resolved target and refuses
  files over the cap *before* they are materialized on the heap.

  Best-effort by design — paths that don't resolve locally (remote
  URIs, VFS mounts) and stat failures return `:ok` so the read itself
  surfaces the real error; `validate_read_content/2` is the
  unconditional backstop on every branch.
  """
  @spec validate_read(String.t(), keyword()) :: :ok | {:error, Exception.t()}
  def validate_read(path, opts) do
    case Resolver.local_path(path, opts, :read) do
      {:ok, local} -> check_stat_size(path, local)
      {:error, _not_locally_resolvable} -> :ok
    end
  end

  defp check_stat_size(path, local) do
    case File.stat(local) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes -> {:error, read_cap_error(path, size)}
      _under_cap_or_stat_error -> :ok
    end
  end

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
end
