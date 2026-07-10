defmodule JidoClaw.Agent.Workers.SystemVerifier do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  # AR-8c: the verifier on the system path. Reviewer-SHAPED output
  # (`OutputSchema.reviewer_verdict/0`), so the `system-verifier` catalog stage's
  # `lens: "system"` makes `RouteComposer.Emit.DefaultMapper` (private `verdict/2`)
  # derive `clean:system` (approve, no findings) / `findings:system` (else) with
  # NO mapper change — convergence rides the existing `Loop.lenses_clean?/3`. But
  # its TOOLS are verifier-style: it inspects the REAL machine (`RunCommand` for
  # idempotent re-check / state assertion / exit code, read/list/search/git) to
  # confirm the change actually took — not just a paper review of the diff. Like
  # `system_executor` it is `composer_private` (no external MCP tools). A
  # `findings:system` re-fires the executor via the AR-8c reverse-verify loop
  # (`reverse_verify: true` on the stage); exhaustion → the `verify_failed`
  # terminal.
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_system_verifier",
    description:
      "Verifies a system/environment change actually took on the real machine: re-runs idempotent checks, asserts state, inspects command exit codes. File inspection is read-only; every command is independently operator-approved from its exact arguments before execution. Return a structured review (`overall`, short `summary`, an `action_needed` line, and a list of `findings`, each with a short stable `title`, `severity` info/warning/error, `confidence` likely/unsure, `location`, and `description`).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff,
      # Item 5 rider (OpenHelm OH1-3): read-only deterministic evidence for
      # the judge — sandboxed, lexical-only, tenant-scoped, Lua.Policy-capped.
      JidoClaw.Tools.LuaQuery,
      JidoClaw.Tools.LuaDocs
    ],
    model: :fast,
    max_iterations: 20,
    streaming: false,
    tool_timeout_ms: 60_000,
    compaction: [mode: :auto],
    output: %{
      schema: OutputSchema.reviewer_verdict(),
      retries: 1,
      on_validation_error: :repair
    }
end
