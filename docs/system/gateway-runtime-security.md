---
type: surface
description: Tenant-safe live-agent identity, bounded stateless completions, tenant lifecycle enforcement, and gateway authentication/diagnostic hardening.
sources:
  - lib/jido_claw.ex
  - lib/jido_claw/agent/stateless_completion.ex
  - lib/jido_claw/agent_view.ex
  - lib/jido_claw/platform/session/supervisor.ex
  - lib/jido_claw/startup.ex
  - lib/jido_claw/conversations/ephemeral_cleanup.ex
  - lib/jido_claw/conversations/request_correlation/cache.ex
  - lib/jido_claw/web/controllers/chat_controller.ex
  - lib/jido_claw/web/controllers/auth_controller.ex
  - lib/jido_claw/web/auth_rate_limiter.ex
  - lib/jido_claw/web/setup_status_cache.ex
  - lib/jido_claw/web/live/setup_live.ex
  - lib/jido_claw/web/live_user_auth.ex
  - lib/jido_claw/setup/credential_validator.ex
  - lib/jido_claw/web/router.ex
  - lib/jido_claw/accounts/password_policy.ex
  - lib/jido_claw/accounts/user.ex
  - lib/jido_claw/tenants/access.ex
  - lib/jido_claw/tenants/resources/tenant.ex
  - lib/jido_claw/platform/tenant/manager.ex
  - lib/jido_claw/resource.ex
  - lib/jido_claw/orchestration/workflow_run.ex
  - lib/jido_claw/orchestration/workflow_event.ex
  - lib/jido_claw/orchestration/workflow_step.ex
  - lib/jido_claw/orchestration/agent_case_event.ex
  - lib/jido_claw/orchestration/composer_artifact.ex
  - lib/jido_claw/audit/resources/event.ex
  - lib/jido_claw/conversations/resources/request_correlation.ex
  - lib/jido_claw/application.ex
  - config/test.exs
  - config/runtime.exs
  - test/support/no_external_ex_aws_http_client.ex
verified: 2026-07-10
verified_sha: "b2cae5cd"
---

# Gateway Runtime Security

## What & why

The Phoenix/API surface turns untrusted client conversation names and payloads into
live Jido processes, durable session rows, provider work, and local diagnostic probes.
This page defines the boundaries that keep those effects tenant-safe and bounded.

## Invariants & contracts

- A live chat-main agent is keyed by the durable conversation UUID as
  `"session:<uuid>"`, never by a client-controlled external session name. Durable
  session uniqueness already includes tenant, workspace, kind, and external id.
- Stateless API completions use a dedicated zero-tool temporary agent. They bypass
  handoff, external MCP attachment, triage, and composer launch, then always tear
  down the agent, any defensive handoff residue, shell sessions, VFS workspace,
  handoff registry entry, Session worker, and correlation-cache entries. The
  caller's stateless marker is validated before any Workspace/Session persistence,
  then verified again against the resolved row.
- PostgreSQL `tenants.status` is the activity authority. Ordinary tenant-scoped Ash
  reads/writes, authenticated LiveView mounts, and every `JidoClaw.chat/4` turn fail
  closed unless it is `:active`; tenant-matched system actors are the explicit
  lifecycle/recovery exception.
- Browser setup diagnostics require an allowlisted admin at both the HTTP and
  LiveView-mount boundaries; probes run asynchronously, coalesce, carry a hard
  deadline, and cache the last known good result.
- Test boots do not read developer dotenv files, inherit known provider/AWS/Brave
  credentials, arm OneCLI, or start Discord.

## Mechanics

### Live sessions and the completion API

`JidoClaw.chat/4` resolves the Workspace and `Conversations.Session` before looking up
the Jido agent. `runtime_agent_id/1` derives the opaque registry key from that row's
UUID and the same id is threaded as the main agent's trace/tool identity. The raw
session name remains only the tenant-qualified Session-worker/handoff lookup key.

`ChatController` accepts 1–100 ordered messages with supported roles, string content,
a 64 KiB per-message bound, and a 256 KiB bound on the JSON-encoded transcript. It
normalizes every entry to role/content (dropping arbitrary extension fields), serializes
the complete ordered transcript once and reuses those exact JSON bytes for both the
size bound and prompt, accepts only `"default"` or the configured server model, uses
UUID external ids, and returns generic client errors with a server-log request id.

The controller sets both `ephemeral_runtime: true` and
`stateless_completion: true`. The latter selects
`JidoClaw.Agent.StatelessCompletion`, whose native tool list is structurally empty,
and skips handoff, external-tool registration, and `FrontDoor.decide/2`. A prompt
that looks like code or system work therefore receives the synchronous prose answer
the OpenAI-compatible contract promises; it cannot launch a durable composer whose
Session/workspace the same request is about to remove. Its injected project prompt
also carries a retained capability block forbidding claims of file, command, tool, or
background-work execution.

The controller's validated concrete model rides the composed request transformer as
a per-turn override, so the response's `model` field and the provider invocation
cannot diverge even on a gateway-only boot where the CLI never rebound global
`:fast` aliases. This path also skips `Startup.ensure_project_state/1`: prompt
assembly reads existing project context with bundled fallbacks, but an authenticated
completion cannot create or synchronize `.jido/` files.

`ephemeral_runtime: true` starts its agent with `restart: :temporary`; the cleanup
bracket begins before Session-worker/agent acquisition, so returns, raises, exits, and
throws from acquisition through dispatch all converge on cleanup. Durable artifacts
(solutions, outcomes, memory, tool output, and cases) are detached from the
conversation; ephemeral messages/correlations and the metadata-marked session are
deleted transactionally. Those table/column decisions live in one compile-time tuple
registry; a schema-introspection regression enumerates every `session_id`/
`session_uuid` column and conversation FK, so a new reference cannot silently escape
cleanup or acquire blanket `ON DELETE SET NULL` semantics. The cleanup transaction
first locks and proves the exact tenant/UUID/stateless row and captures its
correlation IDs. Only after commit are
those IDs—and cache-only fallback IDs tracked by the cache's per-session index—evicted
from ETS. A bounded, TTL-matched deleted-session tombstone rejects a resolver's late
rehydration if it read the durable row before commit but queues its cache write after
the purge; saturation disables new cache writes for one TTL and falls back to
PostgreSQL rather than dropping a fence. Shell-session and VFS-workspace state are
removed alongside both agent and Session processes. Any cleanup failure is returned
to the synchronous caller after all live teardown steps have been attempted
independently.

Before that bracket can be needed, `validate_chat_options/1` requires the literal
`metadata: %{"api_stateless" => true}` marker for every ephemeral call. This check
runs before project bootstrap and `resolve_persistence/5`, so an invalid caller cannot
leave a new Workspace or Session row. `validate_ephemeral_session/2` remains after
resolution to reject reuse of an existing durable/unmarked session even when the
caller supplied the marker.

### Tenant lifecycle

`JidoClaw.Tenants.Access` is the explicit front-door/resolver gate. The base
`JidoClaw.Resource` policy and the four remaining hand-written policy resources
(`WorkflowRun`, `ComposerArtifact`, audit `Event`, and `RequestCorrelation` —
`WorkflowEvent`, `WorkflowStep`, and `AgentCaseEvent` now adopt the macro, whose
`:by_id_global` bypass is inert on resources without that action) enforce the same
contract. Ordinary reads combine actor
tenant equality with a correlated `EXISTS` on the durable active tenant row, so the
row filter and activity check execute in one SQL statement without a stale ETS cache
or an extra per-read query. Ordinary writes use `ActorTenantActive` plus tenant
matching. Deliberate global actions remain administrative escape hatches; a
`kind: :system` actor bypasses activity only when its tenant still matches, allowing
terminalization/audit/recovery of already-running work. Actor-less internal
`RequestCorrelation` signal plumbing marks its bypass explicitly with
`authorize?: false` at each callsite rather than leaving the resource permissive.

The shared `:live_user_required` mount hook applies `Tenants.Access.ensure_active/1`
to Dashboard, Forge, Workflows, Approvals, Agents, Projects, and Settings. This closes
the direct `WorkflowsLive` read path as well as sibling authenticated views; the
separately allowlisted setup/admin surface retains its own admin hook. Session→user
resolution is result-preserving (`Web.SessionUser`, mirroring the upstream
token-presence chain: JWT verify, `"act"` rejection, jti revocation fence, subject
lookup), and the activity check is read-first — the provisioning upsert runs only on a
first-ever mount, so steady-state checks issue no writes and never touch a suspended
row. Mount failures split three ways: an **inactive tenant** (or invalid actor shape)
halts to the public `/auth/account-unavailable` landing page, whose CSRF-protected
DELETE form posts to `/auth/sign-out` on an explicit click only (an `on_mount` hook
cannot clear a Plug session, so the old `/sign-in` redirect looped forever; a
GET-clears-session route or auto-submit would hand attackers a forced logout);
an **infrastructure failure** — in the auth lookup or the activity check, on every
hook and in the `RequireAuth` plug — answers a session-preserving 503
(`/service-unavailable`), never a guessed sign-out; only a genuinely
**unauthenticated** session redirects to `/sign-in`. Sign-out audits record the
client-supplied reason only as allowlisted untrusted `requested_reason` alongside
server-derived `tenant_status_at_signout` / `actor_valid`; a lookup failure degrades
the field to `"unavailable"` and never blocks the session clear.

Ash suspend/resume/archive actions synchronize the legacy ETS mirror only after the
database transaction succeeds. Suspended/terminating transitions stop the tenant
runtime subtree; resume recreates it for a cached tenant. The legacy Manager's public
suspend/resume functions now execute the Ash actions, so they cannot drift from the
durable row. Cache-miss and default-tenant boot paths first load the durable row and
never start a runtime for a suspended/terminating tenant.

### Authentication and setup

New registration/change/reset passwords are at least 12 characters and at most 72
bytes (also at most 72 characters). The byte boundary is enforced on new, confirmation,
current-password, reset, and sign-in arguments before `BcryptProvider`; this avoids
bcrypt's silent truncation after byte 72 while retaining sign-in compatibility with
older shorter credentials. The controller repeats the same UTF-8-safe byte check before
the authentication action.

`AuthRateLimiter` checks a per-IP and per-IP/email sliding window before bcrypt; a
successful login clears the credential bucket but not the broad abuse bucket. Request
work touches only those two map entries. Timestamp lists are capped, the total map has a
hard bucket limit, and a correlated periodic sweep removes expired entries outside the
request path. New identities fail closed with HTTP 503 when the map cannot admit both
keys; a runtime capacity reduction clears state and holds all admission closed for one
window rather than forgetting attempts and failing open.

`/setup` shares the `/admin` plug boundary plus `:live_admin_required` for reconnects.
`SetupLive` uses `assign_async` on mount and `start_async` on re-check, so a cache exit
or probe timeout renders loading/error state instead of crashing the LiveView.
`SetupStatusCache` runs one coalesced probe under `JidoClaw.TaskSupervisor`, caches
success for 60 seconds, limits manual refresh/retry to once per 10 seconds, and applies
a 10-second hard probe deadline. A failure returns the last known good status when one
exists; without one it returns an explicit unavailable error while the GenServer stays
responsive. The local Ollama `curl` probe separately uses a one-second connection and
two-second total timeout.

### Hermetic tests

`config/test.exs` sets `load_dotenv: false`, `skip_discord: true`, and
`sanitize_external_env: true`. At config-evaluation time and again at the first line of
application startup, the test BEAM deletes known provider/adapter secrets,
`BRAVE_SEARCH_API_KEY`, all inherited `AWS_*`, `ONECLI_*`, `FORGE_ONECLI_*`,
`FORGE_SANDBOX*`, and `FORGE_WORKSPACE_*` variables, and the external-env allowlist
knob. It also clears compile-time Nostrum/Brave credentials and resolves OneCLI to an
explicitly disabled config and Forge to the host test runner. `runtime.exs`
independently refuses to arm either Docker or OneCLI when `config_env() == :test`.
Static inert ExAws credentials prevent pod/instance-role fallback, and a test-only
ExAws HTTP adapter rejects every request locally so an accidental S3 VFS call cannot
reach metadata or storage. Tests that exercise a credential path opt in afterward by
setting and restoring that exact variable.

## Config & telemetry

- `config :jido_claw, :auth_rate_limit` — `:window_ms` (60,000), credential
  `:max_attempts` (5), IP-wide `:ip_max_attempts` (100), hard `:max_buckets`
  (10,000), `:max_timestamps_per_bucket` (100), and `:sweep_interval_ms` (60,000).
  Attempt limits above the timestamp cap clamp to the cap (stricter, never fail-open).
- `config :jido_claw, :setup_status_cache` — `:ttl_ms` (60,000),
  `:min_refresh_ms` (10,000), and `:probe_timeout_ms` (10,000).
- `config :jido_claw, :load_dotenv` and `:skip_discord` control boot-only external
  configuration/adapters.
- Authentication successes, failures, and throttled attempts emit `:auth_event` audit
  rows. Completion failures log an opaque request id while clients receive no provider
  body or inspected exception.

## Residuals & accepted risks

- `stream: true` is protocol-compatible SSE framing but currently emits the completed
  response as one buffered delta. The response advertises
  `x-jidoclaw-stream-mode: buffered`; true token streaming needs a front-door/runtime
  event contract that also covers composed workflows.
- Password and setup throttles are per node. A clustered internet-facing deployment
  should add a shared edge limiter.
- The limiter's hard capacity is deliberately availability-failing: enough distinct
  IP/email keys can make previously unseen sign-ins return 503 until expired buckets
  sweep. This bounds per-node memory under cardinality attacks; size the cap for expected
  traffic and put a shared edge limiter in front of an internet-facing deployment.
- The ETS tenant cache remains as a runtime mirror for legacy APIs. PostgreSQL is now
  authoritative and transitions synchronize it, but removing the duplicate store is
  still desirable.
- An inactive tenant deliberately forces sign-out (via the explicit-click landing
  form) rather than keeping the session alive in a read-only limbo; suspension is an
  operator action and the session should not outlive it.
- Sign-out audit rows evidence voluntary-vs-forced through the server-derived
  authoritative fields (`tenant_status_at_signout`, `actor_valid`), not through
  `requested_reason` — the latter is client-supplied and recorded only as an
  allowlisted untrusted hint.

## Source map

- `lib/jido_claw.ex` — durable runtime ids, zero-tool routing, and ephemeral cleanup
- `lib/jido_claw/agent/stateless_completion.ex` — capability-empty completion agent
- `lib/jido_claw/agent_view.ex` — UUID-derived main-agent trace lookup
- `lib/jido_claw/platform/session/supervisor.ex` — Session-worker removal
- `lib/jido_claw/startup.ex` — stateless capability prompt injection
- `lib/jido_claw/conversations/ephemeral_cleanup.ex` — bounded stateless-row cleanup
- `lib/jido_claw/conversations/request_correlation/cache.ex` — hot lookup and
  per-session bulk eviction index
- `lib/jido_claw/web/controllers/chat_controller.ex` — request validation and API shape
- `lib/jido_claw/web/controllers/auth_controller.ex` — pre-bcrypt throttling
- `lib/jido_claw/accounts/password_policy.ex` — shared bcrypt byte ceiling
- `lib/jido_claw/web/auth_rate_limiter.ex` — sliding windows
- `lib/jido_claw/web/setup_status_cache.ex` — coalesced, deadline-bounded,
  last-known-good diagnostics
- `lib/jido_claw/web/live/setup_live.ex` — asynchronous loading/error rendering
- `lib/jido_claw/web/live_user_auth.ex` — authenticated active-tenant mount gate
- `lib/jido_claw/web/session_user.ex` — result-preserving session→user resolver
- `lib/jido_claw/web/plugs/require_auth.ex` — HTTP auth gate with the same 503 split
- `lib/jido_claw/setup/credential_validator.ex` — bounded Ollama probe
- `lib/jido_claw/tenants/access.ex` — durable activity gate
- `lib/jido_claw/resource.ex` and the four hand-written policy resources —
  domain-wide active-tenant policy plus the tenant-matched lifecycle exception
- `lib/jido_claw/tenants/resources/tenant.ex` — lifecycle/runtime synchronization hook
- `config/test.exs` — external-secret and adapter disarming
- `config/runtime.exs` — test-only Docker/OneCLI hard stops
- `test/support/no_external_ex_aws_http_client.ex` — no-network AWS test transport
- `test/jido_claw/accounts/user_password_test.exs` — bcrypt byte-boundary regressions
- `test/jido_claw/web/auth_rate_limiter_test.exs` — window, sweep, and capacity regressions
- `test/jido_claw/application_test.exs` — config/boot environment sanitization regressions
- `test/jido_claw/chat_runtime_identity_test.exs` — collision and cleanup regressions
- `test/jido_claw/tenants/access_test.exs` — suspension enforcement regressions
- `test/jido_claw/web/controllers/chat_controller_test.exs` — API boundary regressions
