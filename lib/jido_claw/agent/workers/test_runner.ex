defmodule JidoClaw.Agent.Workers.TestRunner do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  use JidoClaw.Agent.Defaults,
    name: "jido_claw_test_runner",
    description:
      "Runs tests and reports results. Read-only access to files with command execution for running test suites. Return a structured result with `status` (`passed`/`failed`/`error` — `error` for test-runner crashes/setup failures distinct from `failed` for test assertions), a one-line `summary`, `passed_count` / `failed_count` (non-negative), and a list of `failures` (each with the failing `test` name and its `error` message).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.RunCommand,
      JidoClaw.Tools.FetchOutput,
      JidoClaw.Tools.SearchCode,
      # Item 5 rider (OpenHelm OH1-3): read-only deterministic evidence for
      # the judge — sandboxed, lexical-only, tenant-scoped, Lua.Policy-capped.
      JidoClaw.Tools.LuaQuery,
      JidoClaw.Tools.LuaDocs
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
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
