# Semi-Formal Reasoning for JidoClaw

## Context

The paper "Agentic Code Reasoning" (Ugare & Chandra, Meta, 2026) demonstrates that structured certificate templates — explicit premises, execution traces, formal conclusions — improve LLM agent accuracy by 5-12pp on code verification, review, and fault localization. Two concepts apply to JidoClaw:

1. **Certificate templates** — structured reasoning prompts for the Verifier that prevent premature judgments
2. **Execution-free verification feeding trust scoring** — certificate confidence as a new verification status

The implementation extends three existing systems (trust scoring, tools, solution store) and adds one new module. No new architectural layers. The strategy registry and `reason` tool are not modified.

---

## Phase 1: Certificate Templates

### New: `lib/jido_claw/reasoning/certificates.ex`

Pure-functional module. Four task-specific templates and a JSON parser.

**Templates** — each returns a prompt string via `template_for(type, context_map) :: String.t()`. The `context_map` accepts `:code`, `:specification`, and `:evidence` (verifier's gathered analysis).

- `:patch_verification` — payload requires: per-test claims (each test traced through both patches), comparison outcome per test, counterexample or proof of equivalence, formal conclusion referencing definitions
- `:code_review` — payload requires: invariant list the code must preserve, per-invariant trace with boundary inputs, violation list with severity/confidence, edge case analysis
- `:fault_localization` — payload requires: test semantics premises, code path tracing observations (file:line per method), divergence claims (each references a premise), ranked predictions with supporting claims
- `:code_qa` — payload requires: function trace table (function, file:line, param types, return type, verified behavior), data flow analysis (variable lifecycle), semantic properties with evidence, alternative hypothesis check

**Certificate output format** — typed envelope with task-specific nested payload, fenced as JSON. Different certificate types have different required `payload` keys. See Phase 3 for the full example.

**Parser** `parse_certificate/1`:
- Extracts fenced JSON block between ` ```certificate ` and ` ``` `
- Decodes via `Jason.decode/1` (produces all-string keys)
- Error variants: `{:error, :no_certificate}` (no fenced block), `{:error, :invalid_json}` (block found, bad JSON), `{:error, :invalid_shape}` (parsed but missing required keys, unknown type, or confidence outside 0.0-1.0)
- Validates per type: `"type"` in known set, `"verdict"` present, `"confidence"` is number in 0.0-1.0, required `"payload"` keys present for the given type

**Type normalization** — `normalize_type/1` via fixed map, never `String.to_atom/1`:
```elixir
@type_map %{
  "patch_verification" => :patch_verification,
  "code_review" => :code_review,
  "fault_localization" => :fault_localization,
  "code_qa" => :code_qa
}
```

**Public API**: `template_for/2`, `parse_certificate/1`, `types/0`, `valid?/1`, `normalize_type/1`

---

## Phase 2: Trust Scoring and Store

### Modify: `lib/jido_claw/solutions/trust.ex`

Add two `score_verification/1` clauses before the catch-all at line 154:

```elixir
defp score_verification(%{status: "semi_formal", confidence: c})
     when is_number(c) and c >= 0.0 and c <= 1.0,
     do: c * 0.85

defp score_verification(%{"status" => "semi_formal", "confidence" => c})
     when is_number(c) and c >= 0.0 and c <= 1.0,
     do: c * 0.85
```

### Modify: `lib/jido_claw/solutions/store.ex`

Add `update_verification_and_trust/3`:

```elixir
@spec update_verification_and_trust(String.t(), map(), keyword()) ::
        {:ok, Solution.t()} | :not_found | {:error, :not_running}
def update_verification_and_trust(id, verification_map, trust_opts \\ [])
```

Client: when `GenServer.whereis(__MODULE__)` is nil, return `{:error, :not_running}`.

Server handler:
1. ETS lookup — reply `:not_found` if missing
2. `updated = %{solution | verification: verification_map}`
3. `score = Trust.compute(updated, trust_opts)`
4. `updated = %{updated | trust_score: score, updated_at: utc_now_iso()}`
5. Single ETS insert + `persist_to_disk`
6. Reply `{:ok, updated}`

---

## Phase 3: VerifyCertificate Tool

### New: `lib/jido_claw/tools/verify_certificate.ex`

`use Jido.Action` tool. Provides structured certificate output. Wraps CoT internally.

**Schema**:
- `code` — required string, the code/patch to verify
- `specification` — required string, what the code should do
- `evidence` — optional string, gathered analysis from prior exploration (ReadFile/SearchCode/GitDiff output). Interpolated into the certificate template so the CoT runner has repo evidence.
- `certificate_type` — optional string, default `"patch_verification"`, normalized via fixed map
- `solution_id` — optional string

**Output schema**:
- `verdict` — string
- `confidence` — float
- `certificate` — map (full parsed certificate including type, payload, formal_conclusion — all string keys)
- `trust_score` — float or nil
- `persistence_error` — string or nil

**Runner output contract**: `RunStrategy.run/2` returns `{:ok, %{output: term(), ...}}` on success. The tool extracts the output via a private `extract_output/1` that handles the same shapes as `reason.ex:99-111` — binary passthrough, map with `:result`/`:answer`/`:conclusion` key, or `inspect/1` fallback. This is a local helper, not a shared module (avoids coupling to `reason.ex` internals).

**Run logic**:
1. Normalize `certificate_type` via `Certificates.normalize_type/1` — error if unknown
2. Build prompt via `Certificates.template_for(type, %{code: code, specification: spec, evidence: evidence})`
3. Call `runner.run(%{strategy: :cot, prompt: prompt, timeout: 60_000}, %{})` where `runner` is read from context (default `Jido.AI.Actions.Reasoning.RunStrategy`)
4. Extract output string via `extract_output/1`
5. Parse via `Certificates.parse_certificate/1` — propagate `:no_certificate`, `:invalid_json`, `:invalid_shape` as tool errors
6. If `solution_id` provided:
   - Build verification map: `Map.merge(%{"status" => "semi_formal"}, parsed_certificate)` — **all string keys** since `Jason.decode` produces string keys and `score_verification` has string-key clauses
   - Call `Store.update_verification_and_trust(id, verification_map)`
   - On `{:ok, updated}`: set `trust_score` from updated solution
   - On `:not_found` or `{:error, :not_running}`: **return the certificate anyway** with `trust_score: nil` and `persistence_error: "reason"`. The certificate analysis is valuable independent of persistence.
7. Return result map

**Testing seam**: Tool reads `:reasoning_runner` from `context` map, defaults to `Jido.AI.Actions.Reasoning.RunStrategy`. Tests inject a stub module returning `{:ok, %{output: "```certificate\n{...}\n```"}}`.

---

## Phase 4: Worker and Agent Registration

### Modify: `lib/jido_claw/agent/workers/verifier.ex`

Add `JidoClaw.Tools.VerifyCertificate` to tools list.

### Do NOT modify: `lib/jido_claw/agent/workers/reviewer.ex`

Read-only contract stays intact.

### Modify: `lib/jido_claw/agent/agent.ex`

Add `JidoClaw.Tools.VerifyCertificate` after line 37.

---

## Phase 5: Skills and Documentation

### New: `.jido/skills/verified_feature.yaml`

Iterative skill. Evaluator explores first, then passes evidence to certificate tool:

```yaml
name: verified_feature
description: Implement a feature with semi-formal pre-verification
mode: iterative
max_iterations: 5
steps:
  - name: implement
    role: generator
    template: coder
    task: "Implement the feature following existing project patterns"
    produces:
      type: elixir_module
  - name: pre_verify
    role: evaluator
    template: verifier
    task: |
      Verify the implementation through structured analysis:
      1. Read the implementation code and any files it touches
      2. Search for related tests, modules, and dependencies
      3. Check git diff for the full scope of changes
      4. Run: mix compile --warnings-as-errors
      5. Collect all findings from steps 1-4 as evidence text
      6. Call verify_certificate with:
         - code: the implementation
         - specification: the original task description
         - evidence: your collected findings from steps 1-4
      If certificate confidence >= 0.8 and verdict PASS, emit VERDICT: PASS.
      Otherwise emit VERDICT: FAIL with specific issues from the certificate.
    consumes: [implement]
synthesis: "Present the final implementation with verification certificate"
```

### New: `.jido/skills/sfr_review.yaml`

DAG skill. One researcher step identifies all changed files and their scope. One verifier step reviews all changed areas in a single run (not dynamic fan-out — the skills system is a fixed YAML graph, not runtime expansion), generating a certificate covering the full change set:

```yaml
name: sfr_review
description: Code review with semi-formal reasoning certificate
steps:
  - name: analyze_scope
    template: researcher
    task: "Identify all changed files via git diff. For each, note what it does and what tests cover it."
  - name: certificate_review
    template: verifier
    task: |
      Review all changes identified in the scope analysis:
      1. Read each changed file and its related modules
      2. Search for tests covering the changed code
      3. Run: mix compile --warnings-as-errors
      4. Collect all findings as evidence text
      5. Call verify_certificate with certificate_type "code_review":
         - code: the git diff of all changes
         - specification: what the changes intend to accomplish (from scope analysis)
         - evidence: your collected findings
      Report the certificate verdict and any issues found.
    depends_on: [analyze_scope]
synthesis: "Present code review findings with semi-formal certificate and confidence scores"
```

### Modify: `lib/jido_claw/platform/skills.ex`

Add both skills to `@default_skills` map.

### Modify: `priv/defaults/system_prompt.md`

Add `verify_certificate` tool docs. Migration gap: won't affect existing `.jido/system_prompt.md`.

---

## What Is NOT In This Plan

- **No `prefilter_verify` tool** — no Forge verification pipeline to gate
- **No strategy registry changes** — `VerifyCertificate` wraps `:cot` internally
- **No `reason.ex` changes** — certificate reasoning lives in dedicated tool
- **No reviewer modification** — read-only contract preserved
- **No `problem_description` on Solution** — tool requires spec explicitly
- **No certificate history resource** — full certificate stored in `verification` map; dedicated Ash resource is right follow-up for queryability
- **No MCP server registration** — noted as follow-up

---

## Files Summary

| Action | File |
|--------|------|
| **Create** | `lib/jido_claw/reasoning/certificates.ex` |
| **Create** | `lib/jido_claw/tools/verify_certificate.ex` |
| **Create** | `.jido/skills/verified_feature.yaml` |
| **Create** | `.jido/skills/sfr_review.yaml` |
| Modify | `lib/jido_claw/solutions/trust.ex` — 2 clauses before line 154 |
| Modify | `lib/jido_claw/solutions/store.ex` — new `update_verification_and_trust/3` |
| Modify | `lib/jido_claw/agent/workers/verifier.ex` — add VerifyCertificate to tools |
| Modify | `lib/jido_claw/agent/agent.ex` — add VerifyCertificate to tools |
| Modify | `lib/jido_claw/platform/skills.ex` — 2 skills in `@default_skills` |
| Modify | `priv/defaults/system_prompt.md` — tool docs |

---

## Tests

| Test File | Coverage |
|-----------|----------|
| `test/jido_claw/reasoning/certificates_test.exs` | `template_for/2` per type returns string with type-specific sections; evidence interpolated when provided; `parse_certificate/1` extracts valid fenced JSON with all-string keys; error variants: `:no_certificate`, `:invalid_json`, `:invalid_shape`; per-type payload key validation; `normalize_type/1` via fixed map, rejects unknown |
| `test/jido_claw/solutions/trust_test.exs` (extend) | `score_verification` with `semi_formal` at 0.0/0.5/0.92/1.0; both atom/string keys; confidence outside 0.0-1.0 falls to catch-all 0.3 |
| `test/jido_claw/solutions/store_test.exs` (extend) | `update_verification_and_trust/3`: `{:ok, solution}` with both fields updated; `:not_found` for missing id; `{:error, :not_running}` when server down; trust_score recomputed from new verification |
| `test/jido_claw/tools/verify_certificate_test.exs` | Injected stub runner; schema validation; evidence threaded into template; certificate_type normalization; `extract_output/1` handles string/map/fallback; parse error propagation; store updated with all-string-key map when `solution_id` given; certificate returned with `trust_score: nil` and `persistence_error` on store failure; no store call when `solution_id` absent |

---

## Verification

1. `mix compile --warnings-as-errors`
2. `mix format --check-formatted`
3. `mix test test/jido_claw/reasoning/certificates_test.exs`
4. `mix test test/jido_claw/solutions/trust_test.exs`
5. `mix test test/jido_claw/solutions/store_test.exs`
6. `mix test test/jido_claw/tools/verify_certificate_test.exs`
7. `mix test` — full suite
8. Manual: `mix jidoclaw` then have verifier explore a file and invoke `verify_certificate` with gathered evidence
