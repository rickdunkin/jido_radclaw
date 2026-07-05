defmodule JidoClaw.Agent.Workers.OutputSchema do
  @moduledoc "Shared Zoi schema fragments single-sourced across worker `output:` blocks (AR-5)."

  @doc """
  Builder result object (`status`/`summary`/`files_changed`/`notes` + runtime
  `artifacts`) — the shape a mutating producer worker returns. Now the AR-8c
  `SystemExecutor`'s schema *specifically* (it applies a change and reports what
  changed; its verifier is ordered by the `system-change` data edge, so it carries
  **NO** `signals` field). `Coder` moved to `coder_result/0` — the same builder
  fields PLUS an optional `signals` list — so a real `implementer` / `test-author`
  run self-reports `code-written` / `tests-ready`. The shared fields are factored
  into the private `builder_fields/0` (NOT copied into `coder_result/0`, so the
  ExSlop clone gate stays clean).
  """
  @spec builder_result() :: Zoi.schema()
  def builder_result, do: Zoi.object(builder_fields())

  @doc """
  Coder result object — the builder fields (`status`/`summary`/`files_changed`/
  `notes` + runtime `artifacts`) PLUS an **optional** `signals` string list. The
  shape the `Coder` template returns; `Coder` backs BOTH the `implementer` stage
  (self-reports `code-written`) and the `test-author` stage (self-reports
  `tests-ready`).

  `signals` is **optional** for two reasons: a transient omission of the
  loop-INJECTED completion signal (`code-written`, guaranteed by
  `JidoClaw.RouteComposer.enforce_completion_signals/2`) falls back to injection
  rather than a validation failure, and the field is backward-compatible for any
  no-`signals` `Coder` sample. The signals with **no** injection backstop —
  `tests-ready` (the test-author's ONLY emission path; deliberately not injected,
  so a COMPLETED test-author that omits it leaves the implementer honestly held —
  while a BLOCKED test-author instead route-fails at the mapper,
  `JidoClaw.RouteComposer.Emit.DefaultMapper.refuse_blocked_producer/2`) and the
  conditional `scope-shift` — are self-reported through THIS field only.

  `JidoClaw.RouteComposer.Emit.DefaultMapper`'s `explicit_signals/1` matches these
  against the stage's `publishes` **strings**, so they MUST be strings; like
  `builder_result/0`, `signals` is never persisted as an artifact, so no
  `Envelope.normalize` atom concern applies.
  """
  @spec coder_result() :: Zoi.schema()
  def coder_result,
    do: Zoi.object(Map.put(builder_fields(), :signals, Zoi.optional(Zoi.array(Zoi.string()))))

  # The builder fields shared by `builder_result/0` (SystemExecutor) and
  # `coder_result/0` (Coder). Factored to one source so `coder_result/0` is not a
  # near-clone of `builder_result/0` (the ExSlop/ExDNA clone gate). Uses the map
  # `Zoi.object/1` form (the keyword-list form trips Dialyzer); key order is not
  # significant.
  defp builder_fields do
    %{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      notes: Zoi.string(),
      artifacts: artifacts()
    }
  end

  @doc """
  Fixer result object (`status`/`summary`/`files_changed`/`notes` + a `signals`
  list + runtime `artifacts`) — the shape the AR-4 self-heal `Fixer` returns.

  Builder-like, but with one load-bearing extra: a **`signals`** field carrying
  the domain signals the fixer self-reports for what its edits touched
  (`code-written` always, plus `auth-surface` / `significant-build` for the
  domains it wandered into). `JidoClaw.RouteComposer.Emit.DefaultMapper`'s
  `explicit_signals/1` matches these against the stage's `publishes` **strings**,
  so they MUST be strings (the loop's domain→lens derivation decides which
  reviewers re-run from them). `signals` is never persisted (not in
  `stage.output` — the `fix` artifact resolves to `summary` text via the
  `output_value/3` fallback), so no `Envelope.normalize` atom concern applies and
  `status` stays a plain atom enum like `builder_result/0`.

  Uses the map `Zoi.object/1` form (the keyword-list form trips Dialyzer); key
  order is not significant. The worker's `on_validation_error: :repair` recovers
  a transient field omission.
  """
  @spec fixer_result() :: Zoi.schema()
  def fixer_result do
    Zoi.object(%{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      notes: Zoi.string(),
      signals: Zoi.array(Zoi.string()),
      artifacts: artifacts()
    })
  end

  @doc "Runtime-artifacts object reused by 5 workers (optional url/port/files, preserve unknowns)."
  @spec artifacts() :: Zoi.schema()
  def artifacts do
    Zoi.object(
      %{
        url: Zoi.optional(Zoi.string()),
        port: Zoi.optional(Zoi.string()),
        files: Zoi.optional(Zoi.string())
      },
      unrecognized_keys: :preserve
    )
  end

  @doc """
  Reviewer verdict object (`overall`/`summary`/`action_needed`/`findings`, each
  finding `severity`/`confidence`/`location`/`description`) — the shape
  `JidoClaw.RouteComposer.Emit.DefaultMapper` consumes (via its private
  `verdict/2`), shared
  by the three `reviewer_contract`-carrying judges (`Reviewer`, `SketchReviewer`,
  `SystemVerifier`). The doctrine `reviewer_contract` slice is the prose half of
  this contract (and the source the LLM reads for field order/intent).

  Field-type rationale, which the artifact round-trip depends on:

  - `overall` is an **atom** enum — it drives `DefaultMapper`'s signal logic
    (`approve?`/`@verdicts`) and is never written to a composer artifact.
  - `severity` and `confidence` are **string** enums. `findings` IS stored as an
    artifact, and `ComposerArtifact.Envelope.normalize/1` `inspect/1`s every atom
    *value* — an atom enum (`:error`) would persist as the string `":error"`,
    colon and all. String enums parse to clean `"error"`/`"likely"` that pass
    through `normalize/1` untouched.

  Uses the map `Zoi.object/2` form (matching `Zoi`'s `fields :: map()` spec —
  the keyword-list form trips Dialyzer); key order is therefore not significant.
  New fields are required (Zoi object keys are required by default); the workers'
  `on_validation_error: :repair` recovers a transient omission.
  """
  @spec reviewer_verdict() :: Zoi.schema()
  def reviewer_verdict do
    Zoi.object(%{
      overall: Zoi.enum([:approve, :request_changes, :comment]),
      summary: Zoi.string(),
      action_needed: Zoi.string(),
      findings:
        Zoi.array(
          Zoi.object(
            %{
              severity: Zoi.enum(["info", "warning", "error"]),
              confidence: Zoi.enum(["likely", "unsure"]),
              location: Zoi.string(),
              description: Zoi.string()
            },
            coerce: true
          )
        )
    })
  end
end
