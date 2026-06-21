# AR-2 Composer — Phase 3 review fixes (P1 sensitive marking, P2 context fallback)

## Context

The just-shipped AR-2 Phase 3 work (the AR-8 triage front door + composer pre-run
seeding, plan `please-review-docs-exploration-alp-river-shiny-journal.md`) passed a
code review with **two validated findings**. Both are confirmed real against the
current tree:

- **[P1 — security/leakage]** `JidoClaw.FrontDoor` is the sole user-turn composer
  launcher, but the launch opts it builds (`front_door.ex:98-116`) never set
  `sanitize_sensitive_context: true` / `deadline_ms`. The composer's sensitive-run
  scrubber is fully built and tested (`sensitive_route_test.exs`) and gated exactly
  on those two keys — so a `:secrets`-signalled `code`/`system` turn enters the
  composer **unmarked**, and `SubagentTranscript.scrub_turn/2`
  (`subagent_transcript.ex:156-160`) persists derived task/result plaintext as-is in
  durable sinks. (Decision: **mark sensitive + bounded deadline** — keep the turn in
  the composer with its review gates, but redact durable derived plaintext and
  time-bound the run, using the purpose-built, already-tested machinery. The
  finding's other option — keep `:secrets` turns *out* of the composer until a
  dedicated policy exists — would block the feature now or fall back to the
  less-controlled inline path; marking sensitive resolves the leak without either.)

- **[P2 — correctness]** `build_start_opts/2` (`route_composer.ex:653`) unconditionally
  overwrites `:context` with `restore_context(config["context"])`, which is `%{}`
  when a minimal parent's config has no `"context"`. This **discards an explicit
  caller `opts[:context]`**, violating the documented `start_composer/2` optional
  `:context` contract. It bites the "create minimal parent, then start with context"
  lifecycle (e.g. `composer_durable_test.exs:208-257`). The sibling bounds
  (`:premises`/`:max_waves`/`:wave_timeout_ms`) already use `config[...] || opts[...]
  || default`; `:context` is the lone exception.

**Done bar:** `mise exec -- mix precommit` succeeds.

---

## Fix 1 — P1: mark `:secrets` verdicts sensitive + bounded deadline

A `:secrets` early signal (∈ `verdict.signals`) marks the launched composer run
sensitive and gives it a bounded wall-clock deadline. The two are **coupled** —
`create_parent_run` rejects a marked run with no positive `:deadline_ms`
(`validate_sensitive_deadline/2`, `route_composer.ex:318-323`) — so they are set
together. Non-secrets runs stay unmarked and unbounded (today's behavior). Everything
downstream (durable config persistence at `parent_config/3`, recovery restore at
`build_start_opts/2`, wave threading, the six scrub sinks) is already wired to carry
the two keys — the only gap is the front door not setting them.

### `config/config.exs` (after the `:triage_model` knob, ~line 214)
Add the configurable deadline (30 min default, per decision):
```elixir
# AR-8 triage: a `:secrets`-signalled code/system turn launches its composer run
# marked sensitive (the scrubber redacts derived plaintext in every durable sink)
# and bounded by this wall-clock deadline (ms) — which also caps how long
# secret-bearing request-correlation state lives. A marked run REQUIRES a positive
# deadline (RouteComposer.validate_sensitive_deadline/2), so the two are set
# together in JidoClaw.FrontDoor. Non-secrets runs stay unmarked and unbounded.
config :jido_claw, :triage_sensitive_deadline_ms, 1_800_000
```

### `lib/jido_claw/front_door.ex`
- Add a module attribute beside `@history_window`/`@preview_max` (line 44-45):
  `@default_sensitive_deadline_ms 1_800_000` (in-code fallback, mirrors how
  `:triage_model` keeps a `:fast` default — REPL/test-safe if config is stripped).
- In `start_composer/3`, compute `sensitive?` once and use it for **both** the opts
  marking and the ack wording (the ack must not echo the intent for a sensitive run —
  see below):
```elixir
intent = present(verdict.intent) || message
path = verdict.path
sensitive? = :secrets in verdict.signals

opts =
  [
    # … unchanged keyword list (lines 98-116) …
  ]
  |> mark_sensitive(sensitive?)

with {:ok, parent} <- composer().create_parent_run(opts),
     {:ok, _pid} <- composer().ensure_started(opts, parent) do
  {:ok,
   %{path: path, parent_run_id: parent.id, message: ack_message(path, intent, parent.id, sensitive?)}}
else
  # … unchanged bounded error-ack branch …
end
```
- Add the helpers near the other small helpers:
```elixir
# `:secrets` ∈ signals → mark sensitive + a bounded deadline. The scrubber then
# redacts derived plaintext in every durable sink and the deadline caps secret-state
# lifetime. `create_parent_run` rejects a marked run with no positive `:deadline_ms`
# (validate_sensitive_deadline/2), so both are set together; a non-secrets run is
# returned unchanged (unmarked, unbounded — today's behavior).
defp mark_sensitive(opts, true),
  do: Keyword.merge(opts, sanitize_sensitive_context: true, deadline_ms: sensitive_deadline_ms())

defp mark_sensitive(opts, false), do: opts

defp sensitive_deadline_ms do
  Application.get_env(:jido_claw, :triage_sensitive_deadline_ms, @default_sensitive_deadline_ms)
end

# A sensitive run's ack must NOT echo the intent: marking the run sensitive scrubs
# durable sinks, but the ack string itself bypasses that pipeline and goes straight
# to the surface, so a secret-bearing intent could leak through preview/1.
defp ack_message(path, _intent, run_id, true),
  do: "Starting a sensitive #{path} run (run #{run_id})."

defp ack_message(path, intent, run_id, false),
  do: "Starting a #{path} run for: #{preview(intent)} (run #{run_id})."
```
Marking keys directly off `:secrets in verdict.signals` (independent of
`mapped_signals/1`, which only governs the `live` topic emission). `Keyword.merge`
of a keyword list — no new map shape, so no `fixed_shape_map` exposure.

### Tests — `test/jido_claw/front_door_test.exs`
The setup runs `:front_door_create_mode = :delegate` (real `create_parent_run`) +
`:front_door_ensure_mode = :noop`, so the parent is really created and `parent.config`
is assertable (mirror `sensitive_route_test.exs:154`). **Add `triage_sensitive_deadline_ms`
to the setup's saved/restored env-key list** (the `Map.new(~w(...)a, …)` at line 37-42)
so the fail-closed test's override is auto-restored. Add a describe block reusing the
existing `canned/1` + `reload/2` helpers:
- **positive (marked + bounded + ack omits intent):**
  `canned(%Verdict{path: :code, signals: [:secrets]})`, then
  `decide("rotate SUPERSECRETTOKEN42 in config", ctx)` → launched parent has
  `config["sanitize_sensitive_context"] == true` and `is_integer(config["deadline_at_ms"])`;
  the ack `msg =~ "sensitive"` and **`refute msg =~ "SUPERSECRETTOKEN42"`** (the sensitive
  ack never previews the intent — tweak 3).
- **negative (no over-marking + normal ack):**
  `canned(%Verdict{path: :code, signals: [:auth_surface]})` →
  `refute config["sanitize_sensitive_context"] == true`,
  `refute Map.has_key?(config, "deadline_at_ms")` (an unmarked run sets no deadline —
  `deadline_config/1` only stamps `deadline_at_ms` for a positive `ms`), and the ack
  still previews the intent (`refute msg =~ "sensitive"`, `assert msg =~` the intent).
- **fail-closed on an invalid deadline (the mark-requires-deadline contract):** in the
  existing `chat/4 turn seam` describe (which wires the `ask_runtime`/`dispatch_capture`
  stub), `canned(%Verdict{path: :code, signals: [:secrets]})` +
  `Application.put_env(:jido_claw, :triage_sensitive_deadline_ms, 0)`, then
  `JidoClaw.chat(...)` → `validate_sensitive_deadline(true, 0)` rejects the launch
  *before any parent is created* → `{:ok, msg}` with `msg =~ "couldn't start"` **and
  `refute_receive {:dispatch_capture, _, _, _}, 300`** (fail-closed: bounded ack, the
  mutation-capable inline agent is never invoked). `:front_door_create_mode` stays at
  the setup default `:delegate` so the real validation runs.

---

## Fix 2 — P2: honor an explicit launch `:context` when config has none

Config stays authoritative on recovery (which carries no `opts[:context]`); fall back
to the caller's `opts[:context]` only when config has no persisted `"context"`.

### `lib/jido_claw/route_composer/route_composer.ex`
- Line 653: `|> Keyword.put(:context, restore_context(config["context"]))`
  → `|> Keyword.put(:context, start_context(config["context"], opts[:context]))`.
- Add the helper next to `restore_context/1` (after line 672):
```elixir
# Config is authoritative (recovery carries no opts context): restore the persisted,
# re-atomized subset when present. When config has no "context" — the minimal
# `create_parent_run(tenant:, actor:)`-then-start-with-context launch path, which
# persists no subset — fall back to the caller's opts context (mirroring the
# `config[...] || opts[...]` shape the sibling bounds already use), so an explicit
# launch `:context` is honored rather than clobbered to %{}.
defp start_context(nil, opts_context) when is_map(opts_context), do: opts_context
defp start_context(nil, _opts_context), do: %{}
defp start_context(config_context, _opts_context), do: restore_context(config_context)
```
Recovery is unchanged (config present → restore; both absent → `%{}`); the *only*
behavior change is "config absent **and** opts context present" → use opts context.

### Test — `test/jido_claw/route_composer/composer_durable_test.exs`
Add a launch (non-recovery) regression mirroring the restore mechanism the
`:668` round-trip test already uses (`:route_composer_capture_context` →
`{:wave_context, "researcher", tc}`), but with a **minimal** parent:
```elixir
test "start_composer honors an explicit :context on a minimal parent (P2)", ctx do
  converging_outputs()
  Application.put_env(:jido_claw, :route_composer_capture_context, self())
  on_exit(fn -> Application.delete_env(:jido_claw, :route_composer_capture_context) end)

  {:ok, parent} = RouteComposer.create_parent_run(tenant: ctx.tenant, actor: ctx.actor)
  refute Map.has_key?(parent.config, "context")           # documents why the bug bit

  notify_ref = make_ref()

  {:ok, _pid} =
    RouteComposer.start_composer(
      Keyword.merge(base_opts(ctx), notify: self(), ref: notify_ref),
      parent
    )

  assert_receive {:wave_context, "researcher", tc}, 30_000
  assert tc.workspace_id == ctx.context.workspace_id      # not the "wf_<tag>" fallback
  assert tc.project_dir == ctx.context.project_dir
  assert tc.session_uuid == ctx.context.session_uuid

  # Wait for the terminal so the unlinked composer doesn't outlive the test against
  # the shared sandbox (the notify/ref idiom from composer_durable_test.exs:237-245).
  assert_receive {:route_composer, ^notify_ref, {:done, summary}}, 30_000
  assert summary.terminal == :converged
end
```
`base_opts/1` (line 85) carries `context: ctx.context` + `catalog:`; the minimal
parent's empty config makes `put_start_catalog` fall back to opts (the `:absent`
path) and `start_context` fall back to opts context. Without the fix, `tc.workspace_id`
is the `"wf_<tag>"` fallback and the assert fails — a true regression.

---

## Precommit watch-outs
- **Specs/credo-strict:** all new functions (`mark_sensitive/2`, `sensitive_deadline_ms/0`,
  `ack_message/4`, `start_context/2`) are `defp` — `Readability.Specs` only flags public
  defs, so no `@spec` needed. No new aliases.
- **`fixed_shape_map` (reach):** neither change adds a map literal (P1 merges a
  keyword list; P2 adds none) — no new exposure, and `.reach.exs` needs no edit.
- **ExSlop EXS3004:** no new comment line begins with the word "step" (verified in the
  sketches above).
- **dialyzer:** `start_context/2`'s three clauses are total over `nil | map`; config
  context is always a `json_safe`-encoded map or absent.
- **flaky set:** none of the touched async-singleton files (MCPServer/Prompt/
  PipelineStore/MultiSandbox) — if the full suite flakes, re-verify the suspect file
  **in isolation** (not `--seed 0`) before blaming these changes.

---

## Verification (end to end)
1. **Targeted, as each fix lands:**
   `mise exec -- mix test test/jido_claw/front_door_test.exs test/jido_claw/route_composer/composer_durable_test.exs`
   (the review's 29 front-door/triage tests + the durable suite + the two new cases).
2. **The bar:** `mise exec -- mix precommit` — run **bare in the background** and read
   the output tail; never pipe through `tail` (it masks the gate's exit code). Must end
   green (compile_check → system_prompt.check → deps.unlock → format → reach --strict →
   credo --strict → dialyzer → test).
3. **Manual REPL smoke (optional):** `mise exec -- mix jidoclaw`, then a secret-bearing
   ask (e.g. "rotate the API token in config/runtime.exs") → real triage signals
   `:secrets` → the started `composer` `WorkflowRun` has
   `config["sanitize_sensitive_context"] == true` and a `config["deadline_at_ms"]`
   (inspect via `mcp__tidewave__execute_sql_query`). Set `:triage_model` to a cheap
   model first.

---

## Files to stage (per project policy — do NOT commit; leave unstaged)
- `config/config.exs` — `:triage_sensitive_deadline_ms` knob
- `lib/jido_claw/front_door.ex` — `mark_sensitive/2` + `sensitive_deadline_ms/0` + attr
- `lib/jido_claw/route_composer/route_composer.ex` — `start_context/2` + line 653
- `test/jido_claw/front_door_test.exs` — P1 sensitive-marking describe block
- `test/jido_claw/route_composer/composer_durable_test.exs` — P2 launch-context regression

Suggested commit message (both fixes are independent; one commit is fine, or split P1/P2):

```
fix: AR-2 Phase 3 review — mark :secrets runs sensitive; honor launch :context

P1: FrontDoor now marks a :secrets-signalled composer launch
sanitize_sensitive_context: true with a bounded (configurable, 30m default)
deadline, so the scrubber redacts derived durable plaintext and the run is
time-bounded. P2: build_start_opts/2 falls back to opts[:context] when the
parent config has no persisted "context", honoring the start_composer/2 contract
for the minimal-parent launch path (recovery stays config-authoritative).
```
