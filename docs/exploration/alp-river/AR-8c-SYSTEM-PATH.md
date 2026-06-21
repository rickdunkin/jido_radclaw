# AR-8c — The System Path (verified machine change)

*Architecture direction — extends AR-2 §8 / AR-8. Not a commitment.*

**Context.** AR-8 triage classifies OS-level work as `system` — "update configs,
troubleshoot, run CLI tooling, change the environment" (Alp River
`agents/triage.md`); a path defined by leaving "a verified change to the machine."
Phase 3 routes `system` through the **shared** `planner`/`plan-gate` (catalog
`routes: ["code","system"]`), so a system turn behaves exactly like `code` up to
the gate. The system-specific stages do not exist. This doc designs them.

**Why separate.** It needs new safety-critical worker templates, a **safety gate**
(a Phase-4 gate-producer), and the **reverse-verify loop** (the first real use of
the `stages_invalidated` rerun primitive, §4). Depends on Phase 4 (gates) landing
first.

**Phases.**

- **A — `system-executor` + `system-verifier` workers + catalog stages.**
  `planner → safety-gate → system-executor → system-verifier`, validator-clean,
  `routes: ["system"]`.
- **B — `Reactors.SafetyGate` gate-producer** (`unit: {:gate, "safety"}`), gating
  `destructive-op`/`irreversible` (the system-flavored risk signals triage already
  emits). **Depends on Phase 4.**
- **C — Reverse-verify loop.** `system-verifier` re-fires on a `verify-failed` signal by
  removing `system-executor` from `ran` via a durable `stages_invalidated` event
  (AR-2 §4/§6), bounded by the per-stage rerun cap.
- **D — System terminal semantics.** A machine change that won't verify is a distinct
  failure from `:not_converged`.

**Open questions.** What "verified" means per system op (idempotent re-check vs state
assertion); safety-gate UX for irreversible ops; reconciling environmental artifacts
(a `diff` of machine state) with the artifact store.
