defmodule JidoClaw.Agent.Workers.SketchBuild do
  @moduledoc false
  alias JidoClaw.Agent.Workers.OutputSchema

  # AR-8b sketch worker. File tools ONLY — no `RunCommand`/git, which shell to
  # the host and bypass the VFS jail. Its `sandbox: :prototype` template policy
  # (registered in `JidoClaw.Agent.Templates`) is the real capability boundary;
  # this tool list is the corroborating in-worker restriction. The three
  # read-real tools (AR-8b-2 F3) let it be *informed* by the real project tree
  # (read-only) without being able to mutate it — every write still lands in the
  # `.prototypes/<id>/` sandbox.
  #
  # The output schema deliberately carries NO `signals` field: its absence makes
  # `RouteComposer.Emit.DefaultMapper.explicit_signals/1` emit `[]`, so the
  # sketch-build stage publishes no new signals of its own.
  use JidoClaw.Agent.Defaults,
    name: "jido_claw_sketch_build",
    description:
      "Builds a throwaway prototype in an isolated sandbox: a tracer-bullet, scaffold, diagram, or idea sketch. Writes files only — never runs commands or touches git. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `notes`.",
    tools: [
      JidoClaw.Tools.ReadFile,
      JidoClaw.Tools.WriteFile,
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
      schema:
        Zoi.object(%{
          status: Zoi.enum([:completed, :partial, :blocked]),
          summary: Zoi.string(),
          files_changed: Zoi.array(Zoi.string()),
          notes: Zoi.optional(Zoi.string()),
          artifacts: OutputSchema.artifacts()
        }),
      retries: 1,
      on_validation_error: :repair
    }
end
