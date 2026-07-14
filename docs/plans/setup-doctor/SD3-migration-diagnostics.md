# SD3 — Migration diagnostics

*Builds: the compile-time migration manifest + the bounded read-only DB
status probe + the scratch-repo test infrastructure. Depends on: nothing —
fully parallel to SD1/SD2. Contracts owned: INV-11, INV-18, ST-6, HD-8,
HD-9. Separate workstream because it introduces packaging (escript) and
database-contract concerns nothing else in the group carries.*

> **What this owns.** `Doctor.migration_status/1` — answering "is this
> database migrated, drifted, or unreadable" without mutating anything,
> without hanging on a lock, without booting the app tree, and correctly
> from an escript that bundles no `priv/`. Plus the first-of-kind
> scratch-repo test pattern the probe needs (migrations can't run under the
> SQL sandbox — `[[project_gate_scope_facts]]`).

## Current state

- No health surface reads migration status today; pending migrations crash
  full boot before any diagnostic speaks.
- `Ecto.Migrator.migrations/3` cannot be bounded (HD-9): the versions SELECT
  runs `timeout: :infinity`, so a stuck `ACCESS EXCLUSIVE` holder would hang
  a doctor built on it.
- `Ecto.Migrator.with_repo/3`'s cleanup RESTARTS a repo it found already
  running (`migrator.ex:846-851`) — unusable as-is for a probe that must
  leave a running system untouched.
- The escript bundles no `priv/` (`main.ex:42-44`) — any directory-listing
  inventory would report a cold DB "fully migrated" from the escript (INV-11).

## Design

### 1. `MigrationManifest` — the one local inventory (INV-11)

A generated module (`@external_resource` over `priv/repo/migrations`;
`{version, name}` pairs; 56 entries today) serving mix, REPL, and escript
alike. A dev/test-env test pins manifest ≡ the live directory listing so it
can never silently go stale.

### 2. Own-start claim, not a whereis branch

`migration_status/1` takes the repo module (never hardcoded `JidoClaw.Repo`;
dynamic repos + `:migration_repo` documented OUT of scope in the `@doc` —
the probe targets JidoClaw's repository layout and goes `:unavailable` on
nonstandard config rather than answering wrong). Claim via
`repo.start_link(pool_size: 2)`:

- `{:ok, pid}` → **`Process.unlink(pid)` immediately** (a repo crash must
  surface as probe errors, not kill the caller); probe inside `try/after`
  whose `after` stops EXACTLY the claimed pid.
- `{:error, {:already_started, _}}` → probe directly, NO cleanup (pin: pid
  identical before/after).

Replicates `with_repo`'s app-start preamble (`:ecto_sql` + adapter apps)
without its restart-child cleanup.

### 3. Bounded, lock-free, bidirectional listing (INV-18)

Table name + prefix derive from repo config (`:migration_source` default
`"schema_migrations"`, prefix default `public`). Then:

1. Bounded `to_regclass` existence check (5s, injectable) — absent → ALL
   manifest migrations pending (no DDL ever issued).
2. `count(*)` first — implausible vs the manifest (manifest + slack) →
   `:unavailable` naming the count.
3. Ordered `SELECT version … LIMIT <manifest + slack + 1>` (all
   `timeout: 5_000`).
4. Duplicate detection via bounded `GROUP BY version HAVING count(*) > 1
   LIMIT 1` — duplicates on either side → `:unavailable` with the
   duplicates named, never set-collapsed.
5. Bidirectional compare: local-not-in-DB → pending count (`:gap`, "run
   `mix ecto.migrate`", `repairable?: false` — print-only by decision);
   **DB-not-in-local → `:migration_drift`** (`:gap`, `repairable?: false` —
   Ecto's `** FILE NOT FOUND **` state; wrong-branch guidance; fails
   `healthy?/1`).

Migration locks never block a plain SELECT under MVCC; an `ACCESS EXCLUSIVE`
holder blocks only until the timeout → rescued `:unavailable`. DB/server
absent → `:unavailable`, never a crash.

## Decisions

- **D1 — pending migrations stay print-only.** Bound by the 2026-07-12
  interview: the doctor never runs `ecto.migrate` — the gap prints the
  command. (Recorded here because it looks repairable; it isn't, by
  decision.)
- **D2 — slack constant.** The count/LIMIT bounds use `manifest + slack`;
  pick slack (suggest a small constant, e.g. 100) at build and record it in
  the `@doc` + Deviations.

## Test plan

Async: false, first-of-kind (HD-8, ST-6): `test/support` ScratchRepo
(`use Ecto.Repo, otp_app: :jido_claw, adapter: Ecto.Adapters.Postgres`, zero
Ash wiring), config derived from `JidoClaw.Repo.config()` via
`Application.put_env`, `pool: DBConnection.ConnectionPool`, **`priv:
"priv/repo"`** (else Ecto derives `priv/scratch_repo/migrations` and reports
zero pending), scratch DB name embedding `MIX_TEST_PARTITION`; tolerate
`{:error, :already_up}`; `storage_down` in `on_exit`. Rows — ALL on the
scratch repo, never `JidoClaw.Repo`:

- cold DB → all local pending AND `to_regclass` still null (no DDL);
- own-start claim → repo process ABSENT after success AND after an injected
  raise; caller survives both; already-started → pid IDENTICAL before/after;
- `ACCESS EXCLUSIVE` contention → timely `:unavailable` (test holds the
  lock);
- equivalence pin vs a real `Ecto.Migrator.migrations/3` run, including a
  hand-INSERTed bogus version → `:migration_drift`;
- hand-INSERTed DUPLICATE version → `:unavailable` with the duplicate named;
- high-cardinality scratch table (tens of thousands of rows) →
  `:unavailable` from the bounded count; client memory NOT scaling with
  table size;
- the manifest ≡ directory pin.

Verify the file alone first, then once under `scripts/test-partitioned.sh`
(partition safety is the point of the DB-name embedding).

## Docs & reconciliation (lands with this WS)

- No system page yet; SD4 absorbs the probe's bounds + drift semantics into
  `docs/system/setup-doctor.md` (OD-2).
- Record the ScratchRepo pattern in the test file's moduledoc — it is the
  repo's first `storage_up` precedent and the next standalone-DB test will
  copy it.
- `## Deviations` maintained in this doc as built.

## Cross-references

- [CONTRACTS.md](CONTRACTS.md) — INV-11, INV-18, ST-6, HD-8, HD-9.
- [SD4](SD4-read-only-doctor.md) — the `:database` check consumes
  `migration_status/1`; the doctor's `:unavailable`/`:gap` mapping lives
  there.
- Memory: `[[project_gate_scope_facts]]` (migrations can't run under the SQL
  sandbox — the standalone-script/scratch-repo constraint this WS's test
  infra exists for).
