# Make `PullRequestCoordinator` quality validation genuinely fallible

## Context

`mix compile --warnings-as-errors` trips on two "the following clause will never
match" warnings in `JidoClaw.GitHub.Agents.PullRequestCoordinator.do_attempt/5`
(`lib/jido_claw/github/agents/pull_request_coordinator.ex:32` and `:39`). The
module's `with` chain calls three private helpers — `generate_patch/3`,
`validate_quality/1`, `submit_pr/2` — that are **stubs returning `{:ok, _}`
unconditionally**, so Elixir 1.20's set-theoretic type checker proves the `else`
retry/abort branches unreachable. The branches encode the intended
retry-on-quality-failure contract; the project currently tolerates the two
warnings via an allowlist entry in `lib/mix/tasks/jidoclaw.compile_check.ex:26-32`.

We're completing the contract for real: make the helpers genuinely fallible so
the `else` branches become reachable, the warnings disappear at the source, and
the allowlist entry (and the standing Stop-hook `--warnings-as-errors` conflict)
can be retired.

**Key facts from exploration:**
- `PullRequestCoordinator` is **aspirational / dead code** — its only caller
  `CoordinatorAgent.run/1` is itself uncalled, and the webhook pipeline
  broadcasts to PubSub `"github:webhooks"` with no subscriber. **No tests** touch
  it today. No production blast radius; we write the first test for this area.
- The retry-vs-abort machinery in `do_attempt/5` is correct and its **`with`/`else`
  body stays unchanged**: `{:error, {:quality_failed, reason}}` → retry (line 32);
  any other `{:error, reason}` → abort, no retry (line 39); exhaustion at
  `@max_attempts` (3) → `{:error, {:max_attempts_reached, history}}`.
- **Clearing _both_ warnings needs two distinct error shapes.** Elixir's clause
  checker narrows clause-by-clause, so a single `{:quality_failed, _}` clears line
  32 but leaves line 39 matching `none()`. We supply a retryable `:quality_failed`
  (line 32) **and** a terminal `:generation_failed` (line 39).
- **Cross-module inference works here (verified from existing code):**
  `CoordinatorAgent.run/1` (`coordinator_agent.ex:13-21`) already has a `with`
  whose `else {:error, reason}` consumes `ResearchCoordinator.research/2`'s
  cross-module `{:error, :research_failed}`, and that file is not allowlisted and
  compiles clean. So extracting the validator to its own module and calling it in
  the `with` still makes line 32 reachable.

## Decisions (confirmed with the user)

1. **Input-driven validation, no production test seam.** Validation requires a
   non-empty `files` list of valid file entries (derived from `research`), a
   present description, and a valid branch. With today's always-empty placeholder
   research, `create_pr/3` now returns `{:error, {:max_attempts_reached, _}}`
   instead of `{:ok, _}` — honest for unwired code, and it makes `generate_patch/3`
   actually use its `research` argument. Every path is reachable by varying inputs.
2. **`generate_patch/3` carries the terminal error** (`{:generation_failed,
   :missing_issue_context}`) for the line-39 branch.

## Review feedback incorporated

Round 1: safe `event_label/1` (log line raised before the `with`); `is_binary`
guard so `description_present?` can't throw; `derive_files` keeps only real paths
(no faked default); extracted public `PatchQuality` module instead of a
public-for-tests private fn; tighter per-component branch validator; pattern-
matched `issue_context/1` instead of `if is_nil(...) or is_nil(...)`.

Round 2:
- **`get_in/2` raises on wrong-shaped intermediates** (`get_in(%{repo: "o/r"},
  [:repo, :full_name])` raises). → `issue_context/1` and `event_label/1` use
  function-head matching, not `get_in/2`. (This also subsumes `build_context/2`.)
- **Reject invalid context values, not just `nil`.** → `issue_context/1` guards
  `is_integer(number) and number > 0 and is_binary(repo) and repo != ""`, so
  blank/non-binary repos and non-positive issue numbers become
  `:missing_issue_context` and `submit_pr/2` never sees bad placeholders.
- **`files_present?` must validate entries** (public API). → require a non-empty
  list where **every** entry is `%{path: path}` with a non-empty binary path, so
  `%{files: [nil]}` fails.
- **Branch components beginning with `.`** (`.hidden`, `foo/.bar`) are invalid in
  git. → `valid_component?` adds `not String.starts_with?(c, ".")`.
- **Public module gets real docs** — `@moduledoc` + `@doc` on `validate/1`.

Round 3:
- **`derive_files/1` still used `get_in/2`** (raises on `%{code_search: "bad"}`).
  → pattern-match it too (`%{code_search: %{results: results}}` + catch-all `→
  []`); now no helper uses `get_in/2`.
- **Multiple-failure assertion** uses `MapSet`, not list order.
- **Document `PatchQuality`'s key contract** — expects internal atom-keyed patch
  maps; string keys deliberately unsupported.

## Implementation

### 1. New module `lib/jido_claw/github/patch_quality.ex`

`JidoClaw.GitHub.PatchQuality` — public, pure, no runtime indirection. Real
`@moduledoc` (its role: gate a generated patch before submission) and `@doc` on
`validate/1` that **documents the expected input: an internal atom-keyed patch
map** `%{files: [%{path: binary}], description: binary, branch: binary}` (string
keys are deliberately not supported — patches are always built internally by
`generate_patch/3`, unlike `Trust`, which normalizes externally-sourced maps).
Modeled on `JidoClaw.Solutions.Trust.completeness_score/1`'s
`{predicate, points}` reduce (`trust.ex:82-105`) and its `present?/2`/
`tags_present?/1` blank/empty idioms (`trust.ex:172-180`); per-check records use
the `%{status: "passed"|"failed"}` vocabulary from `trust.ex:143-166`.

```elixir
@checks [:files_present, :description_present, :branch_valid]

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
defp check(:description_present, _), do: false        # nil / non-binary → false, never raise

defp check(:branch_valid, %{branch: b}), do: branch_valid?(b)
defp check(:branch_valid, _), do: false

defp valid_file?(%{path: path}) when is_binary(path) and path != "", do: true
defp valid_file?(_), do: false

defp record({name, ok?}), do: %{name: name, status: if(ok?, do: "passed", else: "failed")}
```

Branch validator — per-component, pragmatic subset of `git check-ref-format
--branch`. Generated `"fix/issue-N"` passes:
```elixir
defp branch_valid?(branch) when is_binary(branch) and branch != "" do
  not String.starts_with?(branch, ["/", "-"]) and
    not String.ends_with?(branch, "/") and
    not String.contains?(branch, "..") and
    branch |> String.split("/") |> Enum.all?(&valid_component?/1)
end
defp branch_valid?(_), do: false

defp valid_component?(c) do
  c != "" and
    not String.starts_with?(c, ".") and             # rejects ".", ".hidden", "foo/.bar"
    Regex.match?(~r{\A[\w.-]+\z}, c) and             # whitelist drops space ~ ^ : ? * [ \ @ {
    not String.ends_with?(c, [".", ".lock"])
end
```

### 2. `lib/jido_claw/github/agents/pull_request_coordinator.ex`

- `do_attempt/5` `with`/`else` **unchanged**, except the log line uses `event_label/1`.
- Add `alias JidoClaw.GitHub.PatchQuality`; drop the obsolete NOTE comment (22-26).
- Replace the helpers (function-head matching throughout — no `get_in/2`):

```elixir
# was: "... for #{event.repo.full_name}##{event.issue.number}"  (raised on malformed events)
defp event_label(%{repo: %{full_name: repo}, issue: %{number: number}})
     when is_binary(repo) and is_integer(number),
     do: "#{repo}##{number}"

defp event_label(_), do: "unknown issue"

defp generate_patch(event, _triage, research) do
  with {:ok, %{issue_number: n}} <- issue_context(event) do
    {:ok,
     %{
       files: derive_files(research),
       description: "Fix for ##{n}",
       branch: "fix/issue-#{n}"
     }}
  end                                                 # passes {:error, …} through → line 39
end

defp issue_context(%{issue: %{number: number}, repo: %{full_name: repo}})
     when is_integer(number) and number > 0 and is_binary(repo) and repo != "" do
  {:ok, %{issue_number: number, repo: repo}}
end

defp issue_context(_), do: {:error, {:generation_failed, :missing_issue_context}}

# Files derive from research findings; empty/pathless/wrong-shaped research →
# empty patch, which PatchQuality.validate/1 rejects, driving the retry loop.
# Only real, non-empty binary paths count (no faked defaults). Matched by shape
# (not get_in/2) so `%{code_search: "bad"}` yields [] instead of raising.
defp derive_files(%{code_search: %{results: results}}) do
  results
  |> List.wrap()
  |> Enum.flat_map(fn
    %{path: p} when is_binary(p) and p != "" -> [%{path: p}]
    _ -> []
  end)
end

defp derive_files(_), do: []
```
The `with` step `{:ok, quality} <- validate_quality(patch)` becomes
`{:ok, quality} <- PatchQuality.validate(patch)`. `submit_pr/2` stays `{:ok, _}`
(only reached on the happy path, where `issue_context/1` has already guaranteed a
binary `repo` and positive `issue_number`), so it is unchanged. Every helper now
matches its input by shape — **no `get_in/2` anywhere** — so a wrong-shaped event
*or* research map yields a clean error / empty result instead of raising.

Error tuples follow house style — cf. `vfs/resolver.ex:578`, `forge/harness.ex:778`,
and sibling `ResearchCoordinator`'s `{:error, :research_failed}`
(`research_coordinator.ex:27-32`).

Resulting `else`-failure type = `{:error, {:generation_failed, _}} | {:error,
{:quality_failed, _}}` → line 32 matches quality, line 39 matches generation →
**both warnings cleared**.

### 3. `lib/mix/tasks/jidoclaw.compile_check.ex`

Set `@allowlist []` (remove lines 26-32's entry). Keep the attribute, the
moduledoc guidance, and `allowed?/1` (handles `[]`: reports "0 tolerated, 0
blocking").

### 4. `AGENTS.md` (doc hygiene)

Refresh the "Known limitations" bullet that claims the allowlist "currently holds
only the two intentional dead-`else` branches … drop them once those helpers do
real work" — the helpers now do fallible work; note the allowlist is empty / the
branches are live.

## Tests

`use ExUnit.Case, async: true` for both (no global state). The coordinator test
carries `@moduletag :capture_log` (logs per attempt/exhaustion). No fixtures
exist; build event maps inline (`event/0` → `%{issue: %{number: 42, …}, repo:
%{full_name: "owner/repo", …}, …}`).

**`test/jido_claw/github/patch_quality_test.exs` (new)** — direct unit coverage:
- good patch (`files: [%{path: "lib/foo.ex"}], description: "x", branch:
  "fix/issue-1"`) → `{:ok, %{passed: true, checks: …}}`.
- files: `[]`, `[nil]`, `[%{}]`, `[%{path: ""}]` → `{:error, {:quality_failed,
  [:files_present]}}` (entry validation, Findings 3 + R2).
- `nil` / non-binary / blank description → `[:description_present]` (no raise).
- invalid branches `"bad branch!"`, `"/leading"`, `"a..b"`, `"x.lock"`, `"."`,
  `"foo."`, `"foo//bar"`, `".hidden"`, `"foo/.bar"` → `[:branch_valid]`; and
  `"fix/issue-42"` passes.
- multiple simultaneous failures → assert via `MapSet.new(names)` (failure order
  is incidental from `@checks`, not a contract).

**`test/jido_claw/github/agents/pull_request_coordinator_test.exs` (new)** —
contract via `create_pr/3`:
- **happy path**: valid event + `research: %{code_search: %{results: [%{path:
  "lib/foo.ex"}]}}` → `{:ok, %{attempts: 1, quality: %{passed: true}, …}}`.
- **retry exhaust**: valid event + `research: %{}` (empty → empty files →
  `:quality_failed` each attempt) → `{:error, {:max_attempts_reached, history}}`;
  `length(history) == 3`; entries `%{attempt: n, error: [:files_present]}`,
  newest-first. Also assert `research: %{code_search: %{results: [%{}]}}`
  (pathless) exhausts (Finding 3).
- **terminal abort, no retry**: `{:error, {:generation_failed,
  :missing_issue_context}}` returned directly (no retry) — and verifies the safe
  log label — for each malformed event: `%{}`; **wrong-shaped**
  `%{repo: "owner/repo", issue: %{number: 1}}` (string repo — would have raised
  under `get_in/2`); **invalid values** `%{issue: %{number: 0}, repo: %{full_name:
  "o/r"}}` and `%{issue: %{number: 1}, repo: %{full_name: ""}}`.

## Verification

Run via `mise exec -- mix` (mise-latest, OTP 29 / Elixir 1.20):
1. `mise exec -- mix compile --warnings-as-errors --force` — **expect exit 0,
   zero warnings** (headline signal; the two PR-coordinator warnings gone, none
   new from the new module).
2. `mise exec -- mix jidoclaw.compile_check` — expect `OK — 0 tolerated, 0 blocking`.
3. `mise exec -- mix test test/jido_claw/github/patch_quality_test.exs test/jido_claw/github/agents/pull_request_coordinator_test.exs`
   — all pass.
4. `mise exec -- mix format --check-formatted`.
5. `mise exec -- mix precommit` — full gate; run bare in background and read the
   tail (do **not** pipe through `tail` — it masks the exit code).

## Notes / out of scope

- **Side benefit:** removing the two warnings also clears the standing Stop-hook
  `compile --warnings-as-errors` conflict in project memory; that note needs a
  post-merge update.
- **Not wiring the pipeline.** No PubSub subscriber, no broadcast↔`CoordinatorAgent`
  event-shape reconciliation — separate, larger work.
- `submit_pr/2` and the patch *content* remain placeholders by design; today's
  goal is genuine fallibility, not a real code generator.

## Files

- `lib/jido_claw/github/patch_quality.ex` — new validator module (with docs).
- `lib/jido_claw/github/agents/pull_request_coordinator.ex` — fallible
  `generate_patch/3` + pattern-matched `issue_context/1` + `derive_files/1`, safe
  `event_label/1`, delegate to `PatchQuality.validate/1`, drop NOTE.
- `lib/mix/tasks/jidoclaw.compile_check.ex` — `@allowlist []`.
- `test/jido_claw/github/patch_quality_test.exs` — new.
- `test/jido_claw/github/agents/pull_request_coordinator_test.exs` — new.
- `AGENTS.md` — refresh the "Known limitations" allowlist bullet.

## Suggested commit

`fix: make PullRequestCoordinator quality validation fallible, drop warning allowlist`
