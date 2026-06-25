defmodule JidoClaw.Agent.Workers.OutputSchema do
  @moduledoc "Shared Zoi schema fragments single-sourced across worker `output:` blocks (AR-5)."

  @doc """
  Builder result object (`status`/`summary`/`files_changed`/`notes` + runtime
  `artifacts`) — the shape a mutating producer worker returns, shared by `Coder`
  and the AR-8c `SystemExecutor` (which apply changes and report what changed).
  """
  @spec builder_result() :: Zoi.schema()
  def builder_result do
    Zoi.object(%{
      status: Zoi.enum([:completed, :partial, :blocked]),
      summary: Zoi.string(),
      files_changed: Zoi.array(Zoi.string()),
      notes: Zoi.string(),
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
  `JidoClaw.RouteComposer.Emit.DefaultMapper.reviewer_verdict/3` consumes, shared
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
