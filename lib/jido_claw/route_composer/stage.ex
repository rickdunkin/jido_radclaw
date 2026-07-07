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
  value, and the closed `guard` / `model` / `effort` / `executor` enums.

  ## Fields

    * `:name` — the stage's string key in the catalog. The
      `JidoClaw.RouteComposer.CatalogValidator` checks it equals the map key;
      the router keys on the map, not this field.
    * `:unit` — the executable this stage is metadata over: `{:seed, name}`
      (the always-on triage seed — *not* a worker template), `{:worker_template,
      name}` (resolved via `JidoClaw.Agent.Templates`), `{:skill, name}`,
      `{:gate, name}` (a named gate reactor), or `{:verify, name}` (a named
      deterministic-verify reactor, item 5 — resolved via
      `JidoClaw.RouteComposer.VerifyReactors`; non-halting, runs solo, its
      verdict signals derive from `lens`). Bare names only — no Alp-River
      `@`/`?`/`#` sigils.
    * `:task` — the stage-specific instruction that makes two stages over the
      *same* template distinct (e.g. `security-reviewer` vs `quality-reviewer`
      over one `reviewer`). Required on a `{:worker_template, _}` stage with a
      required input (validator invariant 6); never read by the router.
    * `:lens` — the review-lens identity (e.g. `"security"`); carried for later
      phases, never a router input.
    * `:reverse_verify` — `true` marks a verifier stage whose open
      `findings:<lens>` re-fire its upstream PRODUCER (the AR-8c reverse-verify
      loop), bounded by the per-stage rerun cap; `false` (default) is a forward
      reviewer, whose open findings re-fire the FIXER on its route (the AR-4
      self-heal loop) — or, where no fixer shares the route (`sketch-review`),
      terminate `:not_converged`. A `reverse_verify: true` stage must carry a
      `lens` and exactly one required input
      (`JidoClaw.RouteComposer.CatalogValidator`). Read by the loop, never by the
      router.
    * `:guard` — `:sticky` keeps a once-triggered stage in the display route
      after its signal goes quiet (only `merge_sticky/3` reads it), or `nil`.
    * `:model` / `:effort` — per-stage tiering overrides (AR-9): read by
      `JidoClaw.RouteComposer.WaveBuilder` at wave build (carried into the
      stage step's options) and applied per LLM turn by the composed
      `JidoClaw.Reasoning.Compactor.RequestTransformer` (`model:` swaps the
      provider via `Jido.AI.resolve_model/1`; `effort:` rides the canonical
      ReqLLM `reasoning_effort` llm_opt). Never read by the router.
    * `:executor` — the per-stage executor override (item 7 PR-4, camus
      OQ-1(b)): `:in_process` or a `{:forge, kind}` term forcing WHERE this
      stage's worker runs, overriding the template's own binding. Precedence
      (both seams): test `:agent_templates_override` > `.jido/config.yaml`
      `review:` knob > this override > template binding. `nil` (the default —
      every shipped catalog stage) leaves the template binding untouched.
      Carried into the stage step's options by
      `JidoClaw.RouteComposer.WaveBuilder` (the AR-9 tier_opts shape) and
      resolved at dispatch + launch fence by
      `JidoClaw.Orchestration.ReviewIndependence`; valid only on a
      `{:worker_template, _}` stage
      (`JidoClaw.RouteComposer.CatalogValidator`). Never read by the router.
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
          | {:verify, String.t()}

  @type emit :: :default | {:mapper, String.t()}

  @type guard :: :sticky | nil

  @type model :: :fast | :capable

  @type effort :: :low | :medium | :high

  @type executor :: :in_process | {:forge, :fake | :shell | :codex | :claude_code | :custom}

  @type lock_entry :: %{while: String.t(), until: String.t()}

  @type input :: %{required: [String.t()], optional: [String.t()]}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          unit: unit() | nil,
          task: String.t() | nil,
          lens: String.t() | nil,
          reverse_verify: boolean(),
          guard: guard(),
          model: model() | nil,
          effort: effort() | nil,
          executor: executor() | nil,
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
    :executor,
    reverse_verify: false,
    emit: :default,
    routes: [],
    input: %{required: [], optional: []},
    output: [],
    subscribes: [],
    publishes: [],
    lock: []
  ]

  # ---------------------------------------------------------------------------
  # JSONB (de)serialization (AR-2 Phase 2d — durable catalog in the parent config)
  # ---------------------------------------------------------------------------
  #
  # `to_map/1` / `from_map/1` round-trip a `%Stage{}` through a JSON-safe map so
  # the composer's launch catalog survives a full node reboot in
  # `WorkflowRun.config["catalog"]`. Only the **closed enums** are stringified
  # (the `unit` tag, `emit`, `guard`/`model`/`effort`/`executor`, and the
  # structural `input`/`lock` keys); every free string/list (`name`, `task`,
  # `lens`, `routes`, `output`, `subscribes`, `publishes`, lock `while`/`until`
  # *values*) passes through verbatim, preserving the atom-safety invariant
  # above.
  #
  # `from_map/1` is **total + nil-on-failure**: it rebuilds via `struct/2` (so
  # struct defaults fill absent keys) and coerces every closed enum back through
  # a **hardcoded whitelist** — NEVER `String.to_atom`/`String.to_existing_atom`
  # on free input (mirrors `ComposerArtifact.Envelope`'s `[:safe]` rationale). An
  # unknown closed tag fails the whole decode (returns `nil`, never a created
  # atom, a kept string, or a partial struct). This guarantees **atom-safety
  # only**: a structurally-degenerate-but-atom-safe map (e.g. `%{}`) still decodes
  # to a default `%Stage{}`, so STRUCTURAL coherence is
  # `JidoClaw.RouteComposer.CatalogValidator`'s job — gated at launch/recovery by
  # `RouteComposer.decode_config_catalog/1`, not by `from_map`.

  @unit_tags %{
    "seed" => :seed,
    "worker_template" => :worker_template,
    "skill" => :skill,
    "gate" => :gate,
    "verify" => :verify
  }
  @guards %{"sticky" => :sticky}
  @models %{"fast" => :fast, "capable" => :capable}
  @efforts %{"low" => :low, "medium" => :medium, "high" => :high}

  # The closed executor-override decode map (PR-4). `"forge:<kind>"` strings
  # keep the wire form flat; an unknown string fails the whole stage decode
  # (the `enum_from/2` contract — never `String.to_atom`).
  @executors %{
    "in_process" => :in_process,
    "forge:fake" => {:forge, :fake},
    "forge:shell" => {:forge, :shell},
    "forge:codex" => {:forge, :codex},
    "forge:claude_code" => {:forge, :claude_code},
    "forge:custom" => {:forge, :custom}
  }

  @doc """
  Serialize a `%Stage{}` to a JSON-safe, string-keyed map (closed enums
  stringified; free strings/lists verbatim). The inverse of `from_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = stage) do
    %{
      "name" => stage.name,
      "unit" => unit_to_map(stage.unit),
      "task" => stage.task,
      "lens" => stage.lens,
      # A plain JSON-safe boolean (default false); no enum coercion needed.
      "reverse_verify" => stage.reverse_verify,
      "guard" => atom_to_string(stage.guard),
      "model" => atom_to_string(stage.model),
      "effort" => atom_to_string(stage.effort),
      "executor" => executor_to_map(stage.executor),
      "emit" => emit_to_map(stage.emit),
      "routes" => stage.routes,
      "input" => input_to_map(stage.input),
      "output" => stage.output,
      "subscribes" => stage.subscribes,
      "publishes" => stage.publishes,
      "lock" => Enum.map(stage.lock, &lock_to_map/1)
    }
  end

  @doc """
  Rebuild a `%Stage{}` from a `to_map/1` (or JSONB-reloaded) map. Total +
  nil-on-failure: an unknown closed enum value, or any non-map input, returns
  `nil` (never a partial struct, a created atom, or a kept string).
  """
  @spec from_map(map() | nil) :: t() | nil
  def from_map(map) when is_map(map) do
    with {:ok, unit} <- unit_from_map(Map.get(map, "unit")),
         {:ok, emit} <- emit_from_map(Map.get(map, "emit")),
         {:ok, guard} <- enum_from(Map.get(map, "guard"), @guards),
         {:ok, model} <- enum_from(Map.get(map, "model"), @models),
         {:ok, effort} <- enum_from(Map.get(map, "effort"), @efforts),
         {:ok, executor} <- enum_from(Map.get(map, "executor"), @executors),
         {:ok, input} <- input_from_map(Map.get(map, "input")),
         {:ok, lock} <- lock_from_map(Map.get(map, "lock")) do
      struct(__MODULE__, %{
        name: Map.get(map, "name"),
        unit: unit,
        task: Map.get(map, "task"),
        lens: Map.get(map, "lens"),
        # Atom-safe boolean coercion: only a literal `true` decodes to `true`
        # (absent / `false` / any other value → the struct default `false`).
        reverse_verify: Map.get(map, "reverse_verify") == true,
        guard: guard,
        model: model,
        effort: effort,
        executor: executor,
        emit: emit,
        routes: string_list(Map.get(map, "routes")),
        input: input,
        output: string_list(Map.get(map, "output")),
        subscribes: string_list(Map.get(map, "subscribes")),
        publishes: string_list(Map.get(map, "publishes")),
        lock: lock
      })
    else
      _ -> nil
    end
  end

  def from_map(_other), do: nil

  defp unit_to_map(nil), do: nil

  defp unit_to_map({tag, name}) when is_atom(tag),
    do: %{"tag" => Atom.to_string(tag), "name" => name}

  defp unit_from_map(nil), do: {:ok, nil}

  defp unit_from_map(%{"tag" => tag, "name" => name}) when is_binary(tag) do
    case Map.fetch(@unit_tags, tag) do
      {:ok, atom_tag} -> {:ok, {atom_tag, name}}
      :error -> :error
    end
  end

  defp unit_from_map(_other), do: :error

  defp executor_to_map(nil), do: nil
  defp executor_to_map(:in_process), do: "in_process"
  defp executor_to_map({:forge, kind}) when is_atom(kind), do: "forge:#{Atom.to_string(kind)}"

  defp emit_to_map(:default), do: "default"
  defp emit_to_map({:mapper, name}), do: %{"mapper" => name}

  # Absent ⇒ the struct default `:default`; the tagged mapper or the literal
  # `"default"` decode back; anything else is an unknown closed value.
  defp emit_from_map(nil), do: {:ok, :default}
  defp emit_from_map("default"), do: {:ok, :default}
  defp emit_from_map(%{"mapper" => name}), do: {:ok, {:mapper, name}}
  defp emit_from_map(_other), do: :error

  defp input_to_map(%{required: req, optional: opt}),
    do: %{"required" => req, "optional" => opt}

  defp input_from_map(nil), do: {:ok, %{required: [], optional: []}}

  defp input_from_map(%{} = map),
    do:
      {:ok,
       %{
         required: string_list(Map.get(map, "required")),
         optional: string_list(Map.get(map, "optional"))
       }}

  defp input_from_map(_other), do: :error

  defp lock_to_map(%{while: w, until: u}), do: %{"while" => w, "until" => u}

  defp lock_from_map(nil), do: {:ok, []}

  defp lock_from_map(list) when is_list(list) do
    reduced =
      Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
        case entry do
          %{"while" => w, "until" => u} -> {:cont, {:ok, [%{while: w, until: u} | acc]}}
          _ -> {:halt, :error}
        end
      end)

    case reduced do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp lock_from_map(_other), do: :error

  # nil (absent) keeps the struct default; a whitelisted string maps to its atom
  # (`Map.fetch/2` already yields `{:ok, atom}` | `:error`, the contract here);
  # any other value is an unknown closed enum and fails the decode.
  defp enum_from(nil, _allowed), do: {:ok, nil}
  defp enum_from(value, allowed) when is_binary(value), do: Map.fetch(allowed, value)
  defp enum_from(_value, _allowed), do: :error

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp string_list(list) when is_list(list), do: list
  defp string_list(_other), do: []
end
