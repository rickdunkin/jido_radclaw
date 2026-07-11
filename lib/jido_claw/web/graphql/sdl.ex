defmodule JidoClaw.Web.GraphQL.SDL do
  @moduledoc """
  Pure SDL rendering + golden-drift detection for the `/gql` schema.

  `render/0` is the single writer's source: `mix jidoclaw.graphql.schema`
  dumps it to the committed golden (`ui/schema.graphql`) and
  `mix jidoclaw.graphql.schema.check` (in the `precommit` alias) fails on
  any byte difference — resource drift without a regenerated client schema
  cannot pass the gate (SYNTHESIS §5.5: advertisement without mechanical
  enforcement rots). The `ui/` client's codegen (argus P2) reads the same
  file.
  """

  @schema JidoClaw.Web.GraphQL.Schema

  @golden_path Path.join("ui", "schema.graphql")

  @regen_hint "run `mix jidoclaw.graphql.schema` and commit ui/schema.graphql"

  @doc """
  The compiled schema's SDL, normalized to exactly one trailing newline so
  byte-comparison against the committed golden is editor-safe.
  """
  @spec render() :: String.t()
  def render do
    @schema
    |> Absinthe.Schema.to_sdl()
    |> String.trim_trailing("\n")
    |> Kernel.<>("\n")
  end

  @doc "Repo-relative path of the committed SDL golden."
  @spec golden_path() :: Path.t()
  def golden_path, do: @golden_path

  @doc """
  Drift problems between `render/0` and the golden; `[]` means in sync.

  Options:

    * `:golden_path` — override the golden location (tests point this at
      tmp files for red/green coverage).

  Every problem string carries the regeneration instruction.
  """
  @spec problems(keyword()) :: [String.t()]
  def problems(opts \\ []) do
    path = Keyword.get(opts, :golden_path, golden_path())

    case File.read(path) do
      {:ok, golden} ->
        if golden == render() do
          []
        else
          ["#{path} does not match the compiled schema SDL — #{@regen_hint}"]
        end

      {:error, reason} ->
        ["cannot read #{path} (#{inspect(reason)}) — #{@regen_hint}"]
    end
  end
end
