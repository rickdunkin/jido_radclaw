defmodule JidoClaw.VFS.AdapterPolicy do
  @moduledoc """
  Single source of truth for VFS adapter identity and write locality.

  Config parsing is closed over the adapters JidoClaw exposes. Approval
  classification is deliberately open-world and fail-closed: only adapters
  explicitly registered as local bypass the remote-write approval gate; an
  unknown live module or config key is treated as remote until classified.
  """

  @adapters [
    %{key: :local, module: Jido.VFS.Adapter.Local, remote?: false, scheme: nil},
    %{key: :in_memory, module: Jido.VFS.Adapter.InMemory, remote?: false, scheme: nil},
    %{key: nil, module: Jido.VFS.Adapter.ETS, remote?: false, scheme: nil},
    %{key: :github, module: Jido.VFS.Adapter.GitHub, remote?: true, scheme: "github"},
    %{key: :s3, module: Jido.VFS.Adapter.S3, remote?: true, scheme: "s3"},
    %{key: :git, module: Jido.VFS.Adapter.Git, remote?: true, scheme: "git"},
    %{key: nil, module: Jido.VFS.Adapter.Sprite, remote?: true, scheme: nil}
  ]

  @remote_prefixes for %{remote?: true, scheme: scheme} <- @adapters,
                       is_binary(scheme),
                       do: scheme <> "://"

  @doc "Parse a supported user-facing adapter key without creating atoms."
  @spec parse_config_key(term()) :: {:ok, atom()} | {:error, term()}
  for %{key: key} <- @adapters, not is_nil(key) do
    string_key = Atom.to_string(key)
    def parse_config_key(unquote(key)), do: {:ok, unquote(key)}
    def parse_config_key(unquote(string_key)), do: {:ok, unquote(key)}
  end

  def parse_config_key(adapter) when is_atom(adapter) or is_binary(adapter),
    do: {:error, {:unknown_adapter, adapter}}

  def parse_config_key(_adapter), do: {:error, :invalid_adapter}

  @doc "Return whether a configured adapter is remote; unknown values fail closed to true."
  @spec config_remote?(term()) :: boolean()
  for %{key: key, remote?: remote?} <- @adapters, not is_nil(key) do
    string_key = Atom.to_string(key)
    def config_remote?(unquote(key)), do: unquote(remote?)
    def config_remote?(unquote(string_key)), do: unquote(remote?)
  end

  def config_remote?(_unknown), do: true

  @doc "Return whether a live adapter module is remote; unknown modules fail closed to true."
  @spec module_remote?(term()) :: boolean()
  for %{module: module, remote?: false} <- @adapters do
    def module_remote?(unquote(module)), do: false
  end

  def module_remote?(_unknown), do: true

  @doc "Return whether a path uses a registered remote URI scheme."
  @spec remote_uri?(term()) :: boolean()
  def remote_uri?(path) when is_binary(path), do: String.starts_with?(path, @remote_prefixes)
  def remote_uri?(_path), do: false
end
