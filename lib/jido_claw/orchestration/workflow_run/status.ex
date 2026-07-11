defmodule JidoClaw.Orchestration.WorkflowRun.Status do
  @moduledoc """
  The run-status enum backing `WorkflowRun.status` — the single source for
  the seven lifecycle values every surface enumerates.

  Introduced by argus P1: ash_graphql maps plain `:atom` attributes to
  GraphQL `String` (no auto-enum from a `one_of` constraint), so exposing a
  typed `WorkflowRunStatus` on `/gql` requires a real `Ash.Type.Enum` with a
  `graphql_type/1`. Storage is unchanged (text column, atom values in
  Elixir) — only the type declaration moved from an inline `one_of`
  constraint into this module. Consumers that need the value set read
  `values/0` (the Lua `jido.runs` status validator does), never a
  re-declared list.
  """

  use Ash.Type.Enum,
    values: [
      :pending,
      :running,
      :awaiting_approval,
      :completed,
      :failed,
      :cancelled,
      :abandoned
    ]

  # Not a behaviour callback — ash_graphql probes for it with
  # `function_exported?/3` when deriving the schema type for enum attributes.
  @spec graphql_type(term()) :: atom()
  def graphql_type(_constraints), do: :workflow_run_status
end
