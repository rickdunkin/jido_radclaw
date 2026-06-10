defmodule JidoClaw.Agent.Workers.TestRunner do
  @moduledoc false
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_test_runner",
    description:
      "Runs tests and reports results. Read-only access to files with command execution for running test suites. Return a structured result with `status` (`passed`/`failed`/`error` — `error` for test-runner crashes/setup failures distinct from `failed` for test assertions), a one-line `summary`, `passed_count` / `failed_count` (non-negative), a list of `failures` (each with the failing `test` name and its `error` message), and `artifacts` (an object with optional `url`/`port`/`files` — use `{}` if none).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.SearchCode
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema:
        Zoi.object(%{
          status: Zoi.enum([:passed, :failed, :error]),
          summary: Zoi.string(),
          passed_count: Zoi.gte(Zoi.integer(), 0),
          failed_count: Zoi.gte(Zoi.integer(), 0),
          failures:
            Zoi.array(
              Zoi.object(
                %{
                  test: Zoi.string(),
                  error: Zoi.string()
                },
                coerce: true
              )
            ),
          artifacts:
            Zoi.object(
              %{
                url: Zoi.optional(Zoi.string()),
                port: Zoi.optional(Zoi.string()),
                files: Zoi.optional(Zoi.string())
              },
              unrecognized_keys: :preserve
            )
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
