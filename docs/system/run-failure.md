---
type: subsystem
description: The 22-kind run-failure taxonomy — platform vs agent provenance, retryable ≠ resume-unsafe as independent derived sets, total classify.
sources:
  - lib/jido_claw/orchestration/run_failure.ex
  - lib/jido_claw/forge/runners/resume_policy.ex
  - lib/jido_claw/forge/harness.ex
  - lib/jido_claw/route_composer/route_composer.ex
  - lib/jido_claw/core/telemetry.ex
verified: 2026-07-11
verified_sha: "6e252a40"
---

# Run-Failure Taxonomy (retryable ≠ resume-unsafe)

## What & why

`JidoClaw.Orchestration.RunFailure` is the one closed vocabulary for *why an agent run
failed* — platform-vs-agent provenance in the kind name, policy (retry? resume?)
derived from set membership, never from string-sniffing at decision sites. It sits
beside `Orchestration.Verdict` so infra ≠ verdict ≠ failure stays one vocabulary, and
ABOVE `Forge.Error.classify/1` (whose `{kind, recovery}` contract is pinned — the
taxonomy composes over it, never breaks it). Port provenance: multica MC1-4 @
`129efb768` (patterns only — failure.go's enum + AllReasons() pre-warm, classify.go's
ordered classifier, service/task.go's two derived sets), with the orca OR3-2 riders
(the `stalled_no_output`/`stalled_wall_clock` split, `user_cancelled` as first-class
non-failure) and bosun BO2-3 (the session-poisoned family). Pre-argus Wave A #1.

## Invariants & contracts

- **`classify/1` and `format_reason/2` are total** over arbitrary input — the entire
  public bodies are wrapped in a final rescue/catch (exceptions, throws, AND exits)
  falling back to `:agent_unknown` / a bounded fallback string; inner extraction
  (`Exception.message/1`, `String.downcase/1` on invalid UTF-8) is additionally
  guarded so the wrapper is the backstop, not the mechanism.
- **`retryable?/1` (retry-the-WORK) and `resume_unsafe?/1` (abandon-the-CONVERSATION)
  are independent predicates** — the overlap (`agent_semantic_inactivity`,
  `agent_session_poisoned`: retry fresh, never on the old anchor) is the point of two
  predicates instead of one severity scale.
- **`failure?/1` is false ONLY for `:user_cancelled`.**
- **Consumers enrich, never redecide** — the harness `:error` arm, the composer's
  Lane-B trace, and telemetry all carry the classified kind without any control-flow
  change; retry policy consumption arrives with its consumers (the resume stack).
- **Splode class containers classify order-invariantly**: every leaf classifies, an
  explicit total precedence rank picks the winner — permuting leaves can never change
  the answer.
- **Whitelist decode only** (`decode/1` over the closed set) — never
  `String.to_atom/1`.
- **`error_details/2` policy bits are caller-proof**: `%{failure_kind, retry}` merges
  OVER the caller's extra after stripping the reserved keys in both atom and string
  forms (`:retry`/`"retry"`, `:failure_kind`/`"failure_kind"`, `:reason`/`"reason"`) —
  callers can never override policy or reintroduce `:reason` (retry-hint diggers read
  it; the LoopGuard `:trigger` naming precedent).

## The 22-kind table

Derived-set legend: R = `retryable?`, U = `resume_unsafe?`. Provenance is `:platform`
for the unprefixed kinds, `:agent` for the `agent_`-prefixed.

| Kind | R | U | Producer status |
| --- | --- | --- | --- |
| `iteration_limit` | – | U | Live: `Forge.run_loop` `:max_iterations_reached`, `{:iteration_limit, _}`. The iteration BOUND only — deadline exhaustion is `stalled_wall_clock`, never this. |
| `api_invalid_request` | – | U | Live: HTTP 400-class statuses + `invalid_request_error` strings (a 400 is baked into history — the same conversation replays it). |
| `stalled_wall_clock` | R | – | Live: `"harness_timeout"` (claude_code/codex runners), sandbox `{_, :timeout}`, exit 124, `{:timeout, ms}` shapes, forge-domain timeout wrappers. |
| `stalled_no_output` | R | – | **Producer-pending** — no silence watchdog exists; pre-argus Wave B #8 (`:stage_stalled`) registers the composer-level stall here. |
| `user_cancelled` | – | – | Live (non-failure): `cancellation.ex` `run_cancelled`, Forge `:cancelled` phases, `{:cancelled, _}` / `%{status: :cancelled}` shapes. |
| `agent_provider_auth_or_access` | – | – | Live: `Jido.AI.Error.API.Auth`, 401/403 statuses, `:unauthorized`, auth-class strings. → CLI exit 6. |
| `agent_provider_quota_limit` | – | – | Live: 402, quota/billing/credit-balance strings. |
| `agent_provider_capacity_or_rate_limit` | – | – | Live: `Jido.AI.Error.API.RateLimit`, 429/529 (Anthropic overloaded = capacity, not generic 5xx), rate-limit strings. |
| `agent_provider_server_error` | – | – | Live: 5xx statuses (minus 529), server-error strings. |
| `agent_provider_network` | – | – | Live: `Jido.AI.Error.API.Request{kind: :network}`, nil-status ReqLLM requests with non-timeout transport causes, `:unreachable`, transport strings. → CLI exit 5. |
| `agent_timeout` | – | – | Live: both `TimeoutError` leaves (Jido + Jido.Action), `Request{kind: :timeout}`, 408, timeout-shaped transport causes, non-forge `:timeout`-phase wrappers. |
| `agent_process_failure` | – | – | Live: nonzero exit codes (minus 124/127), `{_, :output_limit}`, Forge provision/bootstrap/exec pairs. |
| `agent_empty_or_unparseable_output` | – | – | Live: `ReqLLM.Error.API.Response` with nil/2xx status, unparseable-output strings. |
| `agent_context_overflow` | – | – | Live: context-length strings (checked BEFORE the generic 400 rules — providers ship overflow as a 400). |
| `agent_missing_config` | – | – | Live: `JidoClaw.Error.ConfigError`, missing-key strings. |
| `agent_model_not_found_or_unavailable` | – | – | Live: 404 in the LLM-request context, model-not-found strings. |
| `agent_runtime_version_unsupported` | – | – | **Producer-pending** — no runtime version probe exists yet. |
| `agent_runtime_missing_executable` | – | – | Live: exit 127, `"runner_unavailable"`, command-not-found strings. |
| `agent_fallback_message` | – | U | **Live**: `fallback_marker?/1` (≤320 bytes, single-line, non-empty, not `{`-leading) gates the vendor runners' unrecognized-bare-output arm — `Runners.ResumePolicy.armed_failure/7` tags `{:fallback_marker, trimmed}` when a classify miss looks like a bare model marker. |
| `agent_semantic_inactivity` | R | U | **Producer-pending** — multica's codex semantic-inactivity detection has no equivalent probe yet; the kind reserves the policy slot (retry fresh, poison the anchor). |
| `agent_session_poisoned` | R | U | **Live end-to-end**: bosun's codex family (`invalid_encrypted_content`, rollout path, `tool_call_id`) + the invalid-anchor rejection class, including two PRODUCER-EXACT live-probed rules — codex 0.144.1 `"no rollout found"` and claude `"no conversation found"`; the armed runners classify continuations through `ResumePolicy`, poison the anchor, and tag `resume_rejected: true` that the consolidator's ledger-gated retry consumes. |
| `agent_unknown` | – | – | Total fallback — never absent. |

Derived sets exactly: retryable = {`stalled_wall_clock`, `stalled_no_output`,
`agent_semantic_inactivity`, `agent_session_poisoned`}; resume-unsafe =
{`iteration_limit`, `agent_fallback_message`, `api_invalid_request`,
`agent_semantic_inactivity`, `agent_session_poisoned`}.

**The retryable set is deliberately narrow** — a conservative multica-faithful default
and a consumer policy seam. It is NOT justified by "HTTP-level retries already
happened": that is false for Anthropic 5xx in the current stack (osa FWB:176).
Widening (e.g. adding `agent_provider_capacity_or_rate_limit` with backoff) is a
consumer policy decision made against this vocabulary, not inside it.

## Mechanics

- **Enum adaptation from multica's 21**: dropped `queued_expired` /
  `runtime_offline` / `runtime_recovery` (daemon members with no equivalent here) and
  `agent_blocked` (their own producer-less wart — grep-verified in the inventory);
  renamed `timeout` → `stalled_wall_clock`; added `stalled_no_output`,
  `user_cancelled`, `agent_fallback_message`, `agent_semantic_inactivity`,
  `agent_session_poisoned`.
- **classify/1 rule order** (most-specific-first, the classify.go discipline):
  1. unwrap `{:error, _}` shells; 2. cancel shapes; 3. specific dep structs
  (`Jido.AI.Error.API.*` by field, `ReqLLM.Error.API.*` by status with nil-status
  cause dispatch, both TimeoutError leaves); 4. first-party leaves — `:timeout`-phase
  wrappers dispatch on operation BEFORE the cause dig (the raw `{:timeout, ms}` also
  rides `details.cause` and would flatten the split), other `ExecutionError`s dig
  `details.cause`/`details["cause"]` (the Normalize layer's Jido.AI wrap point) and
  use the nested classification when specific; 5. Forge structs compose through the
  pinned `Forge.Error.classify/1` pair; 6. Splode containers via the precedence rank;
  7. generic exceptions through a guarded `safe_message/1` that invokes the
  exception's OWN `message/1` under rescue — never `Exception.message/1`, whose
  shield text embeds call-site line numbers the boundary-safe `\b401\b`-class
  rules can false-positive on; 8. producer
  tuples/atoms; 9. the ordered string rules; 10. `:agent_unknown`.
- **Depth bound 3** on all recursion (`{:error, _}` shells, cause digs, container
  leaves) — deeper nesting is wrapper lasagna, not signal.
- **Container precedence** (compile-guarded total over the enum):
  `user_cancelled` first (sibling errors of a cancel are teardown noise), then the
  plan-stated spine auth > quota > rate > api_invalid_request > model > server >
  network > session_poisoned > context_overflow > timeout-kinds >
  missing_config/missing_executable > empty_output > process_failure > unknown, with
  the unlisted kinds slotted beside their nearest class.
- **String rules**: producer-exact markers first; the session-poison family BEFORE
  the numeric-code rules (a poisoned 400 stays poisoned); context overflow before the
  generic 400; bare timeout words LAST (messages embed "timeout" incidentally).
  Numeric statuses only as boundary-safe regexes (`\b401\b` never matches `40123` or
  `error 4010` — negative tests pin this).
- **HTTP status dispatch**: 401/403 auth · 402 quota · 404 model (LLM-request
  context) · 408 timeout · 429+529 capacity/rate · other 5xx server · other 4xx
  api_invalid_request.
- **Consumers**: the Forge harness classifies once per `:error` terminal — the PubSub
  broadcast gains `kind` (subset-matching consumers verified), telemetry counts, and
  the `iteration.completed` event data gains `failure_kind` on error rows only. The
  composer's Lane-B (`wave_infra_failed`) threads the kind into the non-durable Trace
  via `emit_infra_observability/4` — durable `stage_infra` markers and event shapes
  untouched (welded wave commits are law). `error_details/2` ships here for the
  resume stack's runner terminal envelopes.

## Config & telemetry

No config. Telemetry: `counter("jido_claw.run_failure.total", tags: [:kind,
:provenance])` via `Telemetry.emit_run_failure/2`. `all_kinds/0` is the label
pre-warm export (multica `AllReasons()`).

## Residuals & accepted risks

- **Pre-warm is an export, not a wiring**: no metrics-reporter harness exists in the
  app (the metrics list feeds `telemetry_poller` consumers), so `all_kinds/0` waits
  for a reporter to call it; dashboards discovering labels lazily until then is
  accepted.
- **Producer-pending kinds** (`stalled_no_output`, `agent_runtime_version_unsupported`,
  `agent_semantic_inactivity`) are documented slots, never silent warts — each names
  its arrival trigger in the table above.
- **String-arm conflation**: an Ash `Forbidden` (internal authz) message sniffs to
  `agent_provider_auth_or_access` — same access class, wrong neighbor. Multica's
  substring classifier shares the shape; accepted at this altitude.
- **`retryable?` narrowness** is a policy seam (above), revisited by consumers, not
  by the module.

## Source map

- `lib/jido_claw/orchestration/run_failure.ex` — the module
- `lib/jido_claw/forge/harness.ex:665` — the classify-once `:error` arm consumer
- `lib/jido_claw/route_composer/route_composer.ex:2264` — Lane-B trace threading
- `lib/jido_claw/core/telemetry.ex` — counter + `emit_run_failure/2`
- `test/jido_claw/orchestration/run_failure_test.exs` — the rule/totality tables
