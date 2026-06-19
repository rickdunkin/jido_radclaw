defmodule JidoClaw.RouteComposer.Stage do
  @moduledoc """
  A composable unit of a route — metadata over an existing executable unit
  (a worker template, a skill, or a gate), not a new executor.

  Every stage carries two independent graphs over one catalog (AR-2 §2):

    * the **data graph** (`input` / `output` artifacts) — the precedence DAG a
      producer is ordered before its consumer on; `input.required` is **AND**
      (a missing required input drops the stage),
    * the **signal graph** (`subscribes` / `publishes` topics) — pub/sub
      membership; `subscribes` is **OR** (any live subscribed signal triggers
      the stage), and `publishes` is **never read by the router**.

  Atop both sits a third gate — `lock` (a scheduling hold, never an executor).

  Strings stay strings (atom-safety): stage names, route paths, signal topics,
  and artifact names are all binaries, never `String.to_atom/1`-ed from
  catalog-or-YAML-sourced values. The only atoms are the `unit` tag, the `emit`
  value, and the closed `guard` / `model` / `effort` enums.

  ## Fields

    * `:name` — the stage's string key in the catalog. The
      `JidoClaw.RouteComposer.CatalogValidator` checks it equals the map key;
      the router keys on the map, not this field.
    * `:unit` — the executable this stage is metadata over: `{:seed, name}`
      (the always-on triage seed — *not* a worker template), `{:worker_template,
      name}` (resolved via `JidoClaw.Agent.Templates`), `{:skill, name}`, or
      `{:gate, name}` (a named gate reactor). Bare names only — no Alp-River
      `@`/`?`/`#` sigils.
    * `:task` — the stage-specific instruction that makes two stages over the
      *same* template distinct (e.g. `security-reviewer` vs `quality-reviewer`
      over one `reviewer`). Required on a `{:worker_template, _}` stage with a
      required input (validator invariant 6); never read by the router.
    * `:lens` — the review-lens identity (e.g. `"security"`); carried for later
      phases, never a router input.
    * `:guard` — `:sticky` keeps a once-triggered stage in the display route
      after its signal goes quiet (only `merge_sticky/3` reads it), or `nil`.
    * `:model` / `:effort` — spawn-time tiering overrides for later phases
      (§12); never read by the router.
    * `:emit` — `:default` (map `output` + the worker verdict to artifacts +
      signals) or `{:mapper, name}` (a registered mapper); carried for §7.
    * `:routes` — the validated subset of `["talk", "sketch", "code",
      "system"]` this stage runs on; mandatory and non-empty.
    * `:input` — `%{required: [name], optional: [name]}`. Required inputs are
      AND-gated; optional inputs order-but-never-drop.
    * `:output` — artifact names this stage produces.
    * `:subscribes` — signal topics that trigger this stage (OR-membership,
      family-prefix aware).
    * `:publishes` — signal topics this stage emits; the emission contract (§7),
      never read by `compose_route/4`.
    * `:lock` — `[%{while: signal, until: signal}]`; a router hold (active while
      `while` is live and `until` is not), never an executor.
  """

  @type unit ::
          {:seed, String.t()}
          | {:worker_template, String.t()}
          | {:skill, String.t()}
          | {:gate, String.t()}

  @type emit :: :default | {:mapper, String.t()}

  @type guard :: :sticky | nil

  @type model :: :fast | :capable

  @type effort :: :low | :medium | :high

  @type lock_entry :: %{while: String.t(), until: String.t()}

  @type input :: %{required: [String.t()], optional: [String.t()]}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          unit: unit() | nil,
          task: String.t() | nil,
          lens: String.t() | nil,
          guard: guard(),
          model: model() | nil,
          effort: effort() | nil,
          emit: emit(),
          routes: [String.t()],
          input: input(),
          output: [String.t()],
          subscribes: [String.t()],
          publishes: [String.t()],
          lock: [lock_entry()]
        }

  defstruct [
    :name,
    :unit,
    :task,
    :lens,
    :guard,
    :model,
    :effort,
    emit: :default,
    routes: [],
    input: %{required: [], optional: []},
    output: [],
    subscribes: [],
    publishes: [],
    lock: []
  ]
end
