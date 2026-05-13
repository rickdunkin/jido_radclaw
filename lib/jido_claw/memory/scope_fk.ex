defmodule JidoClaw.Memory.ScopeFk do
  @moduledoc """
  Shared scope/FK helpers used by both `JidoClaw.Memory.Fact` and
  `JidoClaw.Memory.HybridSearchSql` when building raw SQL fragments.
  """

  @doc """
  Normalize a UUID value to its 16-byte binary form for `Repo.query!/2`
  parameter binding. Passes through already-dumped 16-byte binaries and
  non-binary values untouched.
  """
  @spec uuid_dump(any()) :: any()
  def uuid_dump(<<_::binary-size(16)>> = raw), do: raw
  def uuid_dump(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)
  def uuid_dump(other), do: other
end
