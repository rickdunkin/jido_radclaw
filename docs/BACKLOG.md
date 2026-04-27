# JidoClaw Backlog

Items deferred from prior roadmap milestones that aren't yet scheduled. Each entry notes its source milestone, scope, why it was deferred, the trigger to pick it up, and a rough effort estimate.

This is the holding pen for "we know we should do this eventually, but not now." Items graduate out of here into `docs/ROADMAP.md` when scheduled into a release.

For items already in flight or scheduled, see `docs/ROADMAP.md`.

---

## SSH Backend Extensions

Extends the SSH remote-execution surface delivered in v0.5.3 + v0.5.4.

### Jump-host / bastion chains

**Source:** v0.5.3 / v0.5.4 deferrals (`docs/ROADMAP.md:258`, `:289`).

Extends `servers:` in `.jido/config.yaml` with a `proxy_jump:` field (single host or chain) and threads it through `Jido.Shell.Backend.SSH` configuration. Lets users reach hosts behind a jump box without falling back to manual `~/.ssh/config` setup.

**Why deferred:** v0.5.3 prioritized the direct-connection path; jump-host adds config schema surface and connect-time complexity. No upstream blocker.

**Effort:** Medium. Roughly one point release.

**Trigger:** First user report of "I need to SSH through a bastion." Likely soon as remote dev environments standardize on bastion access.

### Key management UI / secret-store integration

**Source:** v0.5.3 / v0.5.4 deferrals (`docs/ROADMAP.md:260`, `:291`).

Today SSH credentials live as plaintext key files on disk and `.jido/config.yaml` points at paths. This item supplements that with secret-store-backed lookup (Vault, OS keychain, AWS Secrets Manager, etc.) and a UI/CLI surface for configuring it.

**Why deferred:** Open design questions on backing store, key rotation, and multi-tenant isolation. No upstream blocker, but needs a design pass before implementation.

**Effort:** Large. Likely a security-themed milestone of its own.

**Trigger:** Multi-tenant deployment requirements, or a compliance ask that disallows on-disk key storage.

---

## Cross-Adapter VFS Operations

Extends file-tool and shell-command coverage across the non-local VFS adapters (`github://`, `s3://`, `git://`, `inmemory://`) registered by `JidoClaw.VFS.Workspace`. v0.3 delivered read coverage and shell mount routing; the gaps below are write coverage, search coverage, and cross-adapter diff.

### VFS-aware diffing across adapters

**Source:** v0.3 deferrals (`docs/ROADMAP.md:79`).

`git_diff` and related diff tools currently assume both sides are git-managed local paths. Cross-adapter diff (e.g., `/project/foo.ex` vs `/upstream/foo.ex` where `/upstream` is a `git://` mount) doesn't work cleanly today.

**Why deferred:** v0.3 focused on read paths through the existing tools; diff cuts across multiple adapter types and needs a common file-byte interface plus a renderer that doesn't assume git semantics.

**Effort:** Small to medium. Smallest of the v0.3 leftovers.

**Trigger:** Workflows that compare local work against an upstream reference (porting changes, syncing forks).

### `SearchCode` remote support

**Source:** v0.3 deferrals (`docs/ROADMAP.md:77`).

`SearchCode` walks local filesystem paths only. Searching across `/upstream` (git mount), `/artifacts` (S3), or in-memory mounts requires either streaming files through the adapter or pushing the search to the remote where supported (GitHub code search API).

**Why deferred:** v0.3 prioritized file-tool coverage over search coverage, and per-adapter strategy is non-trivial — GitHub has search APIs, raw `git://` and S3 don't.

**Effort:** Medium.

**Trigger:** Users storing reference repos in non-local mounts and wanting cross-mount search.

### GitHub / S3 writes from the shell command surface

**Source:** v0.3 deferrals (`docs/ROADMAP.md:78`).

Shell built-ins (`echo > /upstream/foo`, `write`, redirection) currently fail against read-mostly adapters. Symmetry with read support requires per-adapter capability flagging plus a clear error UX for read-only adapters.

**Why deferred:** v0.3 scoped to read parity; write semantics across adapters (atomicity, commit-vs-push for git, multipart for S3) need their own design.

**Effort:** Medium.

**Trigger:** Workflows that materialize artifacts to S3 or open a GitHub PR from inside an agent run.

---

## Runtime Concurrency Model

### Truly concurrent multi-agent streaming

**Source:** v0.5.4 deferrals (`docs/ROADMAP.md:292`).

`JidoClaw.Shell.SessionManager.run/4` is a `GenServer.call` that synchronously runs the command inside the SessionManager process. v0.5.4's streaming code is correct under that constraint, but two agents calling `run_command` concurrently still serialize globally — interleaved live output from simultaneous commands isn't possible today.

**Why deferred:** Lifting the serialization is an ownership/locking redesign, not a feature add. Tagged "a separate milestone" by v0.5.4.

**Effort:** Large; architectural. Likely candidates: pull execution out of SessionManager into per-session GenServers, or split routing/registry concerns from dispatch concerns.

**Trigger:** Real pain from concurrent multi-agent shell workflows. Today swarms tend to do other things in parallel and only one shell at a time.

---

## Not in this backlog

These items appear in `docs/ROADMAP.md` deferrals but are intentionally absent here:

- **Classifier auto-route for SSH** (`docs/ROADMAP.md:256`, `:287`) — "SSH stays explicit" by design.
- **Interactive / TTY-allocating sessions (`ssh -t`)** (`docs/ROADMAP.md:259`, `:290`) — "command-mode only" by design.
- **Passphrase-protected SSH private keys** (`docs/ROADMAP.md:252`, `:288`) — upstream-blocked; needs a `jido_shell` PR before JidoClaw can wire it.
- **Persisting the VFS mount table across node restarts** (`docs/ROADMAP.md:80`) — already folded into v0.6.

The first two are scope decisions; the third is upstream-dependent; the fourth is already scheduled. If any of those change direction, document the move before starting work.
