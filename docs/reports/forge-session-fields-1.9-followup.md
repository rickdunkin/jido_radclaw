# Bug 1.9 follow-up — Forge session UI fields that can only ever be 0 / nil

**Status:** deferred from the 2026-07-04 audit §1 bugfix batch (needs a product
decision + a DB migration; the batch was intentionally migration-free).
**Source:** `lib/jido_claw/forge/resources/session.ex`.

The Forge dashboard renders two session columns that are structurally incapable
of holding a non-default value, plus three dead Ash actions that ride along.
Captured here so the deferral carries its own implementation notes and the
findings need not be rediscovered.

## Findings (re-verified against source)

### `execution_count` is always 0

- The only writer is `set_attribute(:execution_count, 0)` in the `:start`
  action (`session.ex:82`), and it is in `upsert_fields` (`session.ex:75`), so
  every wake / re-upsert re-zeroes it. No increment exists anywhere.
- Read at `forge_view.ex:126`, rendered at `forge_live.ex:38` (under the
  "Executions" `<th>`).

### `last_error` is always nil

- Writers are `set_attribute(:last_error, nil)` in `:start` (`session.ex:81`,
  also in `upsert_fields`) and `set_attribute(:last_error, arg(:error))` in
  `:mark_failed` (`session.ex:100`) — but **`:mark_failed` has zero callers.**
- Failures route through `Persistence.update_session_phase/2`
  (`persistence.ex:271`, the `:update_phase` action), which never touches
  `last_error` (e.g. `manager.ex:123`, harness terminal `harness.ex:799`).
- Doubly dead: the map key it is put into (`forge_view.ex:130`) has no reader
  either.

### Three dead Ash actions ride along

- `:mark_failed` — no callers (see above).
- `:cancel` — cancellation uses `update_session_phase(:cancelled)` instead.
- `:list_active` — `ForgeView` filters phases directly at
  `forge_view.ex:105-116`.

All three have zero prod callers.

## Two resolution paths

### Delete path (smaller, recommended if the dashboard does not need live values)

- Drop the `execution_count` + `last_error` attributes
  (`session.ex:220-229`).
- Remove both from `upsert_fields` (`session.ex:74-75`) and their
  `set_attribute` changes (`session.ex:81-82`).
- Delete `:mark_failed` (`session.ex:95-102` + its `define` at `session.ex:44`),
  optionally `:cancel` (`session.ex:112-117` + define at `session.ex:46`) and
  `:list_active` (`session.ex:127-143` + define at `session.ex:48`).
- Remove the two render cells (`forge_view.ex:126,130`,
  `forge_live.ex:30,38`).
- **Requires an Ecto migration** to drop the two columns. Tiny consumer
  surface.

### Wire path (make the values real)

- Remove `:execution_count` from `upsert_fields` and drop the `:start`
  zero-set (the `default(0)` at `session.ex:223` covers genuine creates); add

  ```elixir
  update :record_execution do
    change atomic_update(:execution_count, expr(execution_count + 1))
  end
  ```

  plus a `code_interface` define, and **call it at execution completion** — the
  ambiguous part is *where* "an execution" is (harness running→ready seam
  ~`harness.ex:465/496`).
- For `last_error`, route terminal failures through `:mark_failed` (or extend
  `update_session_phase` to accept an error string) and thread the error text to
  the terminal call site.

## Test conventions if picked up

- `test/jido_claw/forge_view_test.exs` (`use JidoClaw.TenantCase, async: false`,
  `Persistence.record_session_started/2` seeding).
- A new `test/jido_claw/forge/session_test.exs` could unit-test the increment /
  `:mark_failed` actions directly.
