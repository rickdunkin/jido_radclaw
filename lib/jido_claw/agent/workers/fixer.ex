defmodule JidoClaw.Agent.Workers.Fixer do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  # AR-4 self-heal fixer: a first-class worker (NOT a reuse of `coder`). Now that
  # `coder` self-reports too (`OutputSchema.coder_result/0`'s optional `signals`),
  # the justification is no longer "only the fixer can drive `explicit_signals/1`";
  # it is the fixer's DIFFERENT contract: (1) its own doctrine slice
  # (`fixer_contract`, keyed by template name) — resolve the open findings, then
  # report the domains the edits touched — and (2) `OutputSchema.fixer_result/0`'s
  # **required** `signals` (vs the coder's optional one), since self-reporting the
  # touched domains IS the fixer's whole job. The composer also injects the fixer's
  # baseline `code-written` (`RouteComposer.enforce_completion_signals/2`), so a
  # transient omission of that one still drives the re-review — but `auth-surface` /
  # `significant-build` have no injection backstop and rely on this field. Mutating
  # tool list + model copied from `Coder` (it rewrites the diff to resolve findings).
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_fixer",
    description:
      "Self-heal fixer: rewrites a change to resolve the open review findings, then self-reports which domains its edits touched so the right lenses re-review. Returns `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed`, `notes`, and `signals` (the domain signals it emits — always `code-written`, plus `auth-surface` / `significant-build` for touched domains).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.EditFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff,
      JidoClaw.Tools.GitCommit,
      JidoClaw.Tools.ProjectInfo
    ],
    model: :fast,
    max_iterations: 25,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema: OutputSchema.fixer_result(),
      retries: 1,
      on_validation_error: :repair
    }
end
