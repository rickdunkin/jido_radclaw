# Remove Folio GTD subsystem + Telegram channel adapter

## Context

The 2026-06-10 code review flags both features as needing work: **H16** (Folio resources have no authorization — any user reads every user's data) and **H14** (Telegram adapter is non-functional — its poll loop never runs), plus the Telegram halves of **M9/M10**. Neither feature will ever be used, so instead of fixing them we remove them entirely. This closes H14 and H16 by removal, shrinks the attack/maintenance surface, and drops three unused Postgres tables.

Exploration confirmed both removals are clean: **nothing** in tools, agents, prompts, skills, MCP, or tests depends on either feature. Folio is a self-contained Ash domain + LiveView; Telegram is a single adapter file with no startup path, no callers, and no mix dependency.

**User-confirmed scope decisions:**
1. **Purge Telegram legacy traces too** — remove `:telegram` from the Session `kind` enum AND the `telegram_*` filename mapping in the legacy JSONL import task (they must go together).
2. **Cut the dead channel scaffolding fully** — delete `Channel.Worker` and all of `Channel.Supervisor` (zero live callers; Discord bypasses them via `DiscordConsumer`), remove the producer-less per-tenant `channel_sup` DynamicSupervisor, and **repurpose `/channels`** to report Discord status instead of listing Workers that can never exist. Keep `Channel.Behaviour` (Discord `@impl`s it).

Suggested shape: **two commits** — `refactor: remove Folio GTD subsystem` and `refactor: remove Telegram channel adapter and dead channel scaffolding`. Stage only the files listed per workstream.

---

## Workstream 1 — Folio

### 1a. Delete files (atomic with 1b — tree only compiles with both done)

- `lib/jido_claw/folio.ex` (Ash domain; its `admin do` block is the only AshAdmin hook — deregistration is automatic once it leaves `ash_domains`)
- `lib/jido_claw/folio/action.ex`, `lib/jido_claw/folio/project.ex`, `lib/jido_claw/folio/inbox_item.ex`
- `lib/jido_claw/web/live/folio_live.ex` (sole consumer of the three resources)

### 1b. Single-line wiring edits

- `config/config.exs:248` — remove `JidoClaw.Folio,` from the `ash_domains` list (sole registration point)
- `lib/jido_claw/web/router.ex:100` — remove `live("/folio", FolioLive)` (resolves via the scope alias; nothing else to clean)
- `lib/jido_claw/web/components/layouts/app.html.heex:19` — remove the `<.link navigate="/folio" class="nav-link">Folio</.link>` nav entry
- `lib/jido_claw/web/live/dashboard_live.ex:68` — remove `<.button navigate="/folio">Folio Inbox</.button>` (no folio aliases in the module; nothing else to clean)
- `.reach.exs:16` — remove `"JidoClaw.Folio.*",` from the `data:` layer list (gates `mix reach.check` in precommit)

**Gate:** `mix jidoclaw.compile_check` must pass before 1c (expect "2 tolerated, 0 blocking" — verified green at baseline). Do NOT use `mix compile --warnings-as-errors`: it fails even at baseline on the two documented `PullRequestCoordinator` dead-`else` warnings.

### 1c. Generate the drop migration (verified against `ash_postgres` 2.9.1 source)

Leave `priv/resource_snapshots/repo/folio_*/` in place — the generator consumes and removes them. Optional courtesy check first (data loss is expected/accepted, tables are almost certainly empty): row counts via Tidewave `execute_sql_query` on `folio_projects` / `folio_actions` / `folio_inbox_items`.

```
mix ash.codegen drop_folio_tables
```

- It prompts **once per orphaned table** ("…no longer has a resource. Generate a migration to DROP this table?"). Answer **`y` three times**. Never answer `n` — that writes `drop_table_opted_out` into the snapshot and suppresses future prompts. Non-interactive fallback: `printf 'y\ny\ny\n' | mix ash.codegen drop_folio_tables` (there is no `--yes` flag; `--dev` and `--check` are unsuitable).
- It then **auto-deletes** the three `priv/resource_snapshots/repo/folio_*` directories and writes `priv/repo/migrations/<ts>_drop_folio_tables.exs`.
- **Inspect the generated migration:** only the three folio tables; `folio_actions` dropped **before** `folio_projects` (actions FK-references projects — the generator topo-sorts, but eyeball it); `down` recreates all three. FKs to `users` drop implicitly with the tables.

**Do NOT touch:**
- `priv/repo/migrations/20260321041920_create_folio_tables.exs` — keep; fresh DBs replay create→sync→drop cleanly. Deleting a historical create migration breaks fresh-DB replay.
- `priv/repo/migrations/20260414205523_sync_resource_snapshots.exs` — **shared** migration (also touches approval_gates, secret_refs, workflow_runs, …) with `IF [NOT] EXISTS` guards; its folio lines stay valid in the replay timeline.

Test/dev DBs need no manual reset: `mix test` → `ash.setup --quiet` → `ash_postgres.migrate` applies the drop automatically (snapshots are codegen inputs only, never read at migrate/test time).

---

## Workstream 2 — Telegram + dead channel scaffolding

### 2a. Delete files

- `lib/jido_claw/platform/channel/telegram.ex` (whole adapter; uses `:httpc`+Jason — **no mix.exs change**)
- `lib/jido_claw/platform/channel/worker.ex` (dead: only `start_channel/3` ever started it, which has zero callers; Discord runs via `DiscordConsumer` directly)
- `lib/jido_claw/platform/channel/supervisor.ex` (entire module: `start_channel/3` and `stop_channel/2` are dead, and with Worker gone `list_channels/1` can only ever return `[]` — its sole caller, `/channels`, gets reimplemented in 2c). Keep `behaviour.ex` and everything Discord (`discord.ex`, `discord_consumer.ex`, `application.ex` `maybe_start_discord`, nostrum config/dep).

### 2b. Remove the producer-less `channel_sup` from tenant supervision

`lib/jido_claw/platform/tenant/instance_supervisor.ex` — drop the `{DynamicSupervisor, name: channel_sup(tenant_id), …}` child spec (line 39) and the `channel_sup/1` accessor + `@spec` (lines 55-57). With `Channel.Supervisor` deleted it has zero producers and zero consumers; resurrecting later is a one-line child spec. Also reword the stale `lib/jido_claw/platform/messaging.ex:6-7` moduledoc, which claims messaging instances start "under the tenant's channel_sup" (nothing does).

### 2c. Repurpose `/channels` to report Discord consumer status

`lib/jido_claw/cli/commands.ex:631-646` — reimplement the handler (~10 lines): check `Supervisor.which_children(JidoClaw.Supervisor)` for id `JidoClaw.Channel.DiscordConsumer` and require **`is_pid(pid) and Process.alive?(pid)`** on the child tuple — `which_children` can report non-live states like `:restarting` (verified: its `child_spec` uses the module as id, matching how `start_discord_consumer/0` registers it at `application.ex:121`). Print the `Configure: DISCORD_BOT_TOKEN` hint when absent. **Word the output "Discord consumer running"** (or similar) — `which_children` proves the local consumer process exists, not that Discord is authenticated/online. Delete the now-unused `print_channel_row/1` helper (~line 1733). Update the help text at `lib/jido_claw/cli/branding.ex:228` from "List channel adapters" to e.g. "Show Discord consumer status", and the matching `docs/ARCHITECTURE.md:597` table row.

### 2d. Remove now-orphaned telemetry emitters

`lib/jido_claw/core/telemetry.ex:221-229` — `emit_channel_inbound/1` + `emit_channel_outbound/1` (Worker was their only caller; no handlers attach to those events). Drop any moduledoc/event-list mention alongside.

### 2e. Purge legacy traces (must go together)

- `lib/jido_claw/conversations/resources/session.ex:240` — remove `:telegram` from the `kind` `one_of` enum (app-level Ash constraint, not a PG enum — **no migration**)
- `lib/mix/tasks/jidoclaw.migrate.conversations.ex` — remove the `String.starts_with?(base, "telegram_")` cond clause (~line 280-281) and the `telegram_<chat_id>` line in the filename-prefix doc comment (~line 267). Old `telegram_*.jsonl` archives now fall through to the existing `:imported_legacy` catch-all.
- **Self-healing data migration** (hand-written, tiny): `mix ecto.gen.migration retire_telegram_session_kind`, written with explicit clauses — `def up do execute("UPDATE conversation_sessions SET kind = 'imported_legacy' WHERE kind = 'telegram'") end` and `def down, do: :ok` — matching the repo's migration style and keeping rollback behavior explicit. Any DB this ever runs against then can't hold rows that trip the narrowed enum. Dev DB is verified at 0 rows (adapter never worked), so this is a no-op locally — deploy insurance as a permanent safeguard instead of a one-off check.

### 2f. New regression test (cheap, committed)

No Telegram legacy-fallthrough test exists (`test/mix/tasks/jidoclaw_conversations_export_test.exs` already exercises the migrate task, but never with a `telegram_*` file). Add a case there (or alongside) asserting a `telegram_123.jsonl` legacy file imports as `kind: :imported_legacy` with `external_id: "telegram_123"` — documents the fallthrough and proves the narrowed enum doesn't crash the import path.

### 2g. Text/comment sweep (no logic)

- `config/config.exs:228` — drop the `# Telegram: TELEGRAM_BOT_TOKEN` comment line
- `.env.example:46-47` — drop the Telegram block
- Moduledoc/comment mentions of Telegram (prose only, no doctests): `lib/jido_claw.ex:4,73,454,458`, `platform/channel/behaviour.ex:3`, `platform/messaging.ex:6-7` (combined with the channel_sup reword from 2b), `conversations/resolver.ex:6`, `conversations/domain.ex:6`, `workspaces/resolver.ex:5`, `tool_context.ex:20`
- Stale `Channel.Supervisor`/channel-supervisor mentions now that it's deleted: `platform/tenant/instance_supervisor.ex:2` moduledoc ("each tenant has a channel supervisor"), `README.md:539` supervision-tree entry, `.jido/JIDO.md:57`

---

## Workstream 3 — Docs (living docs only)

- `README.md` — Folio: feature section ~323-341, bullets 38/47, file-tree lines 1088-1089/1202, lines 173/406/560/1261. Telegram/channels: setup section 826-832, env-table row 954, file-tree line 1145, bullet 47, supervision-tree line 539 (`Channel.Supervisor`).
- `AGENTS.md:105` — drop `and lib/jido_claw/folio/` from the Data Layer sentence (CLAUDE.md just `@`-includes AGENTS.md).
- `docs/ARCHITECTURE.md` — lines 108, 403, 597 (`/channels` row, per 2c), 673 (the aspirational `ChannelSupervisor → Channel.Worker` tree — now reflects DiscordConsumer reality), 754, 774.
- `docs/ROADMAP.md` — lines 7, 43, 54 (domain counts/tables).
- `.jido/JIDO.md` — line 39 (Discord/Telegram → Discord), line 57 (`Channel.Supervisor` entry — remove), line 77 ("Channel supervisor (Discord/Telegram)" — remove the channel-supervisor entry, don't just narrow it to Discord).
- `docs/reports/code-review-2026-06-10.md` — follow the doc's existing `✅ fixed 2026-06-10` convention: annotate **H14** and **H16** as resolved by removal (H14 note should mention the Worker/Supervisor/`channel_sup` scaffolding went too and `/channels` now reports Discord status); narrow **M9**/**M10** to Discord-only; update the threat-model line 30 (H16 mention), priority-order line 272 (H14), and the appendix line 292 ("Channel adapters and Folio have no tests").
- **Leave untouched** (historical records): `docs/plans/`, `docs/PLAN-v0.6-memory.md`, `docs/exploration/`.

`priv/defaults/system_prompt.md` has zero folio/telegram references — no change, and `jidoclaw.system_prompt.check` stays green.

---

## What explicitly stays (guardrails)

- Discord everything: `discord.ex`, `discord_consumer.ex`, `maybe_start_discord`, nostrum dep/config
- `Channel.Behaviour` (`behaviour.ex` — Discord `@impl`s all five callbacks)
- The other tenant supervisors in `instance_supervisor.ex` (`session_sup`, `cron_sup`, `tool_sup`) — only `channel_sup` goes
- Both existing migrations (create + shared sync)
- `mix.exs` deps — unchanged (no telegram dep exists)
- Historical docs

## Verification

1. `mix precommit` — covers `jidoclaw.compile_check`, `system_prompt.check`, format check, `credo --strict`, `reach.check --arch --smells --strict` (exercises the edited `.reach.exs`), `deps.unlock --unused`, dialyzer, and `mix test` (which auto-applies the drop migration to the test DB).
2. DB, existing dev DB: after migrate, confirm `\dt folio_*` is empty (Tidewave `execute_sql_query`).
3. DB, fresh replay (once): `mix ecto.reset` — proves the create→sync→drop timeline replays cleanly.
4. New test from 2f passes; full suite green (baseline: 2487 passed).
5. Runtime smoke (optional): boot the dashboard, confirm `/folio` 404s and the nav/quick-actions no longer show Folio; `/channels` in the REPL reports Discord status (running when `DISCORD_BOT_TOKEN` is set, otherwise the configure hint).
