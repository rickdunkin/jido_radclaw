defmodule JidoClaw.Core.FileStat do
  @moduledoc """
  Shared stat-identity tuple for race-fence checks.

  Two security boundaries (the verify-authority working-tree fingerprint in
  `Orchestration.Verify.Git` and the mount-config snapshot fence in
  `Security.ToolApproval`) compare a file's stat before and after reading it
  to detect concurrent swaps. Both need the exact same identity tuple, so it
  lives here once.
  """

  @typedoc "The 8-field stat identity (atime deliberately excluded)."
  @type identity ::
          {integer(), integer(), integer(), atom(), integer(), integer(), term(), term()}

  @doc """
  True when both stats carry the same identity — the pre/post consistency
  fence and opened-file identity check that prevents hashing a
  symlink-swapped target.
  """
  @spec stable?(File.Stat.t() | map(), File.Stat.t() | map()) :: boolean()
  def stable?(left, right), do: identity(left) == identity(right)

  # atime is deliberately excluded: reading the file may update it. The
  # `Map.fetch!` form works on both `%File.Stat{}` and the plain maps some
  # callers build — and still fails loudly on a malformed input.
  @spec identity(File.Stat.t() | map()) :: identity()
  def identity(stat) do
    {
      Map.fetch!(stat, :major_device),
      Map.fetch!(stat, :minor_device),
      Map.fetch!(stat, :inode),
      Map.fetch!(stat, :type),
      Map.fetch!(stat, :size),
      Map.fetch!(stat, :mode),
      Map.fetch!(stat, :mtime),
      Map.fetch!(stat, :ctime)
    }
  end
end
