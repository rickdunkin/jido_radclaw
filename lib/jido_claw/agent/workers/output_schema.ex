defmodule JidoClaw.Agent.Workers.OutputSchema do
  @moduledoc "Shared Zoi schema fragments single-sourced across worker `output:` blocks (AR-5)."

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
