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
end
