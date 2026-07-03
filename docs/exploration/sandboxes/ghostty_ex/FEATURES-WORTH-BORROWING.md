# Features Worth Borrowing from ghostty_ex

Exploration notes — not a plan, not a commitment. Deep-dive **2026-07-03**, fulfilling the
ghostty_ex next-step of the [sandbox landscape scan](../README.md). Source:
`~/workspace/research/sandboxes/ghostty_ex` (dannote/ghostty_ex, HEAD `6cd2d690`,
v0.4.9). Self-description: *"Terminal emulator library for the BEAM — libghostty-vt NIFs
with OTP integration."* Shape: the only Elixir-native subject in the sandbox scan — ~3.8k
lib lines (Elixir + two Zig NIFs: `ghostty_nif.zig` 658 lines wrapping libghostty-vt's C
API, `pty_nif.zig` 274 lines wrapping `forkpty()`), 1.4k test lines, a Phoenix LiveView
component with a TypeScript hook, and ten example scripts that double as pattern
documentation. Maturity: 118 commits, essentially single-author (95/118 by the author, 1
outside contributor), 19 releases 0.1.0→0.4.9 over Mar–May 2026 with a disciplined
CHANGELOG (real fixes: PTY fd-reuse races, reader-start handshakes, EIO-as-exit on macOS),
MIT, quiet since 2026-05-24. CI builds from source on Linux+macOS, runs Playwright browser
tests against the LiveView demo, fuzzes the VT parser (`fuzz/fuzz_vt.zig`), and lints with
**our exact house stack** — `credo --strict`, dialyzer, `ex_dna`, `ex_slop`, plus `zlint`
for the Zig. Precompiled NIF targets: `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`aarch64-macos-none` — exactly our dev/deploy set.

**Epistemic note**: nothing was installed, built, or executed this review — all claims are
firsthand reads of both trees, accurate to within a few lines. Two load-bearing semantics
could not be settled from the clone (it vendors no upstream source) and were verified
against `ghostty-org/ghostty` main (2026-07-03) via its published source: snapshot scope
and soft-wrap handling (see GX2-1/OQ-2). One intermediate web-fetch summary *misread*
upstream's `.screen` tag as viewport-only; the verbatim doc comment in
`src/terminal/point.zig` says the opposite ("Top-left is the furthest back in the
scrollback history … bottom-right of the last written row") — snapshots include the full
scrollback. Recorded because the correction is itself the evidence discipline working.

Companion docs: the [sandbox landscape scan](../README.md) (this answers its ghostty_ex
spike item — and *refines* its framing: terminal emulation is a presentation/normalization
layer, **not** a replacement for the redaction root's textual strip, per S-1);
[nono](../nono/FEATURES-WORTH-BORROWING.md) (any future PTY-backed host spawn is a new
spawn site on the same containment seam nono N1-1/N1-3 wraps — GX2-2 notes the interplay).
Threat model as always: personal, tailnet-only — LLM-misbehavior containment and leakage
hygiene over external-attacker hardening.

## Determination (TL;DR)

**The corpus's first real ADOPT-AS-DEP candidate — scoped, and gated on its first
consumer.** The axis has existed unused since camus noted it; ghostty_ex earns it: a hex
dep whose precompiled-NIF mechanism is a dependency *class we already ship* (jido_browser
→ extractous_ex pulls `rustler_precompiled` today — `mix.lock:55,77,127-128`), MIT, our
lint stack, a fuzzed parser, and `dirty_cpu` discipline on the heavy NIFs. What it is
**for** is narrower than the scan's sketch: the dashboard terminal our own README already
falsely advertises (README.md:379 and :1182 claim `/forge` has an "Interactive sandbox
terminal (xterm.js)" — no xterm.js exists anywhere in `assets/` or `web/`), and — behind
named triggers — screen-state normalization of `\r`-noisy captures, PTY for
TTY-requiring programs, and expect-style TUI verification. What it is **not** for:
replacing `Security.Redaction.Ansi.strip/1`. The redaction root must see the logical byte
stream (it exists to reassemble escape-split secrets before pattern matching); a terminal
*erases* overwritten bytes and *wraps* lines at `cols`, so emulation there would hide
bytes from redaction and split tokens across visual lines. Presentation and hygiene are
different layers; ghostty_ex is the right primitive for the first and the wrong one for
the second.

| Part of ghostty_ex | As a dependency | What to take |
| --- | --- | --- |
| `Ghostty.Terminal` + `LiveTerminal.Component` | **ADOPT-AS-DEP** (first consumer: the dashboard terminal) | GX1-1 — render-only forge/ops terminal, honoring the stale README promise |
| Snapshot-as-normalizer (progress-bar collapse) | Same dep, trigger-gated | GX2-1 — screen-state collapse stage on OutputShaper's generic path |
| `Ghostty.PTY` (forkpty NIF) | Same dep, decision-gated | GX2-2 — TTY-requiring programs + the ops-console input path (web-shell decision first) |
| Expect/diff example patterns | Pattern, not code | GX2-3 — screen-state driving/assertions for evals |
| `Ghostty.Test` golden-snapshot convention | Pattern, works without the dep | GX3-1 — `UPDATE_*_SNAPSHOTS` fixture rewrite for our eval fixtures |
| `Ghostty.TTY` / KeyDecoder / mouse-IME stack | No | S-2, S-4 — line-mode REPL by design; UI layers ride along free |
| PTY as default `run_command` transport | No | S-3 — pipes are the capture-correct default |

## Why ADOPT-AS-DEP is on the table (first use of the axis)

1. **The integration is a hex dep, not a platform.** `{:ghostty, "~> 0.4"}` downloads
   checksummed precompiled NIFs (`checksum-Ghostty.{Terminal,PTY}.Nif.exs`,
   `zigler_precompiled` with sha256 per target) for exactly our triple set; source build
   is an escape hatch (`GHOSTTY_BUILD=1`, Zig 0.15). Terminals are ordinary supervised
   GenServers (`terminal.ex:113-129`) — the OTP integration is already done and idiomatic.
2. **No new dependency class.** The tree already contains `rustler_precompiled`
   (extractous_ex via the *direct* dep jido_browser, `mix.exs:153`) and
   compiled-from-source C NIFs (bcrypt_elixir, picosat_elixir — `mix.exs:232,236`).
   Adopting ghostty_ex changes native-dep *count*, not posture. One transitive addition to
   note: `oxc` (Rust NIF, rustler_precompiled) is a hard dep used to bundle the TS hook at
   compile time (`mix.exs:129`, their `mix.lock:18`).
3. **Quality signals beat its size.** Fuzzed VT parser; `dirty_cpu` on
   `nif_snapshot`/`nif_render_cells`/`nif_render_state` (`terminal/nif.ex:28,35,36`) so
   big renders don't stall BEAM schedulers; XSS handled at both render layers (client hook
   escapes every grapheme before `innerHTML` — `priv/ts/render.ts:6-21`, `util.ts:3-5`;
   upstream HTML formatter entity-escapes `<`/`>`/`&` — verified in ghostty's
   `formatter.zig`); PTY reader threads with a start handshake and documented exit
   semantics. The CHANGELOG reads like someone chasing real races, not features.
4. **NIF blast radius is acceptable at this grain.** A NIF crash kills the BEAM — but the
   terminal NIF is pure in-memory VT state over a fuzzed parser, and the Tier-1 slice
   (render-only dashboard) never touches the riskier `forkpty` NIF. nono S-4's "a NIF
   would sandbox the whole BEAM" rejection was about *policy enforcement* grain; a
   rendering NIF carries no equivalent security inversion.
5. **Honest risk list**: single-author, pre-1.0, quiet for ~6 weeks; the precompile
   workflow builds libghostty-vt from upstream **main, unpinned** at release time
   (`.github/workflows/ci.yml:35`, same in precompile.yml — artifacts are
   checksum-pinned, but which upstream sha produced them is not recorded in-repo);
   Elixir-side mouse/focus tracking regex-scans per-write chunks
   (`terminal.ex:548-577`), so an escape sequence split across two writes can desync
   those two fields (irrelevant to snapshot/render uses, which read NIF state). None of
   these blocks a render-tier adoption; OQ-4 names the trigger that would.

## How to read this document

Recommendations: **ADOPT-AS-DEP** (take it as a library dependency — axis earned here),
**BUILD-ON** (ours to design; the dep supplies the primitive), **BORROW-PATTERN**,
**INDEPENDENT**, **SKIP**, **TRACK** (named trigger). Tiers: **Tier 1** = the adoption
spine (one PR, one consumer); **Tier 2** = rides the dep once present, each behind its own
trigger or decision; **Tier 3** = polish/pattern. Per-entry fields as usual: **Where in
ghostty_ex** (file:line — "start here," not gospel), **What**, **Gap in jido_radclaw**
(verified against source 2026-07-03), **Why it matters**, **Adoption sketch**. IDs are
`GX<tier>-<seq>` (G alone is gust's prefix).

---

## Tier 1 — The adoption spine

### GX1-1. The dashboard terminal the README already promises — render-only first slice

**Recommendation**: ADOPT-AS-DEP (this is the adoption; everything below rides it).

**Where in ghostty_ex**: `Ghostty.Terminal` (`lib/ghostty/terminal.ex:113-218` —
`start_link`/`write`/`snapshot`/`cells`), `Ghostty.LiveTerminal`
(`lib/ghostty/live_terminal.ex:206-229` — JSON-safe `render_payload` + `push_render`),
`Ghostty.LiveTerminal.Component` (`live_terminal/component.ex:56-133` — stateful
LiveComponent; key/text/mouse events handled internally; `pty` assign optional and
omitted in this slice), the igniter installer that vendors the JS hook
(`lib/mix/tasks/ghostty.install.ex`), and the demo app as the wiring exemplar
(`examples/live_terminal/lib/live_terminal_web/live/terminal_live.ex`).

**What**: a supervised GenServer terminal per surface; feed it bytes with `write/2`
(iodata; the VT parser interprets colors, cursor movement, `\r` overwrites); render in
LiveView either live (cells payload over `push_event`, client hook builds escaped spans —
`render.ts:6-21`) or statically (`snapshot(term, :html)` — inline-styled, entity-escaped
upstream). Effects (`{:pty_write, _}`, `:bell`, `:title_changed`) go to the owner
(`terminal.ex:22-29`); without a PTY attached, query responses are safely droppable.

**Gap in jido_radclaw** (verified 2026-07-03): the web layer renders *no* terminal
anywhere. `forge_live.ex:34-69` is a plain HTML table of forge sessions;
`workflows_live.ex:312` and `:481-482` render results as `inspect/2` inside `<pre>`; grep
for `xterm|ansi_up|hterm` across `assets/` and all `.heex` is clean. Meanwhile
`README.md:379` ("`/forge` | Forge Terminal | Interactive sandbox terminal (xterm.js)")
and `README.md:1182` ("forge_live.ex # Forge terminal (xterm.js)") advertise a terminal
that was never built — a documented intent, unshipped. Output that *would* feed it exists:
`Sandbox.Docker.spawn` streams chunks over a Port (`forge/sandbox/docker.ex:202-214`), and
host `run_command` streaming currently goes only to the CLI `Display`
(`session_manager.ex:565-584`; `display.ex:589` writes raw bytes to the operator's stdout)
— nothing fans those chunks out to web subscribers.

**Why it matters**: this closes a README-doc/code drift *and* gives agent-run output a
faithful rendering (colors, progress bars as a human sees them) instead of
`inspect`-in-`<pre>`. It is the scan's named spike, scoped to its safe half: render-only —
no keyboard input path, no PTY, so nothing about the web surface becomes a shell (that
decision is deliberately deferred to GX2-2/OQ-3).

**Adoption sketch**: add `{:ghostty, "~> 0.4"}`; `mix igniter.install ghostty` vendors the
hook into `assets/` and wires `app.js`. New `JidoClaw.Web.TerminalFeed` (or a per-forge-
session GenServer): subscribe a forge session's spawn/stream chunks, `Terminal.write/2`
each chunk (chunked writes are the NIF-friendly shape — `nif_vt_write` is not a dirty NIF;
PTY-sized 4KB chunks are what the library itself produces), broadcast a refresh;
`forge_live` mounts `LiveTerminal.Component` with `pty: nil` and `send_update(...,
refresh: true)` on chunks. Plumbing note: the missing piece is the chunk fan-out (today
Display is the only stream subscriber) — a small PubSub topic per forge session, capped by
the terminal's own `max_scrollback`. Failure posture: NIF load failure ⇒ feature-flag the
component off and keep today's table/`<pre>` (config `:web_terminal, enabled?:`); never
let a rendering dep block boot. Fix `README.md:379/:1182` to say ghostty (or, until
shipped, to stop claiming xterm.js). *(Same-day validation: the
[agentos dig](../agentos/FEATURES-WORTH-BORROWING.md) found their
`examples/browser-terminal` — xterm.js over a WebSocket, render-only, reconnect
re-adopts by id — independently landing on this exact product shape (agentos S-9): the
corpus's two-subjects-converging signal.)*

---

## Tier 2 — Rides the dep, each behind its own gate

### GX2-1. Screen-state collapse for `\r`-noisy captures — an OutputShaper generic-path stage

**Recommendation**: BUILD-ON (dep-enabled). **Trigger**: first observed `\r`-frame blowup
in a shaped output or stored ref (a captured progress bar inflating a capture toward the
512KB cap, or `\r` garbage reaching the model).

**Where in ghostty_ex**: the property is demonstrated end-to-end in
`examples/progress_bar.exs` (100 `\r\e[K` frames → snapshot shows only the final bar) and
`examples/ansi_stripper.exs`; snapshot mechanics in `ghostty_nif.zig:320-353`. Upstream
semantics verified 2026-07-03 against ghostty-org/ghostty: with no selection the formatter
walks `.screen` bounds — "furthest back in the scrollback history … bottom-right of the
last written row" (`src/terminal/point.zig` Tag docs; `formatter.zig` uses
`getTopLeft(.screen)`) — i.e. **snapshots are full-transcript, bounded by
`max_scrollback` lines (default 10k), not viewport-only**.

**What**: an ephemeral terminal as a normalizer — write the captured text through the VT
parser, snapshot `:plain`, get "what a human would have seen": overwrite frames collapsed,
cursor games resolved, erase sequences applied.

**Gap in jido_radclaw** (verified 2026-07-03): nothing interprets `\r`/`\b` anywhere.
`Ansi.strip/1` is three delete-only regexes (`security/redaction/ansi.ex:19-21,30-35`) —
its own test pins deletion semantics (`a\e[2Kb\e[1Gc` → `"abc"`, `ansi_test.exs:13-15`,
where a real terminal renders `"cb"` — erase-line, `b` at column 2, cursor home, `c`
overwrites column 1); bare `\r`/`\b` are not
ESC-prefixed and pass through. Captures join chunks verbatim
(`session_manager.ex:1475-1486`), so every intermediate frame survives into the stored ref
and — for unknown formats — into the head+tail shaped body
(`output_shaper.ex:585-590`). Honest demand calibration (the mapper's point): our spawns
are pipes, not TTYs (`backend_host.ex:135-141`), so `isatty()`-checking tools already
suppress their own progress output — the residual offenders are unconditional emitters.
This is why the entry is trigger-gated, not Tier 1.

**Why it matters**: when it fires, it fires exactly where head+tail is weakest — noise
distributed through the whole body. And pipeline placement makes it hygiene-safe *only*
in one spot: shaping runs **after** redaction (`tools/action.ex:60-63`), so the terminal
normalizes already-redacted text; the redaction root keeps seeing the logical stream
(S-1). The model-facing copy gets the human view; the ref keeps the full (redacted)
capture — same reversibility contract shaping already has.

**Adoption sketch**: in `generic_or_passthrough/2` (`output_shaper.ex:585`), when the
clean text matches an overwrite heuristic (`\r` not followed by `\n`, or cursor-movement
CSI — detectable *before* strip), route through
`Terminal.start_link(cols: wide, rows: small, max_scrollback: byte_size/40)` → chunked
writes → `snapshot(:plain)` → existing head+tail if still oversize; tag the shaped body
(`[screen-normalized]`) and emit a `:shaping` telemetry variant. Any error ⇒ fall through
to today's path. Two prerequisites: OQ-2 (`unwrap` — without it, lines longer than `cols`
gain hard wraps; interim workaround is very wide `cols`), and a bounds test that
`max_scrollback` covers the 512KB capture's line count. Terminal-pool reuse
(`examples/pool.exs`) only if per-call spawn shows up in telemetry.

### GX2-2. `Ghostty.PTY` — for programs that require a TTY, and (decision-gated) the interactive ops console

**Recommendation**: ADOPT-AS-DEP phase 2. **Gates**: a concrete TTY-requiring need (a
TUI-only tool in a runner; driving a REPL-style CLI), and for any web input path, OQ-3
(the web-shell decision) — in that order, or independently.

**Where in ghostty_ex**: `lib/ghostty/pty.ex` (GenServer; `{:data, binary}` /
`{:exit, status}` to owner; `resize/3` with SIGWINCH) over `pty_nif.zig:177-229`
(`forkpty()` + `execvp`, argv not shell, non-blocking reader thread with start handshake,
`EIO`-as-exit for macOS PTY EOF — `pty_nif.zig:157-160`). The demo's env-injection
pattern: `cmd: "/usr/bin/env", args: ["TERM=xterm-256color", …, "/bin/bash", …]`
(`terminal_live.ex:358-378`) — because the NIF exposes **no env/cwd parameters**.

**What**: a real pseudo-terminal so `vim`/`top`/interactive REPLs behave; pairs with a
`Ghostty.Terminal` (forward `{:data,_}` → `write/2`; forward the terminal's
`{:pty_write,_}` query responses back to the PTY).

**Gap in jido_radclaw** (verified 2026-07-03): zero PTY capability. Grep for
`openpty|forkpty|termios|stty|posix_openpt` across the repo is clean; every exec path is
pipe-based (`backend_host.ex:135`, `os_cmd.ex:101-108`, `host_shell.ex:213-217`,
`docker.ex:202-214` — and `sbx exec` is invoked without `-t`). Anything that demands a
controlling TTY simply cannot run today.

**Why it matters**: it's the missing capability class — but with integration caveats that
must ride any adoption, all verified in the Zig: (1) **children inherit the BEAM's full
environment** — no env/cwd args, and `/usr/bin/env` *adds* without scrubbing; our posture
requires an `env -i`-style allowlist wrapper to match the `Env.scrubbed_port_env`
default-deny already applied on the Port path (`security/redaction/env.ex:43-94`). (2)
**Exit status is lossy**: signal-killed children report `{:exit, 0}`
(`pty_nif.zig:87-94`, `WIFEXITED ? WEXITSTATUS : 0`) — never gate success on a PTY exit
code alone. (3) **Close is SIGHUP-only** (`pty_nif.zig:39-51`; no SIGKILL escalation,
`waitpid` is `WNOHANG`) — a SIGHUP-ignoring child can linger; our `OsCmd` tree-kill
doctrine (`os_cmd.ex:24-38`) would need to wrap it. (4) A PTY host spawn is a **new spawn
site** on the containment seam — it belongs under the same nono-wrap + approval posture as
the existing `sh -c` site (nono N1-1/N1-3), not beside it — and one a `Port.open`-needle
spawn-site guard ([agentos AO2-1](../agentos/FEATURES-WORTH-BORROWING.md)) cannot see:
the fork happens inside the NIF, so `Ghostty.PTY` must join that guard's needle list the
day this lands.

**Adoption sketch**: a `JidoClaw.Shell.PtyRunner` used only where a `tty_required` flag
says so; env via allowlist wrapper; lifetime owned by a supervisor that escalates
SIGHUP→SIGKILL through `OsCmd`'s tree-kill; for the ops console, `LiveTerminal.Component`
with the `pty` assign — behind OQ-3 and plausibly behind the tool-approval gate as a
`run_command`-equivalent surface.

### GX2-3. Expect-style screen-state driving and terminal-aware assertions for evals

**Recommendation**: BORROW-PATTERN. **Trigger**: first eval/verify case that needs to
drive or assert on a screen (REPL smoke test, TUI verification, "does the spinner
resolve" checks).

**Where in ghostty_ex**: `examples/expect.exs` (a ~60-line Expect: plain `Port.open` +
terminal as the screen-state matcher — patterns match through ANSI/cursor
movement/progress because matching runs on `snapshot/1`, not the byte stream);
`examples/diff.exs` (normalize two ANSI outputs through terminals, then
`String.myers_difference` — terminal-aware diff for assertions).

**What**: the assertion target becomes "what the screen shows," not "what bytes arrived" —
strictly more robust for anything animated, and no PTY needed unless the target program
demands one (their Expect uses an ordinary pipe Port).

**Gap in jido_radclaw** (verified 2026-07-03): the eval harness asserts on strings/
schemas/composer outcomes (`JidoClaw.Eval.run_case/2` kinds `:prompt`/`:schema`/
`:composer`/`:coherence`); nothing can drive an interactive program or assert on rendered
output. The REPL's own surface is only line-tested.

**Why it matters**: cheap once the dep exists (the pattern is ~60 lines against public
API), and it composes with the eval harness's fake↔live seam — an `:interactive` case
kind whose assertions are `assert_text`-style screen claims.

---

## Tier 3 — Pattern with or without the dep

### GX3-1. Golden-snapshot fixtures with an env-var rewrite valve

**Recommendation**: INDEPENDENT (works without the dep; comes free with it).

**Where in ghostty_ex**: `Ghostty.Test.assert_snap/3` (`lib/ghostty/test.ex:160-171`) —
compare against a fixture file; `UPDATE_GHOSTTY_SNAPSHOTS=1` rewrites fixtures instead of
failing; fixtures live in `test/fixtures/terminal/`.

**Gap in jido_radclaw** (verified 2026-07-03): no golden-file convention anywhere — grep
for `UPDATE_*`-style rewrite env vars and `.snap`/`__snapshots__` is clean; fixtures are
built programmatically (`test/support/replay_fixtures.ex`). Our eval seeds pin the
post-AR-9 prompt surface *in code* (`test/jido_claw/eval/`).

**Why it matters**: prompt-surface and shaped-output regression pinning is exactly the
golden-file shape — assert-against-file plus an explicit rewrite valve beats re-editing
heredocs, and the eval harness's prompt cases are the natural first user
(`UPDATE_JIDO_GOLDENS=1`).

**Adoption sketch**: a ~30-line `JidoClaw.Test.Golden.assert_golden/3` mirroring theirs;
adopt for new eval fixtures first, no migration of existing tests.

---

## Skip / Already Covered

- **S-1. Terminal emulation as the redaction-root ANSI strip.** SKIP — the scan's framing
  ("principled alternative to regex ANSI-stripping") is *refined* by this dig, not
  confirmed. The root strip (`ansi.ex:19-21`, applied at `output_redaction.ex:22,62-63`)
  exists to reassemble escape-split secrets on the **logical byte stream** before pattern
  matching; emulation would (a) *erase* overwritten bytes so redaction never scans them
  while the raw capture still carries them, (b) hard-wrap at `cols`, splitting tokens
  across lines (until OQ-2), and (c) drop history beyond `max_scrollback` silently. The
  queue's planned homoglyph normalizer (unadopted-next-ten:491) confirms the root is a
  textual-normalization layer by design. Emulation belongs after redaction (GX2-1), never
  instead of it.
- **S-2. `Ghostty.TTY` / `KeyDecoder` raw REPL input.** SKIP — the REPL is line-mode by
  design (`repl.ex:469`, `IO.gets`); no TUI ambitions on any queue. Named trigger: a real
  TUI REPL initiative (at which point their OTP-28 `backend: :auto` raw-mode work is the
  reference).
- **S-3. PTY as the default `run_command` transport.** SKIP — pipes are the
  capture-correct default: not-a-TTY makes well-behaved tools suppress progress noise at
  the source, while a PTY would *invite* it (and lose faithful exit codes,
  `pty_nif.zig:87-94`). PTY is for programs that need a TTY (GX2-2), not for fidelity.
- **S-4. Mouse/selection/IME/focus stack.** Nothing to do — rides along inside the
  component (GX1-1) at zero integration cost; listed so nobody scopes it as work.
- **S-5. `snapshot(:vt)` round-trip session recording/replay.** SKIP with trigger —
  genuinely interesting (record raw VT, replay into a terminal later; asciinema-shaped),
  but no current consumer. Trigger: a session-replay feature request for agent terminal
  output.

## Open questions

- **OQ-1. Runtime spike on our toolchain.** Precompiled zigler NIFs (built against OTP 27)
  loading under mise OTP 29 / Elixir 1.20; and the escript caveat — escripts can't bundle
  NIF `priv/` artifacts, so the REPL-escript surface can't use the dep directly (the
  Tier-1/2 consumers all run under `mix`/release, so this only bites if a CLI surface ever
  wants it). One `mix run` smoke on the dev Mac answers both.
- **OQ-2. `unwrap` exposure.** Upstream libghostty-vt's formatter already supports
  "unwrap soft-wrapped lines" (`GhosttyFormatterTerminalOptions.unwrap`, verified in
  `formatter.h`); ghostty_ex zeroes it (`ghostty_nif.zig:332-335` sets only
  `emit`+`trim`). A one-option upstream PR (`snapshot(term, :plain, unwrap: true)`)
  removes GX2-1's wrap-mangling caveat; interim workaround is very wide `cols`.
- **OQ-3. Is a browser-reachable PTY acceptable at all?** The dashboard is tailnet-only,
  but a LiveView PTY is a web shell on the host. Options when GX2-2's console half fires:
  render-only forever (input via existing gated `run_command`), PTY behind the
  tool-approval gate, or PTY only into Forge microVM sessions (`sbx exec` has no TTY
  today, so that path needs its own work). Decide then; GX1-1 deliberately doesn't open
  the question.
- **OQ-4. Supply-chain/bus-factor watch.** Named triggers to re-evaluate (vendor, fork,
  or pin): the precompile pipeline keeps building upstream ghostty **main unpinned**
  (`ci.yml:35`) *and* an upstream break ships; or 6+ months without maintenance while we
  hold a patch (e.g. OQ-2) unmerged.

## Cross-references and dependencies

```
GX1-1 (dep + dashboard terminal, render-only)
  ├─→ GX2-1 (shaper collapse)        [trigger: \r blowup]  ←needs OQ-2 for long lines
  ├─→ GX2-2 (PTY: TTY programs/console) [trigger: TTY need; console additionally OQ-3]
  │       └─ interplay: nono N1-1/N1-3 (new host spawn site → same containment posture)
  └─→ GX2-3 (expect-style eval driving) [trigger: first screen-state eval case]
GX3-1 (golden fixtures) — independent of all of the above
```

**Suggested first wave** (one PR): GX1-1 — dep + igniter hook vendor + chunk fan-out +
render-only terminal on `forge_live` + README claim fix + OQ-1 smoke as its verify step.
No collision with the active queues: unadopted-next-ten is composer/review-machinery; the
only adjacent queue note (osa OS1-4's normalizer, next-ten:491) lands in the redaction
root, which S-1 deliberately leaves untouched. GX3-1 can ship any time as a test-infra
nicety.

## Bottom line

1. **Adopt the dep when GX1-1 ships, not before** — the first ADOPT-AS-DEP in the corpus,
   earned by dependency-class precedent (rustler_precompiled already in-tree), matching
   platform triples, and a render-tier blast radius; the first consumer is the terminal
   our README has been falsely advertising at `/forge`.
2. **Keep emulation out of the redaction root** (S-1). The logical stream is where secret
   reassembly lives; the screen is where presentation lives. GX2-1's post-redaction
   shaper stage is the only hygiene-safe home for snapshot-normalization.
3. **PTY is a capability decision, not a rendering one** (GX2-2/OQ-3): env-inheritance,
   lossy exit codes, SIGHUP-only close, and a new containment seam — adopt it for
   TTY-requiring programs when one actually appears, and treat any web input path as the
   security decision it is.
