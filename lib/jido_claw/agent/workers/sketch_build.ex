defmodule JidoClaw.Agent.Workers.SketchBuild do
  @moduledoc false

  # AR-8b sketch worker. File tools ONLY — no `RunCommand`/git, which shell to
  # the host and bypass the VFS jail. Its `sandbox: :prototype` template policy
  # (registered in `JidoClaw.Agent.Templates`) is the real capability boundary;
  # the tool list (single-sourced in `SketchWorker` with `exec?: false`) is the
  # corroborating in-worker restriction. The three read-real tools (AR-8b-2 F3)
  # let it be *informed* by the real project tree (read-only) without being able
  # to mutate it — every write still lands in the `.prototypes/<id>/` sandbox.
  use JidoClaw.Agent.Workers.SketchWorker,
    exec?: false,
    name: "jido_claw_sketch_build",
    description:
      "Builds a throwaway prototype in an isolated sandbox: a tracer-bullet, scaffold, diagram, or idea sketch. Writes files only — never runs commands or touches git. Return a structured result with `status` (`completed`/`partial`/`blocked`), a short `summary`, `files_changed` (list of paths), and `notes`."
end
