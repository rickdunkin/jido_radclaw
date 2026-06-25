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
  Reviewer verdict object (`overall`/`summary`/`findings`) — the shape
  `JidoClaw.RouteComposer.Emit.DefaultMapper.reviewer_verdict/3` consumes, shared
  by every read-only judge worker (`Reviewer`, `SketchReviewer`).
  """
  @spec reviewer_verdict() :: Zoi.schema()
  def reviewer_verdict do
    Zoi.object(%{
      overall: Zoi.enum([:approve, :request_changes, :comment]),
      summary: Zoi.string(),
      findings:
        Zoi.array(
          Zoi.object(
            %{
              severity: Zoi.enum(info: "info", warning: "warning", error: "error"),
              description: Zoi.string()
            },
            coerce: true
          )
        )
    })
  end
end
