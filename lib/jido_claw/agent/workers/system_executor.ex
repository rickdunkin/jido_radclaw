defmodule JidoClaw.Agent.Workers.SystemExecutor do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  # AR-8c: the mutating worker on the system path. Coder-shaped (`status`/
  # `summary`/`files_changed`/`notes` + `artifacts`), but its toolset is centered
  # on `RunCommand` (`tool_timeout_ms: 60_000`, like `Verifier` — it runs CLI
  # tooling / config edits against the REAL machine). It is `composer_private`
  # (registered in `JidoClaw.Agent.Templates`), so a misbehaving main agent can
  # never spawn it directly past the safety gate, and it gets ZERO external MCP
  # tools (`external_tools?/1` is false). It carries NO `signals` output field:
  # the verifier is ordered after it by the `system-change` data edge, not by a
  # completion signal (the `sketch-build` → `sketch-review` pattern). The
  # `summary`/`notes`/`artifacts` ARE the machine-state description the verifier
  # checks; the `ComposerArtifact` store encrypts them at rest.
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_system_executor",
    description:
      "Applies an approved change to the machine/environment: updates configs, runs CLI tooling, changes the environment. Reads, writes, edits files, runs commands, and inspects git state. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `notes` for caveats.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
      JidoClaw.Tools.EditFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.GitStatus,
      JidoClaw.Tools.GitDiff
    ],
    model: :fast,
    max_iterations: 25,
    streaming: false,
    tool_timeout_ms: 60_000,
    compaction: [mode: :auto],
    output: %{
      schema: OutputSchema.builder_result(),
      retries: 1,
      on_validation_error: :repair
    }
end
