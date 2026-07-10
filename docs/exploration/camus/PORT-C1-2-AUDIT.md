# PORT-C1-2-AUDIT — Untracked-aware verify integrity

Amends the shipped deterministic verify port described by
[C1-2](FEATURES-WORTH-BORROWING.md) after the 2026-07-09 audit identified a
local integrity gap. Primary source: `camus @ 53da91b3` (MIT). Source behavior
uses tracked-only porcelain and a tracked diff. Target:
`JidoClaw.Orchestration.Verify.Git` in jido_radclaw's current working tree.

**Status: signed off by the operator and implemented 2026-07-09.** This is a
deliberate local hardening divergence, not a claim that camus provides
untracked-file integrity.

## Source and pre-amendment local semantics

Camus snapshots tracked porcelain around its verifier, rejects tracked dirt in
sealed mode, and binds its certificate to HEAD. JidoClaw preserved that shape
for sealed routes and extended non-committing routes with a SHA-256 of
`git diff --no-ext-diff --no-textconv --binary HEAD`, because porcelain cannot
see a second edit to an already-dirty tracked file.

Both captures omitted nonignored untracked files. An untracked source, fixture,
generated config, or executable can therefore affect the checks while sitting
outside both the cleanliness decision and the certificate. A check can also
create or mutate one without triggering the mid-verify tamper fence.

## Approved target semantics

1. `Verify.Git.porcelain/1` becomes nonignored-untracked-inclusive. Sealed mode
   refuses a tree containing any tracked dirt **or** untracked path before it
   runs checks. Gitignored paths remain outside the authority because the repo
   has explicitly classified them as disposable.
2. `diff_digest/1` hashes a domain-separated tuple of:
   the existing tracked binary diff; and a sorted manifest of every path from
   `git ls-files --others --exclude-standard -z`.
3. A regular untracked entry contributes its exact path, type/mode metadata,
   and content hash. A symlink contributes its path and link-target bytes only;
   its target is never followed. Unsupported special files make capture
   unavailable rather than being silently omitted.
4. Manifest capture is bounded by file count and aggregate content bytes. A
   crossed bound, invalid path, read failure, or detected change during capture
   returns `nil`. Existing callers already map a missing digest toward
   `integrity_unavailable`/INCONCLUSIVE, never green.
5. Regular files are `lstat`ed before and after the bounded read; identity,
   type, size, timestamps, and mode must remain stable. This is a consistency
   fence, not a claim of an atomic filesystem snapshot. A deliberately timed
   same-content ABA write can evade any finite read/stat sampler without a
   filesystem snapshot, mandatory writer cooperation, or a change journal.
6. The same digest is captured before and after verification and at convergence.
   Thus a pre-existing untracked file may remain in working-tree mode, but any
   content/path/type change retracts or tampers the certificate exactly like a
   tracked diff change.
7. Existing durable certificates need no migration. Their old digest fails the
   next convergence re-derivation and causes a fresh engine verify.

Implementation bounds are 1,000 untracked paths, 10 MiB aggregate regular-file
content plus symlink-target bytes, and 4,096 bytes per exact relative path.
Manifest discovery is itself output-capped at one byte beyond the largest
legal manifest, and its NUL parser refuses the first overlong path or 1,001st
unique entry before sorting; arbitrary `path_fingerprints/3` enumerables use
the same max+1 collection posture. Regular content is read twice in 64 KiB
chunks; both full-length hashes and the descriptor metadata must agree.
`Verify.Git.path_fingerprint/3` and
`path_fingerprints/3` expose the same domain-separated path/type/mode/content
capture for engine-side reuse; the latter may omit individually unreadable
paths only when a findings-only caller explicitly requests `on_error: :omit`.
The verify digest itself remains all-or-nothing.

## Side-by-side map

| Concern | Camus / pre-amendment port | Implemented local divergence |
| --- | --- | --- |
| Sealed cleanliness | Tracked porcelain only | Tracked + nonignored untracked porcelain |
| Working-tree content bind | Tracked binary diff SHA-256 | Domain-separated tracked diff + bounded untracked manifest SHA-256 |
| Build artifacts | Untracked always invisible | Ignored artifacts stay invisible; nonignored artifacts are integrity-relevant |
| Symlinks | Outside capture when untracked | Hash link text and metadata; never read the target |
| Capture overload/failure | Git failure ⇒ unavailable | Git/read/type/bound/race failure ⇒ unavailable |
| Verdict posture | Missing capture cannot certify green | Preserved exactly |

## Behaviors preserved exactly

- The engine, never an LLM relay, owns the verify verdict.
- HEAD remains part of every certificate.
- A failed integrity capture cannot produce green.
- A tampered verify is not retried and is never fed to a fixer.
- The verify command remains argv-only engine code.
- Ignored build output is not accidentally promoted into source integrity.

## Deliberately changed behavior

The camus-verbatim tracked-only boundary is dropped. Nonignored untracked paths
are executable inputs to ordinary repository checks and therefore belong to
the same trust boundary as tracked working-tree content. This closes a security
and correctness gap while retaining the source's fail-closed certificate
posture.

## Required tests

- sealed mode rejects a nonignored untracked file before checks execute;
- an untracked file changes both porcelain and the working-tree digest;
- a second edit while its `??` status remains unchanged changes the digest;
- create/delete/rename/type/mode transitions change the digest;
- ignored files do not affect porcelain or the digest;
- a symlink hashes its link text, not external target content;
- file-count/content-byte overflow and special/read-race failures return `nil`;
- collection refuses at max+1 before sorting the remaining enumerable, and a
  same-inode/same-size write between repeat reads returns `nil`;
- a verify command that mutates an untracked file is classified as tampered;
- convergence retracts a certificate after a later untracked mutation.

## Sign-off record

The operator explicitly approved `PORT-C1-2-AUDIT` on 2026-07-09, authorizing
decisions 1–7 above, the deliberate departure from camus's tracked-only flags,
and the fail-to-INCONCLUSIVE bounds. Implementation landed in the same working
tree under `JidoClaw.Orchestration.Verify.Git` with focused real-git coverage.
