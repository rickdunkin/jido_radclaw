defmodule Mix.Tasks.Jidoclaw.Graphql.Schema.Check do
  @moduledoc """
  Checks that the committed SDL golden (`ui/schema.graphql`) byte-matches
  the compiled `/gql` schema — the precommit drift guard pairing
  `mix jidoclaw.graphql.schema` (the writer).

  A mismatch (or missing golden) fails with regeneration instructions, so
  resource drift cannot land without the client-facing schema moving in the
  same change (SYNTHESIS §5.5).
  """

  use Mix.Task

  alias JidoClaw.Web.GraphQL.SDL

  @shortdoc "Checks ui/schema.graphql drift against the compiled GraphQL schema"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    case SDL.problems() do
      [] ->
        Mix.shell().info("GraphQL SDL golden in sync (#{SDL.golden_path()}).")

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)

        Mix.raise(
          "GraphQL SDL drift detected — run mix jidoclaw.graphql.schema " <>
            "and commit ui/schema.graphql"
        )
    end
  end
end
