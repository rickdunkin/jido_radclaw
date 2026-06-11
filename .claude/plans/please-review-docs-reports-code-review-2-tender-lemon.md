# Secrets Cluster Fix Plan — H7, H8, H9, M1, M2

## Context

`docs/reports/code-review-2026-06-10.md` identified a "secrets cluster" (priority tier 3): three HIGH findings on secrets at rest/in transit and two MEDIUM redaction gaps. All five were re-verified against source during planning:

- **H7** — `persist_env_var/3` (`lib/jido_claw/cli/setup.ex:300-317`) writes API keys to `.env` at the process umask (world-readable); zero `chmod` calls in the file.
- **H8** — Message `:append` runs `Changes.RedactContent`, but `:import` (`lib/jido_claw/conversations/resources/message.ex:167-189`) runs only `ValidateCrossTenantFk` — legacy JSONL secrets land in Postgres verbatim. The export test "proves" redaction with a pre-scrubbed fixture, passing trivially.
- **H9** — `scrubbed_cmd_env/1` (`lib/jido_claw/security/redaction/env.ex:96-110`) is inherit-everything + denylist-unset; `SECRET_KEY_BASE`, `ONECLI_AGENT_TOKENS`, `AWS_ACCESS_KEY_ID` etc. slip through to every spawned child, including LLM-driven CLIs.
- **M1** — Block `:write` (`lib/jido_claw/memory/resources/block.ex:114-142`) has no redaction change, yet blocks render verbatim into the system prompt (`lib/jido_claw/agent/prompt.ex:263`). `Security.Redaction.Memory`'s moduledoc already claims Block coverage.
- **M2** — `LogRedactor.filter/2` (`lib/jido_claw/security/redaction/log_redactor.ex:18-20`) rewrites only `event.msg`; `event.meta` and the `{:report, _}` / `{format, args}` msg shapes (OTP crash reports can dump GenServer state) pass through unredacted.

User decisions (confirmed via Q&A): **H9 = allowlist inheritance** (review's preferred fix); **M2 = meta + report/format shapes**. Greenfield — no data/path compat needed. **Done-criterion: `mix precommit` passes** (compile_check → system_prompt.check → deps.unlock --unused → format --check-formatted → reach.check --arch --smells --strict → credo --strict → dialyzer → test).

Every fix reuses an existing in-repo pattern; no new top-level modules. Revised after the user's source-level plan review: proxy/credential-capability vars tightened out of the H9 base allowlist, `OsCmd.run/3` default scrubbed, a reachable config surface for the allowlist extension, fail-closed depth bound + binary keys for M2, an adjacent M1 CLI `source:` bug folded in, prompt-level and persisted-state regression tests, and `.env.tmp` failure cleanup.

---

## H7 — chmod `.env` to 0600

**File:** `lib/jido_claw/cli/setup.ex` (`persist_env_var/3`, lines 300-317). Reuse the mode idiom from `lib/jido_claw/agent/identity.ex:173-178`.

1. At function start, defensively `File.chmod(env_path, 0o600)` (non-bang) **only when `File.lstat/1` says the path exists and `type == :regular`** — `lstat`, not `stat`: `stat` follows symlinks, so a symlink at `.env` would still get its target chmod'd. Never chmod a directory/symlink that happens to sit at the path (a directory would lose its execute bit before the rename failure surfaces).
2. Use a **unique tmp path** instead of the fixed `.env.tmp`: `env_path <> ".#{System.unique_integer([:positive])}.tmp"` — concurrent callers can't trample each other's tmp, and the cleanup below only ever removes our own file.
3. Create the tmp file restrictive **before** content lands in it: `File.touch!(tmp)` → `File.chmod!(tmp, 0o600)`, then `File.write!(tmp, new_content)` → `File.rename!(tmp, env_path)` wrapped in `try ... after File.rm(tmp) end` — on write/rename failure the secret-bearing tmp never outlives the call; after a successful rename the `rm` is a harmless `:enoent`. Rename preserves mode, so the final `.env` is 0600 with no world-readable window, including for the tmp.
4. Update the `@doc`: file created/kept at mode 0600; tmp is unique per call.

**Tests (new file `test/jido_claw/cli/setup_test.exs`** — none exists; setup.ex is entirely untested):
- Fresh dir: `persist_env_var/3` → `.env` exists, correct content, `Bitwise.band(File.stat!(path).mode, 0o777) == 0o600` (assertion idiom from `test/jido_claw/agent/identity_test.exs:181-183`); no `*.tmp` left behind (glob the dir).
- Pre-existing `.env` chmod'd to 0o644 with other lines/comments: upsert replaces the key line in place, preserves the rest, and mode ends 0o600.
- Failure cleanup: pre-create `env_path` as a **directory** so `File.rename!` fails deterministically → the error propagates, no `*.tmp` remains, AND the directory's own mode is untouched (pins the stat-guard on the defensive chmod).

## H8 — redact on Message `:import`

**Files:** `lib/jido_claw/conversations/resources/message.ex`, `test/mix/tasks/jidoclaw_conversations_export_test.exs`, fixture `test/fixtures/exports/conversations/with_secrets/.jido/sessions/__tenant__/api_secret.jsonl`, `test/jido_claw/conversations/message_test.exs`.

1. Add `change({__MODULE__.Changes.RedactContent, []})` to the `:import` action, **above** `ValidateCrossTenantFk` (matches `solution.ex:164` `:import_legacy` ordering: scrub, then validate). The existing inline change (message.ex:557-585) already covers `:content` + `:metadata` via `Transcript.redact/1` and is idempotent — re-running the migrator converges (`import_hash` is computed by the migrator from the raw line, so dedup is unaffected). Fix at the action, **not** the migrator — covers every future `Message.import/1` caller, mirroring Solution/Fact.
2. Update the moduledoc (~lines 47-52) that currently documents `:import` as running "only the cross-tenant FK validation hook".
3. **Fixture:** replace the pre-baked `[REDACTED:API_KEY]` literal on line 3 with a raw key, e.g. `set OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz01 please` (`test/jido_claw/security/redaction/transcript_test.exs:33-35` pins the expected output `[REDACTED:API_KEY]`).
4. **Export test (lines 75-168):** flip the line-88 assertion to assert the raw fixture contains the **raw** `sk-...` key (proving the test starts unscrubbed); rewrite the now-stale comment at 84-89; the comment at 122-127 ("migrate task redacts at the storage boundary") becomes true — keep. The manifest/position assertions (128, 146-161, 163-167) need no logic changes: positions are recovered by `[REDACTED` prefix-match, and they now pass *because of* the fix instead of trivially.
5. **Direct unit test in `test/jido_claw/conversations/message_test.exs`:** `Message.import` with raw `sk-...` content and `%{"api_key" => "sk-..."}` metadata, then **re-read the row from the DB** (by id / `for_session`) and assert on the reloaded record: content `=~ "[REDACTED:API_KEY]"`, metadata value `== "[REDACTED]"` — pins persisted state, not the returned struct.

## H9 — env scrub: inherit-allowlist instead of denylist

**File:** `lib/jido_claw/security/redaction/env.ex`. Output shape of `scrubbed_cmd_env/1` / `scrubbed_port_env/1` is unchanged (`{key, nil}` unsets ++ overrides), so **zero consumer changes** across all ~30 call sites (forge host_shell/docker, backend_host, os_cmd, git tools, setup checkers, terminal, $EDITOR, etc. — all funnel through these two functions; verified no unscrubbed spawn sites exist).

1. **Base allowlist** as module attributes:
   - exact (unconditional): `PATH HOME USER LOGNAME SHELL TERM COLORTERM LANG LANGUAGE TZ TMPDIR EDITOR VISUAL PAGER SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE NO_PROXY no_proxy`.
   - **value-conditional:** proxy vars `HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY` + lowercase forms are inherited **only when the value carries no credentials**, via a proxy-specific `proxy_value_has_creds?/1` predicate matching BOTH the existing `@url_with_creds` form (`scheme://user:pass@host`) AND the scheme-less form (`~r/^[^:@\/\s]+:[^@\/\s]+@/`, i.e. `user:pass@host:8080` — no `@` means plain `host:port` stays safe). A credentialed proxy value is dropped, not handed to LLM-driven children. Comparison stays case-sensitive, no normalization.
   - **deliberately NOT in the base list (credential-capability vars):** `SSH_AUTH_SOCK`, `GPG_TTY`, `GNUPGHOME` — not secret strings themselves, but they grant auth/signing capability to children. Opt back in via the extension surface; document in the moduledoc that SSH-based `git clone` in `resource_provisioner` and GPG-signed commits need the opt-in.
   - prefixes: `LC_`, `XDG_` (via `String.starts_with?/2`).
2. **Operator extension, read at call time, with a reachable config surface:** extra var names come from BOTH `Application.get_env(:jido_claw, :extra_allowed_env_vars, [])` (app config / tests) AND the `JIDOCLAW_EXTRA_ALLOWED_ENV_VARS` System env var (comma-separated; parse with `String.split(",")` → `String.trim/1` each → drop `""`, so `"FOO, BAR,"` behaves predictably) — the env var is the user-facing surface, reachable from `.env` since `load_dotenv/0` (application.ex:416) only populates System env and `.jido/config.yaml` never lands in app env. Extra prefixes: `:extra_allowed_env_prefixes` app-env key only. Document all three in the moduledoc.
3. **`scrubbed_cmd_env/1`:** flip the comprehension filter from `sensitive_key?(key)` to `not inheritable?(key, value)` (new private predicate: allowlist membership + the proxy userinfo check, which needs the value). Overrides still always win and bypass the allowlist — that's what keeps CODEX_HOME, vault secrets, OneCLI proxy vars, and session env working (claude/codex auth via synced credential files, not env — verified). `scrubbed_port_env/1` delegates, unchanged.
4. **Broaden `sensitive_key?/1`** (stays — feeds `redact_value/2`, `Transcript`, and the M2 fix): suffix regex → `~r/_(KEY|TOKEN|TOKENS|SECRET|PASSWORD|PASS|PAT|CREDENTIAL|CREDENTIALS)$/i`; specific regex → add `AWS_ACCESS_KEY_ID|SECRET_KEY_BASE|ONECLI_AGENT_TOKENS`. **No blanket `_BASE` suffix** (`URL_BASE`/`API_BASE` false positives).
5. Update moduledoc Rules section + `scrubbed_cmd_env/1` `@doc` to describe allowlist-then-override semantics.
6. **Close the `OsCmd.run/3` default-env footgun:** `lib/jido_claw/core/os_cmd.ex:69` defaults `:env` to `[]`, so the port inherits everything when the caller forgets (tests already hit this default). Change the default to `Env.scrubbed_cmd_env()` via `Keyword.get_lazy/3`; an explicitly passed `:env` is still used as-is (both production callers already build theirs via `scrubbed_cmd_env(overrides)`). Update the `@doc` from "already scrubbed by the caller" to "defaults to `Env.scrubbed_cmd_env()`; pass `:env` built via `scrubbed_cmd_env(overrides)` to inject vars".

**Tests (`test/jido_claw/security/redaction/env_test.exs`):**
- **Flip, don't delete,** the inverted case at L113-117 ("leaves non-sensitive vars alone" → "drops non-allowlisted vars": a random `JIDO_TEST_*` var now yields `{name, nil}`).
- Add: unconventionally-named secrets are dropped (`SECRET_KEY_BASE`, `ONECLI_AGENT_TOKENS` set in parent → unset tuples); credential-capability vars dropped by default (`SSH_AUTH_SOCK`); allowlist survival (`refute {"PATH", nil} in result`, same for HOME/TERM); `LC_*`/`XDG_*` prefix survival; proxy conditioning (`http_proxy=http://proxy:8080` and bare `HTTP_PROXY=proxy.example.com:8080` survive; `HTTP_PROXY=http://user:pass@proxy:8080` AND scheme-less `HTTP_PROXY=user:pass@proxy:8080` are dropped); both extension surfaces (`Application.put_env` + `JIDOCLAW_EXTRA_ALLOWED_ENV_VARS` System env var, each with on_exit cleanup).
- `sensitive_key?/1`: keep all existing asserts (HOME/PATH/TERM refutes still hold — different mechanism); add asserts for `ONECLI_AGENT_TOKENS`, `SECRET_KEY_BASE`, `AWS_ACCESS_KEY_ID`, `MY_CREDENTIALS`; add `refute sensitive_key?("URL_BASE")`.
- `test/jido_claw/core/os_cmd_test.exs`: add a default-scrub case — set a parent `SECRET_KEY_BASE`-style var, run `OsCmd.run("/bin/sh", ["-c", "printenv ..."])` with NO `:env` opt → var not visible; existing explicit-`:env` cases must pass unchanged.
- Remaining consumer suites must pass **unchanged** (they pin the contract): `test/jido_claw/forge/runner/host_shell_test.exs` (env scrubbing describe), `test/jido_claw/shell/backend_host_test.exs` (session/exec env wins).

## M1 — redact Block `:write`

**File:** `lib/jido_claw/memory/resources/block.ex`. Block's content attribute is **`value`** (NOT NULL) plus nullable `description`.

1. Add inline `Changes.RedactContent` mirroring `fact.ex:595-615`: `before_action`, redact `:value` and `:description` via `JidoClaw.Security.Redaction.Memory.redact_fact!/1` (binary-guard each attr; add the `MemoryRedaction` alias). `before_action` is safe under the consolidator's nested-transaction caveat (block.ex:586-595 — only `after_transaction` hooks are dangerous).
2. Wire into `:write` **before `CapValueLength`** (order is load-bearing: redaction placeholders can be longer than a short raw secret, so the cap must validate the final stored value; Ash runs `before_action` hooks in registration order):
   `ValidateScopeFk → ValidateCrossTenant → RedactContent (new) → CapValueLength → Audit.MemoryWrite`.
3. Coverage is complete via `:write` alone: consolidator (`run_server.ex:898/899/903`), CLI (`commands.ex:1424/1442`), and `Block.revise/3` (block.ex:609) all converge on it; `:invalidate` accepts no content. `Security.Redaction.Memory`'s moduledoc claim becomes true — no edit needed there.
4. **Adjacent CLI bug (fix while here):** `commands.ex:1438` builds the cross-scope override with `source: :user_save`, but Block's constraint is `@sources [:user, :consolidator]` (block.ex:67) — `:user_save` is **Fact** vocabulary (fact.ex:82), so this CLI path fails the changeset today. Change to `source: :user`. Pre-existing bug, not caused by this plan.

**Tests (`test/jido_claw/memory/block_test.exs`, existing TenantCase setup):**
- `:write` with `sk-ant-...` in `value` → stored `[REDACTED:ANTHROPIC_KEY]`, raw absent; secret in `description` → redacted.
- **Ordering-isolating case:** raw secret 31 bytes, redacted form 18 bytes, `char_limit: 25` → write **succeeds** (cap saw the redacted value; would fail if cap ran first).
- Idempotency: writing already-redacted content stores unchanged; `revise/3` path redacts (routes through `:write`).
- **CLI-source regression:** a `:write` mirroring the CLI override attrs (`source: :user`, `written_by: "cli"`, full scope fields) succeeds — pins the `commands.ex:1438` fix against Block's `@sources` constraint.
- **Prompt-level regression (`test/jido_claw/agent/prompt_snapshot_test.exs`):** write a block whose `value` (and `description`) contained a raw secret, build the prompt via the existing snapshot API, refute the raw secret appears and assert the `[REDACTED:...]` marker does — blocks render verbatim at `prompt.ex:253-263`, so this pins the end-to-end guarantee M1 exists for.
- **Bonus (cheap, closes a latent gap):** Fact's redaction wiring (fact.ex:177/216) is untested — add a `Fact.record` redaction case to `test/jido_claw/memory/fact_test.exs`.

## M2 — redact logger metadata + report/format msg shapes

**File:** `lib/jido_claw/security/redaction/log_redactor.ex` (36 lines; `:logger` **primary** filter — survives the MCP stderr handler swap; installed before `.env` load at `application.ex:36`).

1. `filter/2` → `%{event | msg: redact_message(message), meta: redact_meta(meta)}`. Keep the legacy arity-4 clause as-is.
2. **`redact_meta/1`** (also reused for report maps/keywords):
   - Skip-set of standard meta keys passed through verbatim (perf — never secrets, often charlists/pids): `mfa file line pid gl time domain application report_cb ancestors callers registered_name`. **`crash_reason` is deliberately NOT skipped** (GenServer state can carry secrets).
   - Per `{k, v}`: key sensitivity via a `key_sensitive?/1` helper with **atom AND binary clauses** (`Atom.to_string/1` for atoms — `Env.sensitive_key?/1`'s non-binary clause silently returns `false`; binary keys occur in `{:report, map}` payloads from app code); any other key type → not sensitive. Sensitive key → `"[REDACTED]"`; else recurse into the value.
   - **Value walker** (`@max_meta_depth 4`), **fail closed at the bound:** binaries → `Patterns.redact/1` at any depth (leaves — the bound doesn't apply); maps/keyword lists → keyed recursion (depth+1); **tuples → walk elements and reconstruct** (`Tuple.to_list/1` → walk each → `List.to_tuple/1`, same depth accounting) — crash shapes like `{:badmatch, %{api_key: ...}}` are tuples wrapping the secret-bearing term; **at the depth bound replace any container (map/list/tuple) with an opaque `"[REDACTED:DEPTH]"` placeholder** — never pass deep containers through, that's exactly where nested GenServer state secrets hide; keyword lists (`[{atom, _} | _]`) → keyed walk; **charlists (lists of integers) → opaque pass-through** (never walk char-by-char); other lists → element-wise (same bound); atoms/numbers/pids/refs/functions → unchanged. Do **not** reuse `Env.redact_value/2` here — its `to_string/1` coercion would corrupt non-binary terms.
3. **`redact_message/1`** new clauses (keep the existing three): `{:report, report}` when map or keyword → keyed walk via the same `redact_meta` machinery; `{format, args}` when `is_list(args)` → **walk each arg with the same bounded value walker** (not binaries-only — `{"state=~p", [%{api_key: "sk-..."}]}` is a real leak shape). Because the walker preserves shapes (maps stay maps, tuples are reconstructed as tuples), `~p`/`~w` formatting is unaffected. **Redact the format string too** (a literal `{"token sk-...", []}` would otherwise leak), directive-safely: split the string on a directive regex covering Erlang's full `~F.P.PadModC` grammar — optional sign/width/precision/pad/`t`/`l`/`k` modifiers and the `~~` escape, e.g. `~r/~(?:[-+]?\d+|\*)?(?:\.(?:\d+|\*)?(?:\.(?:.|\*))?)?[tlk]*(?:[a-zA-Z]|~)/` (verify against the `:io_lib.format/2` docs at implementation) with `include_captures: true` — run `Patterns.redact/1` only on the non-directive literal segments, rejoin — directives can't be mangled by construction (the generic `token=value` pattern would otherwise eat a `token=~s` directive). Type-preserving for charlist formats (convert → process → convert back); other format types (atoms) untouched.
4. Split helpers into small clauses (`redact_meta/1`, `redact_meta_value/2`, `key_sensitive?/1`, `skip_key?/1`) — keeps credo `--strict` cyclomatic complexity happy. Module stays `@moduledoc false`; loose `term()` specs on the recursive walker for dialyzer.

**Tests (`test/jido_claw/security/redaction/log_redactor_test.exs`, direct `filter/2` calls as today):** sensitive atom key (`%{api_key: "sk-..."}` → `"[REDACTED]"`); embedded secret in non-sensitive-keyed value (`%{note: "token sk-..."}` → patterns-scrubbed); skip-set untouched (`%{file: ~c"/path", mfa: {Foo, :bar, 1}}` byte-identical); `crash_reason` walked (`%{crash_reason: %{state: %{api_key: "sk-..."}}}` → redacted); **tuple `crash_reason`** (`%{crash_reason: {:badmatch, %{api_key: "sk-..."}}}` → tuple shape preserved, inner value `"[REDACTED]"`); `{:report, %{password: "hunter2"}}` → `"[REDACTED]"`; **binary-keyed report** (`{:report, %{"api_key" => "sk-..."}}` → `"[REDACTED]"`); `{"api_key=~s", ["sk-..."]}` → arg scrubbed, format untouched; **`~p` map arg** (`{"state=~p", [%{api_key: "sk-..."}]}` → arg stays a map with value `"[REDACTED]"`); benign structured arg (`{"~p", [%{a: 1}]}`) byte-identical; **format-string literal secret** (`{"token sk-... seen", []}` → scrubbed) while **directives survive adjacent key names** (`"token=~s, key=~p"` keeps both directives byte-identical post-redaction) and **width/modifier variants survive** (`"token=~-10s pass=~10.5s name=~ts pct=~~"` byte-identical — pins the broadened directive grammar against future regex narrowing); **depth bound fails closed** (a map nested past `@max_meta_depth` with a secret inside comes back as `"[REDACTED:DEPTH]"`, never the raw container); keep the two existing tests.

---

## Sequencing

Each step is independently green; run the targeted suite after each. **H9 before M2** (M2's tests assert against the broadened `sensitive_key?/1`).

1. **H7** — `mix test test/jido_claw/cli/setup_test.exs`
2. **H8** — `mix test test/jido_claw/conversations/message_test.exs test/mix/tasks/jidoclaw_conversations_export_test.exs`
3. **M1** (incl. the `commands.ex:1438` source fix) — `mix test test/jido_claw/memory/block_test.exs test/jido_claw/memory/fact_test.exs test/jido_claw/agent/prompt_snapshot_test.exs`
4. **H9** (incl. the `os_cmd.ex` default) — `mix test test/jido_claw/security/redaction/env_test.exs test/jido_claw/forge/runner/host_shell_test.exs test/jido_claw/shell/backend_host_test.exs test/jido_claw/core/os_cmd_test.exs`
5. **M2** — `mix test test/jido_claw/security/redaction/log_redactor_test.exs`

If committing: branch off `main` first; one commit per finding (`fix:` prefix), staging only that finding's files.

## Verification

1. Per-step targeted suites above.
2. `mix format` then **`mix precommit`** — the done-criterion. Watch specifically: `jidoclaw.compile_check` (clean recompile, allowlist only tolerates the two PullRequestCoordinator branches), `credo --strict`, `dialyzer`, full `mix test` (~2487 tests).
3. The review report (`docs/reports/code-review-2026-06-10.md`) gets per-finding "✅ fixed" annotations matching the established format — only after precommit is green.

## Risks / gotchas

- **env_test inversion (H9):** the L113-117 case flips meaning — rewrite to pin the new "drops non-allowlisted" contract, don't delete.
- **Allowlist completeness (H9):** uncommon inherited vars (`KUBECONFIG`, `DOCKER_HOST`, `GIT_SSH_COMMAND`) are dropped until added via `JIDOCLAW_EXTRA_ALLOWED_ENV_VARS` / `:extra_allowed_env_vars` — accepted trade-off; the moduledoc documents the escape hatch. Known functional consequences of the capability-var opt-out: SSH-based `git clone` in `resource_provisioner` and GPG-signed git commits stop working until `SSH_AUTH_SOCK` / `GPG_TTY`+`GNUPGHOME` are opted in — call these out explicitly in the moduledoc. `os_cmd.ex:283`'s internal ps/kill keeps working (PATH allowlisted, executables resolved absolute).
- **`OsCmd.run/3` default change (H9):** explicit `:env` keeps its exact semantics (used as-is); only the no-`:env` default changes from inherit-everything to scrubbed. Both production callers pass explicit env — behavior change is confined to forgotten-env callers, which is the point.
- **Atom meta keys (M2):** forgetting `to_string/1` before `sensitive_key?/1` makes meta redaction a silent no-op — the `%{api_key: ...}` test exists to catch exactly this.
- **CapValueLength ordering (M1):** redaction must be registered above the cap; the 31B-raw/18B-redacted/25-cap test isolates it.
- **Fixture swap (H8):** position assertions are `[REDACTED`-prefix-based, robust to the swap; ensure the raw key matches `~r/sk-[a-zA-Z0-9_-]{20,}/` so `Patterns` produces exactly `[REDACTED:API_KEY]`.
