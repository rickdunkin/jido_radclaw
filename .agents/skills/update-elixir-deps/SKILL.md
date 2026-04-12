---
name: update-elixir-deps
description: Update, upgrade, or audit existing dependencies in an Elixir/Mix project. Trigger when the user wants to bring packages up to date, check what's outdated, refresh mix.lock, or do a dependency security audit — even generic requests like "update my deps" when the project has mix.exs. Provides a complete upgrade workflow: runs mix hex.outdated, classifies safe vs breaking updates, looks up changelogs for major version migrations, applies code changes, and verifies compilation and tests pass. Also covers pre-release sweeps, neglected project catch-up, and compliance-driven upgrades. Do NOT use for: adding brand-new dependencies, fixing compile/runtime errors, publishing to hex.pm, or debugging existing version conflicts.
---

# Update Elixir Dependencies

Update all outdated dependencies in an Elixir project, handling both safe updates within version constraints and breaking major version changes that require code modifications.

## Phase 1: Assess What's Outdated

Run `mix hex.outdated` and parse the output. Classify each dependency:

- **Safe updates** — the latest version falls within the current version constraint in `mix.exs` (patch/minor bumps). These update automatically with `mix deps.update`.
- **Breaking updates** — the latest version requires changing the constraint in `mix.exs` (typically a major version bump like 1.x → 2.x).
- **Git dependencies** — packages sourced from GitHub/GitLab repos rather than Hex. These won't appear in `mix hex.outdated` output. Check them separately by reviewing `mix.exs` for `github:` or `git:` source entries. For git deps pinned to a branch, `mix deps.update <name>` pulls the latest commit on that branch.
- **Override dependencies** — packages marked with `override: true`. These exist to force a specific version across the dependency tree. Update them carefully since other packages depend on the pinned version.

Present the full picture to the user before making changes — how many safe updates, how many breaking, any git deps that can be refreshed.

Even when the user says something broad like "update all my deps," they mean the full workflow including breaking changes. But before applying breaking updates, confirm with the user: show them which packages have major version bumps and what the target versions are. Safe updates can proceed without confirmation since they stay within existing constraints.

## Phase 2: Apply Safe Updates

```bash
mix deps.update --all
```

This updates everything within existing version constraints. After running, do a quick sanity check:

```bash
mix compile --warnings-as-errors
```

If compilation fails, fix issues before proceeding. Safe updates occasionally introduce deprecation warnings or subtle behavior changes even without a major version bump.

## Phase 3: Handle Breaking Changes

Work through breaking updates one at a time. For each dependency:

### 3a. Find the changelog

Look up what changed between the current and target version. Try these sources in order:

1. Fetch `https://hexdocs.pm/{package_name}/changelog.html`
2. If that doesn't have what you need, check `https://hexdocs.pm/{package_name}` — look for sidebar links to "Changelog", "Upgrade Guide", or "Migration Guide"
3. Check the package's GitHub repo for CHANGELOG.md or release notes

Focus on breaking changes between the installed version and the target version. Skip entries for versions you're not jumping past.

### 3b. Update mix.exs

Change the version constraint to allow the new major version. For example:

```elixir
# Before
{:some_package, "~> 1.5"}
# After
{:some_package, "~> 2.0"}
```

Then fetch the new version:

```bash
mix deps.get
```

### 3c. Apply code changes

Based on the changelog, update any code that uses deprecated or removed APIs. Common patterns in Elixir major version bumps:

- Renamed modules or functions
- Changed function signatures (new required args, removed args)
- Config key changes
- Struct field changes
- Behaviour callback changes

### 3d. Verify before moving on

After each breaking update, run the full verification suite before starting the next one. This isolates failures to the specific upgrade that caused them:

```bash
mix compile --warnings-as-errors
mix test
```

Fix any issues before proceeding to the next breaking dependency.

## Phase 4: Verification

Once all updates are applied, run the full verification:

```bash
# Compile with warnings as errors
mix compile --warnings-as-errors

# Check formatting
mix format --check-formatted

# Run tests
mix test
```

If any step fails:
- **Compile warnings**: Fix the warning in the source code. Common causes are deprecated function calls from upgraded packages.
- **Format issues**: Run `mix format` to auto-fix, then verify with `--check-formatted` again.
- **Test failures**: Debug by examining the failure output. Often caused by API changes in upgraded dependencies.

## Phase 5: Confirm and Summarize

Run `mix hex.outdated` one final time to confirm the state of dependencies.

Provide a summary including:
- Which dependencies were updated and from/to versions
- Any breaking changes that required code modifications (and what was changed)
- Any dependencies that could NOT be updated and why (e.g., a git dep pinned to a specific branch, an override that other packages depend on, a package with no newer version available)

## Edge Cases

**Ash Framework ecosystem** — Ash and its extensions (ash_postgres, ash_json_api, ash_authentication, etc.) should be updated together since they have tight cross-version compatibility requirements. Check `mix hex.outdated` after updating one Ash package to see if others now need updating too.

**Optional dependencies** — Packages marked `optional: true, runtime: false` in `mix.exs` may not be exercised by the test suite. Still update them, but note that verification through tests may not catch regressions.

**Lock file conflicts** — If `mix.lock` has complex resolution issues after updating constraints, try `mix deps.unlock --all && mix deps.get` to rebuild the lock file from scratch. Only do this as a last resort since it changes every locked version at once.
