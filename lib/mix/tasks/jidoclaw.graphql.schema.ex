defmodule Mix.Tasks.Jidoclaw.Graphql.Schema do
  @moduledoc """
  Writes the `/gql` schema's SDL to the committed golden
  (`ui/schema.graphql`) — the single writer of that file.

  Run after any change to the GraphQL-exposed resources/domains, then commit
  the regenerated golden; `mix jidoclaw.graphql.schema.check` (in the
  `precommit` alias) fails until the two match.
  """

  use Mix.Task

  alias JidoClaw.Web.GraphQL.SDL

  @shortdoc "Writes the GraphQL SDL golden to ui/schema.graphql"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    path = SDL.golden_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, SDL.render())
    Mix.shell().info("wrote #{path}")
  end
end
