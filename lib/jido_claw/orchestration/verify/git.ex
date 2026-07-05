defmodule JidoClaw.Orchestration.Verify.Git do
  @moduledoc """
  The single git capture seam for the deterministic verify authority (and, in
  Phase 2, `JidoClaw.Tools.GitCommit`'s engine facts) — single-sourced here so
  the `System.cmd` git idiom is never cloned across the verify/commit surfaces.

  Every capture is nil-on-failure (nonzero exit, missing git, not a repo, a
  raise): callers treat nil as "capture unavailable" and fail toward
  inconclusive, never toward a fabricated value. stderr is deliberately NOT
  merged into stdout — `diff_digest/1` hashes stdout, and interleaved warning
  chunks would make the digest nondeterministic.
  """

  alias JidoClaw.Security.Redaction.Env

  @doc "The full sha of `repo`'s current HEAD, or nil when git cannot answer."
  @spec head(String.t()) :: String.t() | nil
  def head(repo) do
    case git(["rev-parse", "HEAD"], repo) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          sha -> sha
        end

      _other ->
        nil
    end
  end

  @doc """
  Tracked-files-only porcelain snapshot of `repo` vs HEAD (`""` = clean), or
  nil when git cannot answer. Untracked junk stays irrelevant
  (`--untracked-files=no`) and submodule noise is excluded
  (`--ignore-submodules=all`) — camus-verbatim flags.
  """
  @spec porcelain(String.t()) :: String.t() | nil
  def porcelain(repo) do
    case git(["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all"], repo) do
      {output, 0} -> output
      _other -> nil
    end
  end

  @doc """
  Content-addressed tracked-tree digest: sha256 over `git diff --no-ext-diff
  --no-textconv --binary HEAD`, or nil when git cannot answer. Config-
  insensitive (`--no-ext-diff` alone doesn't cover textconv diff drivers) and
  content-aware (`--binary`; porcelain status lines cannot see content edits
  to already-dirty files) — the working-tree mode's mid-verify integrity bind.
  """
  @spec diff_digest(String.t()) :: String.t() | nil
  def diff_digest(repo) do
    case git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD"], repo) do
      {output, 0} ->
        :sha256
        |> :crypto.hash(output)
        |> Base.encode16(case: :lower)

      _other ->
        nil
    end
  end

  # The shared git System.cmd idiom (git_status.ex): scrubbed child env, cd
  # into the repo, nil-safe on the spawn-failure raises (missing git binary /
  # bad cwd raise ErlangError; a malformed arg raises ArgumentError — the
  # `Core.OsCmd.run_cmd/2` rescue set).
  defp git(args, repo) do
    System.cmd("git", args, cd: repo, env: Env.scrubbed_cmd_env())
  rescue
    _error in [ErlangError, ArgumentError] -> {"", 1}
  end
end
