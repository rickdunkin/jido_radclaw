defmodule JidoClaw.GitHub.PatchQuality do
  @moduledoc """
  Quality gate for a generated patch before it is submitted as a pull request.

  `PullRequestCoordinator.generate_patch/3` builds a candidate patch from the
  triage/research findings; `validate/1` is the checkpoint that decides whether
  that patch is good enough to submit or must be regenerated. A failed validation
  drives the coordinator's retry loop (`{:error, {:quality_failed, _}}`).

  The checks are intentionally pure and structural — no I/O, no LLM calls — so the
  gate is cheap and deterministic. Each check contributes a per-check record
  (`%{name: atom, status: "passed" | "failed"}`) for inspection on success.
  """

  @checks [:files_present, :description_present, :branch_valid]

  @doc """
  Validate a generated patch, returning `{:ok, report}` or `{:error, {:quality_failed, failed_checks}}`.

  Expects an **internal, atom-keyed** patch map of the shape

      %{files: [%{path: binary}], description: binary, branch: binary}

  String keys are deliberately not supported: patches are always built internally
  by `PullRequestCoordinator.generate_patch/3`, so there is no externally-sourced
  map to normalize (unlike `JidoClaw.Solutions.Trust`, which accepts both key
  styles). A missing or wrong-typed field simply fails its check rather than
  raising, so any map is safe to pass.

  Checks (all must pass):

    * `:files_present` — `:files` is a non-empty list and every entry is
      `%{path: binary}` with a non-blank (post-trim) path.
    * `:description_present` — `:description` is a non-empty (post-trim) binary.
    * `:branch_valid` — `:branch` is a valid git branch name (pragmatic subset of
      `git check-ref-format --branch`).
  """
  @spec validate(map()) ::
          {:ok, %{passed: true, checks: [map()]}}
          | {:error, {:quality_failed, [atom()]}}
  def validate(patch) do
    results = Enum.map(@checks, fn name -> {name, check(name, patch)} end)

    case Enum.reject(results, fn {_n, ok?} -> ok? end) do
      [] -> {:ok, %{passed: true, checks: Enum.map(results, &record/1)}}
      failed -> {:error, {:quality_failed, Enum.map(failed, fn {n, _} -> n end)}}
    end
  end

  # Non-empty list AND every entry a valid file (so [nil] / [%{}] fail).
  defp check(:files_present, %{files: files}) when is_list(files) and files != [],
    do: Enum.all?(files, &valid_file?/1)

  defp check(:files_present, _), do: false

  defp check(:description_present, %{description: d}) when is_binary(d),
    do: String.trim(d) != ""

  # nil / non-binary → false, never raise
  defp check(:description_present, _), do: false

  defp check(:branch_valid, %{branch: b}), do: branch_valid?(b)
  defp check(:branch_valid, _), do: false

  # Non-blank check lives in the body (String.trim/1 is not guard-legal), so a
  # whitespace-only path like "   " is rejected, matching :description_present.
  defp valid_file?(%{path: path}) when is_binary(path), do: String.trim(path) != ""
  defp valid_file?(_), do: false

  defp record({name, ok?}), do: %{name: name, status: if(ok?, do: "passed", else: "failed")}

  # Pragmatic subset of `git check-ref-format --branch`. Generated
  # "fix/issue-N" passes; obviously-bad refs are rejected.
  defp branch_valid?(branch) when is_binary(branch) and branch != "" do
    not String.starts_with?(branch, ["/", "-"]) and
      not String.ends_with?(branch, "/") and
      not String.contains?(branch, "..") and
      Enum.all?(String.split(branch, "/"), &valid_component?/1)
  end

  defp branch_valid?(_), do: false

  defp valid_component?(c) do
    # rejects ".", ".hidden", "foo/.bar"
    # whitelist drops space ~ ^ : ? * [ \ @ {
    c != "" and
      not String.starts_with?(c, ".") and
      Regex.match?(~r{\A[\w.-]+\z}, c) and
      not String.ends_with?(c, [".", ".lock"])
  end
end
