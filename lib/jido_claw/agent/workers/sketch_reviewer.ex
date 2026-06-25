defmodule JidoClaw.Agent.Workers.SketchReviewer do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  # AR-8b-2 F1: the light-lens correctness reviewer on the sketch path. Runs in
  # the SAME `.prototypes/<uuid>/` sandbox as `sketch_build` (`sandbox: :prototype`
  # template policy, registered in `JidoClaw.Agent.Templates`), so it carries only
  # read/list/search file tools — NO `GitDiff`/`GitStatus` (no git in the sandbox).
  # The three read-real tools let it be *informed* by the real project (read-only)
  # without being able to mutate it.
  #
  # It reuses `Reviewer`'s output schema (`OutputSchema.reviewer_verdict/0`), so
  # `RouteComposer.Emit.DefaultMapper.reviewer_verdict/3` maps its `overall`/
  # `findings` to `clean:correctness` / `findings:correctness` with no mapper
  # change — flipping the sketch path from trivially-clean to lens-gated.
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_sketch_reviewer",
    description:
      "Reviews a throwaway prototype in an isolated sandbox for logic and edge-case correctness. Read-only file tools (plus read-only access to the real project tree) — never runs commands or touches git. Return a structured review (`overall`, short `summary`, an `action_needed` line, and a list of `findings`, each with `severity` info/warning/error, `confidence` likely/unsure, `location`, and `description`).",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.ListDirectory,
      JidoClaw.Tools.SearchCode,
      JidoClaw.Tools.ReadRealFile,
      JidoClaw.Tools.SearchRealCode,
      JidoClaw.Tools.ListRealDirectory
    ],
    model: :fast,
    max_iterations: 15,
    streaming: false,
    tool_timeout_ms: 30_000,
    compaction: [mode: :auto],
    output: %{
      schema: OutputSchema.reviewer_verdict(),
      retries: 1,
      on_validation_error: :repair
    }
end
