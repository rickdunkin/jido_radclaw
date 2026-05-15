# Plan: Repo-wide explicit `belongs_to allow_nil?` (43 sites)

## Context

The AshCredo rules added in `1baaad7 AshCredo cleanup (part 1)` produced 186
remaining issues. This is **part 2**: clear all 16
`AshCredo.Check.Readability.BelongsToMissingAllowNil` warnings **and** close the
scope gap by also fixing 27 additional sites that AshCredo cannot see.

The check only scans direct `use Ash.Resource` modules. Resources using
`use JidoClaw.Resource` (the wrapper defined in `lib/jido_claw/resource.ex`
that emits `use Ash.Resource` plus the standard tenant policy) are invisible
to the check, even though their `belongs_to` declarations have the same
implicit-default problem. Going repo-wide eliminates the inconsistency in
one pass.

Why the rule exists: `belongs_to` defaults to `allow_nil?: true`, which
silently allows an unset FK even on tables whose underlying column is
`NOT NULL`. Making the option explicit forces a deliberate choice and makes
the relationship contract reviewable at the resource site (rather than only
in a migration).

**This is not strictly a pure-style change** for the 26 `allow_nil?: false`
sites. The DDL is unchanged (every FK uses `define_attribute?(false)` and the
underlying attribute already has the right `allow_nil?` value, so
`mix ash_postgres.generate_migrations --check` will report no drift). What
*does* change for the `false` sites is Ash's validation pipeline: setting
`allow_nil?: false` on a `belongs_to` makes Ash add it to
`required_belongs_to_relationships`
(`deps/ash/lib/ash/resource/transformers/cache_relationships.ex:29`), which is
checked by `Ash.Actions.ManagedRelationships.validate_required_belongs_to/2`
(`deps/ash/lib/ash/actions/managed_relationships.ex:383`) before persistence.
A missing (nil) FK now fails with an Ash validation error earlier and with
a clearer shape, instead of falling through to a database `NOT NULL`
violation. (Invalid non-nil IDs still hit the FK constraint as today.) That
is desirable, but worth flagging during review and exercising tests
against — see Verification.

## Decision matrix

`allow_nil?` mirrors the FK attribute's declared `allow_nil?` everywhere.
Spot-checked migrations confirm the FK attribute is the source of truth
(`secret_refs.user_id` → `null: false`, `request_correlations.tenant_id`
→ `null: false` — both match their resource attributes).

Mandatoriness is sourced from each FK attribute's declared `allow_nil?`,
which encodes the intended contract. Note that **multitenancy `:tenant`
relationships** all mirror their `tenant_id` attribute's `allow_nil?: false`
— mandatory because the row cannot route without a tenant partition.

### Credo-visible sites (16) — `use Ash.Resource` resources

| # | File:Line | Relationship | Source attr | FK `allow_nil?` | Form |
|---|---|---|---|---|---|
|  1 | `solutions/resources/reputation_import.ex:113` | `:tenant` | `tenant_id` | **false** | do-block |
|  2 | `audit/resources/event.ex:203`                 | `:tenant` | `tenant_id` | **false** | do-block |
|  3 | `conversations/resources/request_correlation.ex:233` | `:tenant`    | `tenant_id`    | **false** | do-block |
|  4 | `conversations/resources/request_correlation.ex:238` | `:session`   | `session_id`   | **false** | do-block |
|  5 | `security/secret_ref.ex:92`                          | `:user`      | `user_id`      | **false** | keyword-list → do-block |
|  6 | `folio/action.ex:161`              | `:user`      | `user_id`     | true | keyword-list |
|  7 | `folio/action.ex:166`              | `:project`   | `project_id`  | true | keyword-list |
|  8 | `folio/inbox_item.ex:106`          | `:user`      | `user_id`     | true | keyword-list |
|  9 | `folio/project.ex:102`             | `:user`      | `user_id`     | true | keyword-list |
| 10 | `orchestration/workflow_run.ex:171`| `:user`      | `user_id`     | true | keyword-list |
| 11 | `orchestration/workflow_run.ex:176`| `:project`   | `project_id`  | true | keyword-list |
| 12 | `orchestration/approval_gate.ex:103`| `:requester`| `requested_by_id` | true | keyword-list |
| 13 | `github/issue_analysis.ex:130`     | `:project`   | `project_id`  | true | keyword-list |
| 14 | `reasoning/resources/outcome.ex:251`| `:workspace`| `workspace_uuid` *(non-default source_attribute)* | true | do-block |
| 15 | `reasoning/resources/outcome.ex:257`| `:session`  | `session_uuid` *(non-default source_attribute)*   | true | do-block |
| 16 | `conversations/resources/request_correlation.ex:243` | `:workspace` | `workspace_id` | true | do-block |

### Hidden sites (27) — `use JidoClaw.Resource` resources

All 27 are do-block form, all use `define_attribute?(false)` and
`attribute_writable?(true)`. The FK attribute's `allow_nil?` reads as below.

| # | File:Line | Relationship | Source attr | FK `allow_nil?` |
|---|---|---|---|---|
| 17 | `memory/resources/consolidation_run.ex:276`  | `:tenant`   | `tenant_id`   | **false** |
| 18 | `memory/resources/block_revision.ex:157`     | `:tenant`   | `tenant_id`   | **false** |
| 19 | `memory/resources/block_revision.ex:162`     | `:block`    | `block_id`    | **false** |
| 20 | `memory/resources/fact.ex:467`               | `:tenant`   | `tenant_id`   | **false** |
| 21 | `memory/resources/link.ex:174`               | `:tenant`   | `tenant_id`   | **false** |
| 22 | `memory/resources/link.ex:179`               | `:from_fact`| `from_fact_id` *(explicit source_attribute)* | **false** |
| 23 | `memory/resources/link.ex:185`               | `:to_fact`  | `to_fact_id`   *(explicit source_attribute)* | **false** |
| 24 | `memory/resources/block.ex:303`              | `:tenant`   | `tenant_id`   | **false** |
| 25 | `memory/resources/episode.ex:190`            | `:tenant`   | `tenant_id`   | **false** |
| 26 | `memory/resources/fact_episode.ex:115`       | `:tenant`   | `tenant_id`   | **false** |
| 27 | `memory/resources/fact_episode.ex:120`       | `:fact`     | `fact_id`     | **false** |
| 28 | `memory/resources/fact_episode.ex:125`       | `:episode`  | `episode_id`  | **false** |
| 29 | `solutions/resources/reputation.ex:166`      | `:tenant`   | `tenant_id`   | **false** |
| 30 | `solutions/resources/solution.ex:401`        | `:tenant`   | `tenant_id`   | **false** |
| 31 | `solutions/resources/solution.ex:406`        | `:workspace`| `workspace_id`| **false** |
| 32 | `solutions/resources/solution.ex:411`        | `:session`  | `session_id`  | true |
| 33 | `solutions/resources/solution.ex:416`        | `:created_by` | `created_by_user_id` *(explicit source_attribute, diverges from default `:created_by_id`)* | true |
| 34 | `workspaces/resources/workspace.ex:200`      | `:tenant`   | `tenant_id`   | **false** |
| 35 | `workspaces/resources/workspace.ex:205`      | `:user`     | `user_id`     | true |
| 36 | `workspaces/resources/workspace.ex:210`      | `:project`  | `project_id`  | true |
| 37 | `conversations/resources/session.ex:237`     | `:tenant`   | `tenant_id`   | **false** |
| 38 | `conversations/resources/session.ex:242`     | `:workspace`| `workspace_id`| **false** |
| 39 | `conversations/resources/session.ex:247`     | `:user`     | `user_id`     | true |
| 40 | `conversations/resources/message.ex:372`     | `:tenant`   | `tenant_id`   | **false** |
| 41 | `conversations/resources/message.ex:377`     | `:session`  | `session_id`  | **false** |
| 42 | `conversations/resources/message.ex:382`     | `:parent_message` | `parent_message_id` *(self-FK, explicit source_attribute)* | true |
| 43 | `cron/resources/job.ex:188`                  | `:tenant`   | `tenant_id`   | **false** |

**Totals**: 26 sites get `allow_nil?: false`, 17 get `allow_nil?: true`.

## Style — match the existing block form

The repo's in-place convention for explicit `allow_nil?(false)` on
`belongs_to` is the do-block form (6 existing examples:
`accounts/api_key.ex:68`, `orchestration/workflow_step.ex:119`,
`orchestration/approval_gate.ex:109`, `forge/resources/checkpoint.ex:80`,
`forge/resources/event.ex:98`, `forge/resources/exec_session.ex:136`).
There is currently zero in-repo precedent for `allow_nil?: true` on
`belongs_to`.

Do **not** add `public?` to any of these edits. The 6 existing examples
above pair `allow_nil?(false)` with `public?(true)` because they declare
the FK attribute inline. All 43 sites in this change use
`define_attribute?(false)` — the FK attribute is declared separately in
`attributes do … end`, so the relationship-level `public?` is intentionally
left at the default and should stay that way.

Rule for this change:

- **Do-block sites (35 of 43)** — insert one line inside the existing block.
  ```elixir
  belongs_to :tenant, JidoClaw.Tenants.Tenant do
    define_attribute?(false)
    attribute_writable?(true)
    allow_nil?(false)   # new line
  end
  ```
- **Keyword-list sites — `true` (8 of 8)** — add `allow_nil?: true` to the
  keyword list (minimal diff; sites #6–#13).
  ```elixir
  belongs_to(:user, JidoClaw.Accounts.User,
    define_attribute?: false,
    attribute_writable?: true,
    allow_nil?: true
  )
  ```
- **Keyword-list `false` site (#5 `secret_ref.ex:92`)** — convert to do-block
  to match the six existing `allow_nil?(false)` precedents (per
  reviewer-confirmed style choice).
  ```elixir
  belongs_to :user, JidoClaw.Accounts.User do
    define_attribute?(false)
    attribute_writable?(true)
    allow_nil?(false)
  end
  ```

Final shape after the change: 35 do-block sites + 8 keyword-list sites = 43.

## Preventing recurrence

Fixing 43 sites once doesn't stop future wrapper-using resources from
reintroducing the gap, because `AshCredo.Check.Readability.BelongsToMissingAllowNil`
only scans direct `use Ash.Resource`. Recommend landing one of these as
part of this PR (or as an immediate follow-up):

- **(Recommended) Local regression test** — `test/jido_claw/style/belongs_to_allow_nil_test.exs`.
  Globs `lib/jido_claw/**/*.ex`, finds each `belongs_to` declaration with a
  simple AST walk (Code.string_to_quoted! + `Macro.prewalk`), and asserts an
  `allow_nil?` option is present either in the keyword list or as a child
  `do`-block call. Catches *every* wrapper variant. ~40 lines.
- **Alternative: upstream patch to AshCredo** — teach the check to recognize
  modules whose `__using__` macro chains to `use Ash.Resource`. Bigger
  effort, depends on upstream merge timing; file as a follow-up issue if not
  done here.

Pick at execution time. The regression test is the lower-risk default.

## Files to edit (24)

```
lib/jido_claw/audit/resources/event.ex                           (1 site)
lib/jido_claw/conversations/resources/message.ex                 (3 sites)
lib/jido_claw/conversations/resources/request_correlation.ex     (3 sites)
lib/jido_claw/conversations/resources/session.ex                 (3 sites)
lib/jido_claw/cron/resources/job.ex                              (1 site)
lib/jido_claw/folio/action.ex                                    (2 sites)
lib/jido_claw/folio/inbox_item.ex                                (1 site)
lib/jido_claw/folio/project.ex                                   (1 site)
lib/jido_claw/github/issue_analysis.ex                           (1 site)
lib/jido_claw/memory/resources/block.ex                          (1 site)
lib/jido_claw/memory/resources/block_revision.ex                 (2 sites)
lib/jido_claw/memory/resources/consolidation_run.ex              (1 site)
lib/jido_claw/memory/resources/episode.ex                        (1 site)
lib/jido_claw/memory/resources/fact.ex                           (1 site)
lib/jido_claw/memory/resources/fact_episode.ex                   (3 sites)
lib/jido_claw/memory/resources/link.ex                           (3 sites)
lib/jido_claw/orchestration/approval_gate.ex                     (1 site)
lib/jido_claw/orchestration/workflow_run.ex                      (2 sites)
lib/jido_claw/reasoning/resources/outcome.ex                     (2 sites)
lib/jido_claw/security/secret_ref.ex                             (1 site)
lib/jido_claw/solutions/resources/reputation.ex                  (1 site)
lib/jido_claw/solutions/resources/solution.ex                    (4 sites)
lib/jido_claw/solutions/resources/reputation_import.ex           (1 site)
lib/jido_claw/workspaces/resources/workspace.ex                  (3 sites)
```

24 files, 43 sites — `reputation.ex` and `reputation_import.ex` are
distinct (one wrapper-resource, one direct Ash.Resource).

Single PR — the change is uniformly mechanical and benefits from a single
review pass over the matrix.

## Verification

1. `mix credo --format json --mute-exit-status | jq '.issues |
   map(select(.check ==
   "AshCredo.Check.Readability.BelongsToMissingAllowNil")) | length'` → `0`.
   (`--mute-exit-status` keeps the pipeline survivable under `set -e` /
   `pipefail`; Credo exits non-zero when any issues exist.)
2. `mix credo --format json --mute-exit-status | jq '.issues | length'`
   → `170` (was 186 before part 2; only the 16 Credo-visible sites count
   toward the total — the 27 hidden sites are silent to Credo).
3. `mix compile --warnings-as-errors` clean.
4. **`mix ash_postgres.generate_migrations --check`** clean — asserts no
   schema drift without writing snapshot/migration files. (The `--check`
   flag is the correct "no DDL change" assertion; the bare task would write
   files or prompt.)
5. `mix format --check-formatted` clean.
6. `mix test` — focused regression coverage on touched resources, with
   particular attention to the 26 `allow_nil?: false` sites because Ash now
   validates these relationships before persistence (see Context):
   - `test/jido_claw/conversations/` — session + message + request_correlation
   - `test/jido_claw/memory/` — fact + link + block + episode + revision flows
   - `test/jido_claw/solutions/` — solution + reputation + **reputation_import**
     (the `:tenant` FK is a behavior-changing `false` site)
   - `test/jido_claw/workspaces/` — workspace policy + creation paths
   - `test/jido_claw/audit/` — append-only event creation
   - `test/jido_claw/security/` — secret_ref unique-per-user identity
   No behavioral change is expected on `allow_nil?: true` sites; for `false`
   sites the only expected delta is that missing FKs now surface as an Ash
   validation error rather than a DB FK constraint violation.

## Commit

Suggested message (do not run without explicit user request):

```
AshCredo cleanup (part 2): explicit belongs_to allow_nil?

Mirror each belongs_to's allow_nil? to its FK attribute's allow_nil?
across all 43 sites in lib/jido_claw/. Clears 16
AshCredo.Readability.BelongsToMissingAllowNil findings on direct
`use Ash.Resource` resources and closes the scope gap on 27 sites in
`use JidoClaw.Resource` wrapper resources (which AshCredo cannot scan).
No DDL change (define_attribute?(false) everywhere; FK attribute
allow_nil? already matches). For `allow_nil?: false` sites, Ash now
validates the relationship before persistence via
required_belongs_to_relationships.
```
