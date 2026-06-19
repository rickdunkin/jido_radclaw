defmodule JidoClaw.RouteComposer.TestFixtures do
  @moduledoc """
  Shared builders and assertion helpers for the route-composer suite — the
  Elixir analogue of Alp River `test_route.py`'s `S()` factory, `CATALOG`, and
  `_lock_catalog`.

  Every fixture routes through `stage/1` and the named catalog builders so the
  port stays structurally DRY (one builder, no duplicated stage literals across
  test files).
  """

  import ExUnit.Assertions

  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.Stage

  @doc """
  Builds a `%Stage{}` from `S()`-style keyword opts. Unspecified fields take
  their struct defaults; `:req` / `:opt` populate `input.required` /
  `input.optional`, and `:sub` / `:pub` populate `subscribes` / `publishes`.
  `:model` / `:effort` / `:emit` pass straight through to the same-named struct
  fields (defaulting to `nil` / `nil` / `:default` — i.e. the struct defaults).
  """
  @spec stage(keyword()) :: Stage.t()
  def stage(opts) do
    %Stage{
      name: Keyword.get(opts, :name),
      unit: Keyword.get(opts, :unit),
      task: Keyword.get(opts, :task),
      lens: Keyword.get(opts, :lens),
      guard: Keyword.get(opts, :guard),
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort),
      emit: Keyword.get(opts, :emit, :default),
      routes: Keyword.get(opts, :routes, []),
      input: %{required: Keyword.get(opts, :req, []), optional: Keyword.get(opts, :opt, [])},
      output: Keyword.get(opts, :out, []),
      subscribes: Keyword.get(opts, :sub, []),
      publishes: Keyword.get(opts, :pub, []),
      lock: Keyword.get(opts, :lock, [])
    }
  end

  @doc """
  The 8-stage synthetic catalog from `test_route.py` (`CATALOG`). Names are
  stamped from the map keys so the catalog is self-consistent; the router never
  reads `name`, and this catalog is intentionally **not** validator-clean
  (`scan` triggers on the raw path topic `code`).
  """
  @spec synthetic_catalog() :: %{String.t() => Stage.t()}
  def synthetic_catalog do
    key_named(%{
      "scan" =>
        stage(
          routes: ["code", "talk"],
          req: ["intent"],
          out: ["reuse-map"],
          sub: ["code"],
          pub: ["missing-infra", "scope-shift"]
        ),
      "impl" =>
        stage(
          routes: ["code"],
          req: ["plan", "tests"],
          out: ["diff"],
          sub: ["plan-ready"],
          pub: ["code-written", "scope-shift"]
        ),
      "sec" =>
        stage(
          routes: ["code", "sketch"],
          req: ["diff"],
          out: ["findings"],
          sub: ["auth-surface"],
          pub: ["findings:security", "scope-shift"],
          guard: :sticky
        ),
      "proto" =>
        stage(
          routes: ["code"],
          req: ["intent"],
          out: ["tracer"],
          sub: ["missing-infra"],
          pub: ["scope-shift"]
        ),
      "plan" =>
        stage(
          routes: ["code"],
          req: ["intent"],
          opt: ["reuse-map"],
          out: ["blueprint"],
          sub: ["plan-needed"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "codeonly" => stage(routes: ["code"], sub: ["ping"], pub: ["scope-shift"]),
      "sketchonly" => stage(routes: ["sketch"], sub: ["ping"], pub: ["scope-shift"]),
      "both" => stage(routes: ["code", "sketch"], sub: ["ping"], pub: ["scope-shift"])
    })
  end

  @doc """
  A minimal catalog with a single lockable `impl` stage (`test_route.py`'s
  `_lock_catalog`). Options: `:lock` (the lock list, default `[]`) and `:extra`
  (a map of additional stages to merge). Not required to be validator-clean.
  """
  @spec lock_catalog(keyword()) :: %{String.t() => Stage.t()}
  def lock_catalog(opts \\ []) do
    lock = Keyword.get(opts, :lock, [])
    extra = Keyword.get(opts, :extra, %{})

    base = %{
      "impl" =>
        stage(
          routes: ["code"],
          req: ["plan"],
          out: ["diff"],
          sub: ["plan-ready"],
          pub: ["code-written", "scope-shift"],
          lock: lock
        )
    }

    key_named(Map.merge(base, extra))
  end

  @doc """
  Drives `Router.compose_route/4` from list inputs. Options: `:available` and
  `:ran` (both lists, default `[]`). Live signals are the second argument.
  """
  @spec compose(%{String.t() => Stage.t()}, [String.t()], keyword()) :: Router.result()
  def compose(catalog, live, opts \\ []) do
    available = Keyword.get(opts, :available, [])
    ran = Keyword.get(opts, :ran, [])
    Router.compose_route(catalog, MapSet.new(live), MapSet.new(available), MapSet.new(ran))
  end

  @doc "Asserts `name` is in the composed route."
  @spec assert_in_route(Router.result(), String.t()) :: true
  def assert_in_route(result, name) do
    assert name in result.route, "expected #{name} in route, got #{inspect(result.route)}"
  end

  @doc """
  Asserts `name` is held and its unmet-until list contains every signal in
  `expected_untils`.
  """
  @spec assert_held(Router.result(), String.t(), [String.t()]) :: true
  def assert_held(result, name, expected_untils) do
    assert Map.has_key?(result.held, name),
           "expected #{name} held, got #{inspect(Map.keys(result.held))}"

    unmet = Map.fetch!(result.held, name)

    Enum.each(expected_untils, fn until ->
      assert until in unmet, "expected #{until} in held[#{name}]=#{inspect(unmet)}"
    end)

    true
  end

  # Stamp each stage's `name` from its catalog key.
  defp key_named(map) do
    Map.new(map, fn {name, stage} -> {name, %{stage | name: name}} end)
  end
end
