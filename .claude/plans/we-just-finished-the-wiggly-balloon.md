# Plan: Remediate the three P4 channels-surface review findings

## Context

A code review of the argus P4 channels work (plan
`.claude/plans/this-sounds-reasonable-but-bright-rocket.md`) reported three
findings. Done criterion: `mix precommit` passes (plus the full UI gate, since
one finding touches `ui/`).

## Verification verdicts

**F1 (P1) — composer runs can stay visually `running` after terminalizing: VALIDATED.**
Composer parents get ZERO lifecycle broadcasts across their whole life:
`{:run_started, …}` is broadcast only by `reactor_middleware.ex:159` and the
composer never runs through the middleware (`create_parent_run/1` appends
`:run_started` inside its mint `Ash.transact`, `route_composer.ex:450-476`,
broadcasting nothing), and ALL twelve `route_*` terminal kinds plus the
abnormal-path `:run_failed` funnel through ONE choke point —
`append_parent_terminal/6` → `append_loaded_parent_terminal/6`
(`route_composer.ex:5434-5477`) — which returns bare `:ok` post-commit with no
RunPubSub call. `WorkflowLog.append` does no PubSub by design; the channel's
five-kind allowlist (`workflows_channel.ex:36`) would drop `route_*` kinds
anyway. Cancellation/Cases already broadcast their own terminals
(`:run_cancelled`/`:run_abandoned` — the "cancellation e2e" the reviewer saw),
so the gap is exactly the composer's own start + terminals. Park paths keep
the parent `:running` by design (the durable case row IS the park
representation; `workflow_log.ex:228-233`) — nothing to broadcast on park.

**F2 (P2) — missing-token WS attempts unaudited: VALIDATED.**
`argus_socket.ex:36-37` returns `{:error, :missing_api_key}` on nil token
BEFORE `authenticate_api_key/1` — the only socket path that emits audit rows.
Both moduledocs promise one `:auth_event` per attempt
(`argus_socket.ex:15-16`, `api_key_auth.ex:41-44`); the HTTP plug emits the
`missing_api_key` failure itself in its else branch (`api_key_auth.ex:29-31`),
the socket emits nothing.

**F3 (P2) — /runs may never discover new runs after navigation: VALIDATED.**
`ui/src/routes/runs.tsx:31-33` passes no `fetchPolicy` (and `apollo.ts` sets no
`defaultOptions`) → Apollo default `cache-first`; the production client is a
`main.tsx:9` singleton that persists across navigation; the channel-opening
effect (`runs.tsx:84-135`) early-returns when there are zero non-terminal ids.
So after `/runs` caches an empty or all-terminal list, remounting serves
entirely from cache — no network request, no channels — and new runs stay
invisible until hard reload. Confirmed against @apollo/client 4.2.6: `refetch`
still forces network under `cache-and-network`, `notifyOnNetworkStatusChange`
defaults true in v4, and no `fetchPolicy` precedent exists yet in ui/src.

## Decisions taken (one sensible path — logged for veto, not blocking)

1. **Composer terminals map onto the existing five broadcast kinds by status
   family** (completed → `:run_completed`, failed → `:run_failed`, cancelled →
   `:run_cancelled`) instead of adding new `route_*` wire kinds. Zero new
   message shapes on `orchestration:run:*`/`orchestration:runs` (dashboard and
   `run_await` subscribers already handle these five), the channel allowlist
   stays five, and the client refetches via GraphQL where the amber
   `disposition` already lives (camus C1-4). The allowlist is CENTRALIZED into
   RunPubSub so producer kinds and the channel can't drift.
2. **`:route_abandoned` broadcasts `:run_cancelled`, not `:run_abandoned`** —
   it projects to status `:cancelled` (`projection.ex:180-181`), and the
   broadcast kind must agree with the durable status the payload carries.
3. **Park/resume residual RETAINED** (reviewer asked retain-or-remove): parks
   are deliberately status-less (parent stays `:running`), so there is no
   status-authority event to publish; step/park deltas remain slice 1. The
   residual text is re-worded, not deleted.

## Remediation plan

### Fix 1 — complete lifecycle publication for composer runs (F1)

Durable-then-notify at both seams (`docs/TRUST-BOUNDARIES.md` discipline;
broadcasts best-effort, return values discarded, never touching the durable
result — the cancellation.ex:281-291 / gate_disposition.ex:291-310 precedent).

- `lib/jido_claw/orchestration/run_pubsub.ex`:
  - Add the canonical kind inventory: `@lifecycle_kinds [:run_started,
    :run_completed, :run_failed, :run_cancelled, :run_abandoned]` + public
    `lifecycle_kinds/0`.
  - Add `broadcast_run_started(%WorkflowRun{} = run)` — a construction-site
    sibling of `broadcast_run_terminal/3` emitting `{:run_started, run.id,
    %{tenant_id, name, workflow_type, status: :running, completed_at: nil}}`
    via `broadcast/2` (both topics, same as terminals).
- `lib/jido_claw/web/channels/workflows_channel.ex`: source the allowlist —
  `@lifecycle_kinds RunPubSub.lifecycle_kinds()` (compile-time attr; the
  `handle_info` guard is unchanged). Update the producer-inventory comment
  (`:33-35`) to include the composer.
- `lib/jido_claw/orchestration/workflow_event/projection.ex`: expose the
  committed terminal status for an appended terminal kind (e.g.
  `route_terminal_status/1` built from the SAME `@route_failed_kinds` /
  `@route_cancelled_kinds` / converged lists that drive `next_status/2`, plus
  `:run_failed → :failed`) — single-sourced status authority; the composer
  never re-derives family by hand. (A successful append guarantees this is
  the status that committed — `:illegal` transitions roll the append back.)
- `lib/jido_claw/route_composer/route_composer.ex`, two seams:
  - **Start**: `reload_running_parent/3` success arm (`:1129-1130`, the first
    post-`Ash.transact` point, reloaded `:running` row in hand; all producer
    entrances funnel through `create_parent_run/1` and boot recovery never
    re-mints) → `RunPubSub.broadcast_run_started(running)`. This satisfies the
    reviewer's "only after the outer Ash.transact commits" verbatim.
  - **Terminal**: `append_loaded_parent_terminal/6`'s `{:ok, _event}` arm
    (`:5473`, post-commit by `WorkflowEvent`'s `transaction?(true)`): map the
    appended kind → committed status (Projection helper) → **`wire_kind`**
    (family map, decision 1/2 — the name distinguishes it from the durable
    event `kind` throughout); reload-once for the fresh `completed_at`,
    degrading to the pre-append `parent` snapshot on a freak reload failure
    (status passed explicitly — the `broadcast_run_terminal/3` doc's own
    rule) → `RunPubSub.broadcast_run_terminal(reloaded, wire_kind, status)`.
    **Guard (explicit)**: the whole mapping → reload → broadcast tail is
    TOTAL and best-effort — the Projection helper has an explicit unknown
    branch, and an unmappable kind or any reload/broadcast failure logs
    loudly and skips; it must NEVER turn the successfully persisted terminal
    into an error (the choke point's `:ok` is already durable truth).
    The already-terminal `:ok` short-circuit (`:5454-5455`) must NOT
    broadcast — that's the finish-vs-timeout race double-fire guard. Covers
    BOTH callers (loop terminals via `parent_terminal_notify/4`, abnormal
    `:run_failed` via `terminalize_parent/5`) with one seam.
- **Tests (red→green)**:
  - Producer-to-channel e2e in `test/jido_claw/web/workflows_channel_test.exs`
    (the reviewer's "direct test broadcasts are insufficient"): mint a parent
    via `RouteComposer.create_parent_run/1` (fixtures
    `TestFixtures.base_opts/1`), `subscribe_and_join` `workflows:run:<id>`,
    launch the REAL loop via `ensure_started/2` with the stub-worker arming
    (`composer_durable_test.exs:57-103,537-550` template), then
    `assert_push "run_event", %{id: ^parent_id, kind: :run_completed}` with a
    generous timeout + `refute_push` duplicate (double-fire guard). RED today.
    **Immediately after the push, re-read the run** (`WorkflowRun.by_id`) and
    assert terminal `status` + non-nil `completed_at` — directly proving
    durable state is visible before notification (durable-then-notify, law-2
    posture).
  - `run_started` producer test: `RunPubSub.subscribe_all()` →
    `create_parent_run/1` → `assert_receive {:run_started, id, %{status:
    :running}}` (id == parent.id) — channel-side `run_started` delivery is
    already pinned by the five-kinds proxy test.
  - Pure unit for the Projection mapping over all 13 kinds (cancelled-family
    e2e already exists in `cancellation_test.exs:59-130`).
  - Raw `WorkflowLog.append` stays broadcast-free (janitor/no-broadcast stance
    unchanged — the broadcast lives in the composer, not the log).

### Fix 2 — audit missing-token WebSocket attempts (F2)

- `lib/jido_claw/web/plugs/api_key_auth.ex`: add public
  `missing_api_key_failure/0` — emits `emit_auth_event(:api_key_sign_in_failure,
  nil, %{reason: "missing_api_key"})` and returns `{:error, "missing_api_key"}`
  (sibling of the existing private `invalid_key_failure/0`). The plug's
  `call/2` else branch consumes it instead of its inline emission (`:29-31`),
  so HTTP behavior is unchanged: still exactly one row per attempt.
  Update the `authenticate_api_key/1` @doc contract wording to cover the
  missing-key path explicitly.
- `lib/jido_claw/web/channels/argus_socket.ex:36-37`: the nil-token branch
  calls `ApiKeyAuth.missing_api_key_failure()` (result discarded) before
  returning `{:error, :missing_api_key}` — one audit row per refused attempt,
  matching the moduledoc's stated contract.
- Tests (`test/jido_claw/web/argus_socket_test.exs`, red→green): reuse the
  house pattern from `api_key_auth_test.exs:38-43` (baseline `:auth_event`
  count + `eventually` delta == 1 + `latest_auth_event` row asserts):
  - **Split the existing missing-token test (`:70-75`)** — it currently makes
    TWO connect attempts (bare `connect(ArgusSocket, %{})` and the
    params-carried key, which never authenticates) in one test. Restructure
    to ONE connect attempt per test, each with its own baseline capture and
    its own exactly-one `api_key_sign_in_failure` / reason `"missing_api_key"`
    assertion (RED today — zero rows), the `eventually` poll guaranteeing the
    async audit row has landed before the test exits (both attempts are
    nil-token post-fix, so each must emit exactly one row).
  - invalid-key connect emits exactly one failure with reason
    `"invalid_api_key"` (closes the review's "valid, invalid, and missing each
    produce exactly one" triple — valid-side already covered at `:95-120`).
  - `test/jido_claw/web/plugs/api_key_auth_test.exs` must pass unchanged
    (the P4 plan's own invariant).

### Fix 3 — `/runs` refreshes on route entry (F3)

- `ui/src/routes/runs.tsx:31-33`: add `fetchPolicy: "cache-and-network"` to
  the `useQuery` options — cached rows render immediately, every route entry
  fires the network leg, and the refetch-on-`run_event` path is unaffected
  (Apollo 4.2.6: `refetch` stays network under `cache-and-network`;
  `notifyOnNetworkStatusChange` already defaults true in v4). First
  `fetchPolicy` use in ui/src — no defaultOptions precedent to follow.
- Regression test (`ui/src/runs.test.tsx`, red→green): one `MockedProvider`
  (its constructor builds a single persistent client — matches the `main.tsx:9`
  production singleton) wrapping `RouterProvider` over
  `createMemoryHistory({ initialEntries: ["/runs"] })`; keep the `router`
  reference (extend `renderRuns` or build inline — it currently drops it).
  Two ordered mocks for `{ query: RecentWorkflowRunsDocument, variables:
  { limit: 50 } }`: first `[]` ("No runs yet.", zero channels since
  `activeKey` is empty), second `[pending run row]`. Navigation is AWAITED,
  never fire-and-forget —
  `await act(async () => { await router.navigate({ to: "/" }) })` — and the
  test asserts the index route has settled (its content rendered) BEFORE
  navigating back to `/runs` the same awaited way, so the remount can't race
  the assertion. Then: under cache-first mock #2 is never consumed and
  "No runs yet." persists (RED); under cache-and-network the remount
  consumes mock #2 and the row renders (GREEN). Import from
  `"vite-plus/test"` (lint-enforced); no navigation test precedent exists —
  this sets it.
- `projects.tsx:10-12` has the identical cache-first exposure but no live
  requirement — out of scope per the review; noted for a follow-up.

### Fix 4 — docs riders (same change, machine-enforced pairing)

- `docs/system/channels-surface.md`: `:56-60` contract sentence + `:100`
  "every refused connect writes a durable audit row" become true — keep,
  tighten wording; `:75-87` allowlist inventory + `:125-128` runs-page
  mechanics + `:156-158` telemetry note updated per Fix 1/3;
  residual `:168-170` re-worded (navigation now genuinely refetches; the
  remaining gap is only "no runs-list topic until slice 1"); residual
  `:171-174` park/resume — RETAIN explicitly (park keeps the parent
  `:running`; broadcasting step/park deltas stays slice 1) with wording
  updated for composer terminals now broadcasting. `verified:` re-dated.
- `AGENTS.md` channels bullet (`:120`): "kind allowlisted to the five
  lifecycle broadcasts" stays literally true (family mapping keeps the set at
  five) — amend it to say composer runs now publish start/terminals and the
  inventory is centralized in RunPubSub; "one `:auth_event` per attempt"
  stays (now actually true).
- `docs/exploration/argus/OVERVIEW.md` `:344` table row ("published by
  `ReactorMiddleware`"), `:202`, `:612` run-lifecycle publication claims +
  `DECISIONS.md:87-91` (exact-allowlist wording) corrected for composer
  broadcasts. Then a stale-restatement sweep (the false-invariant memory
  rule): `rg` docs/ + lib/ moduledocs for "published by ReactorMiddleware",
  "nothing broadcasts", composer-never-broadcasts claims, and check
  `docs/system/terminal-statuses.md` for any no-broadcast claim the fix
  invalidates.
- `docs/plans/argus-ui-bootstrap/README.md` `### P4 (implemented 2026-07-11)`
  deviations record (`:488-569`): add three review-driven entries (forced
  corrections) — lifecycle publication gap (the P4 plan's "exact inventory"
  claim missed that composer parents never ride the topic), missing-token
  audit miss (the zero-audit nil branch was in the plan as specified),
  and the cache-first navigation staleness. The bright-rocket plan file has
  no Deviations section — the README P4 record is the deviations home.

## Implementation order

Fix 2 (small, isolated) → Fix 1 (backend core) → Fix 3 (UI) → Fix 4 (docs) —
each with its regression test written first and confirmed RED before the fix.
Deviations from this plan get logged under `## Deviations` in this file as
they happen.

## Verification

- Targeted tests, red→green per fix:
  `mix test test/jido_claw/web/argus_socket_test.exs
  test/jido_claw/web/plugs/api_key_auth_test.exs
  test/jido_claw/web/workflows_channel_test.exs
  test/jido_claw/route_composer/composer_durable_test.exs
  test/jido_claw/orchestration/cancellation_test.exs` (+ any new files).
- Full UI gate: `pnpm --dir ui codegen` && `check` && `test` && `build` —
  all four; precommit is node-free, so the UI finding is proven here.
- Full `mix precommit` (the done criterion) — run bare, never piped; report
  exact exit code + counts verbatim. Rotating-flake policy per memory: one
  unrelated timing test with all stages green → single re-run; the same test
  red twice → treat as real and fix.
- `docs/system` pairing: `mix jidoclaw.system_docs.check` rides precommit
  (channels-surface.md `verified:` re-dated in the same change).

## Deviations

- **`route_terminal_status/1` shape (forced correction, 2026-07-11)**: the
  plan's "plus `:run_failed → :failed`" landed first as an
  `or kind == :run_failed` term in the failed-family guard; reach's smell
  gate (`guard compares parameter to literal with ==`) failed precommit and
  forced `:run_failed` into its own pattern-matched function head (placed
  before the family guards). Semantics identical — all 13-kind projection
  unit tests unchanged and green.
- **Invalid-key audit assertion extended the existing socket test** rather
  than adding a separate test — keeps one-connect-per-test with its own
  baseline, same coverage the plan asked for ("valid, invalid, and missing
  each produce exactly one").
- **Sweep catches beyond the plan's named files**: the false-claim sweep
  also corrected `lib/jido_claw/cli/run_await.ex`'s moduledoc ("does not
  broadcast") and `docs/exploration/osa/FEATURES-WORTH-BORROWING.md`'s
  OQ-4 answer parenthetical ("composer-parent terminals don't broadcast") —
  both now state broadcasts exist but are best-effort, polling stays
  authoritative. `docs/system/terminal-statuses.md` carries no broadcast
  claims (checked, no edit needed).
- **Round-2 review P1 (forced correction, 2026-07-11)**: the plan's
  "best-effort — return values discarded" posture was insufficient:
  `Phoenix.PubSub.broadcast/3` RAISES while its registry is down
  (`{:ok, _} = Registry.meta(...)` in the dep), so a PubSub restart could
  fail `create_parent_run/1` after the mint committed or crash the
  composer after its terminal committed. Both seams now run under
  `RouteComposer.notify_best_effort/3` (public `@doc false`, the
  `read_error_reason/1` unit-coverage precedent): logs returned errors AND
  catches raises/exits/throws, always `:ok`. Red→green via a
  deterministic e2e that stops the PubSub child under the one_for_one
  `JidoClaw.InfraSupervisor` during `create_parent_run/1` (RED reproduced
  the reviewer's exact `ArgumentError: unknown registry` escaping
  post-commit) + direct shield unit tests (error tuple / raise / exit /
  throw). Same exposure exists pre-dating this change in
  cancellation/cases/gate_disposition's direct `broadcast_run_terminal`
  calls — out of scope here, noted for follow-up.
