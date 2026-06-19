defmodule JidoClaw.RouteComposer.CatalogValidator do
  @moduledoc """
  Coherence + structural check over a route catalog — the second gate beside
  the router tests.

  A port of Alp River `check_catalog.py` plus three jido_radclaw additions: the
  AR-2 cycle check (§3.2 step 5), a self-dependency invariant (review follow-up
  #2 — cycle detection alone cannot catch a stage that requires its own output,
  since the toposort discards the self-predecessor edge), and a group of
  structural well-formedness checks (review follow-up #4) that replace the
  compile-time normalization the skipped `gen-catalog` step used to provide.

  `validate/1` returns a list of human-readable problem strings (`[]` = clean),
  sorted. It runs **structural checks first and short-circuits**: a malformed
  `input` / `lock` / `unit` shape would otherwise crash the coherence and cycle
  checks themselves, so when group 0 finds any problem the semantic groups and
  the cycle check are skipped.

  Group 0 also shape-checks the typed scalar fields — `task` / `lens` as
  nilable strings, `guard` / `model` / `effort` as their closed enums, and
  `emit` as `:default | {:mapper, string}` — and rejects a non-`%Stage{}`
  value or a non-string catalog key up front, so a clean result implies every
  entry is a binary-keyed, well-formed `%Stage{}`.

  Existence of the template / skill / gate a `unit` names is **not** resolved
  here — that is execution-time (Phase 1+). Group 0 validates shape only; the
  `JidoClaw.RouteComposer.Catalog` compile-time guard checks worker-template
  existence separately.

  ## Invariants (groups 1–8 + cycle = 9)

    1. `routes` present, non-empty, and ⊆ `["talk", "sketch", "code",
       "system"]`.
    2. `scope-shift` ∈ `publishes` (every stage self-reports premise breaks).
    3. every `subscribes` topic is a seed signal or family-published.
    4. every **required** input is a seed artifact or in the union of outputs.
    5. a `{:worker_template, _}` stage with a required input, not in
       `@template_exempt`, carries a non-empty `task` (`{:seed, _}` /
       `{:skill, _}` / `{:gate, _}` units carry their own steps → exempt).
    6. every `lock` `while` / `until` is a seed signal or family-published.
    7. no self-dependency — a stage's required inputs are disjoint from its
       outputs.
    8. an `emit: :default` + `lens` stage declares **both** `clean:<lens>` and
       `findings:<lens>` in `publishes` (the `:default` mapper derives both
       verdict families, so a missing declaration would fail the strict
       ⊆-publishes emit check mid-wave — caught here at load instead, AR-2 §7).
    9. the producer → consumer data graph is acyclic.

  `family_match?/2` is **bidirectional** (an exact topic, a qualified member of
  the family, **or** the family base) and is deliberately distinct from the
  router's one-directional `matches?/2` — the two are not the same matcher.
  """

  alias JidoClaw.RouteComposer.Graph
  alias JidoClaw.RouteComposer.Stage

  @paths ~w(talk sketch code system)
  @seed_signals ~w(request-received)
  @seed_artifacts ~w(request)
  @template_exempt ~w(triage)
  @unit_tags [:seed, :worker_template, :skill, :gate]

  @doc """
  Validates a catalog (`%{name => %Stage{}}`), returning a sorted list of
  problem strings (`[]` = clean).

  Structural problems short-circuit: when any are found the coherence and cycle
  checks are skipped (they assume a well-formed shape).
  """
  @spec validate(%{optional(String.t()) => Stage.t()}) :: [String.t()]
  def validate(catalog) do
    problems =
      case structural(catalog) do
        [] -> coherence(catalog) ++ cycle(catalog)
        structural_problems -> structural_problems
      end

    Enum.sort(problems)
  end

  @doc """
  Bidirectional family match: satisfied by an exact topic, a qualified member
  of the family (`findings` ← `findings:security`), or the family base
  (`findings:x` ← `findings`).

  Deliberately distinct from `JidoClaw.RouteComposer.Router`'s one-directional
  `matches?/2`; do not collapse the two.
  """
  @spec family_match?(String.t(), Enumerable.t()) :: boolean()
  def family_match?(sub, published) do
    Enum.any?(published, fn pub ->
      pub == sub or String.starts_with?(pub, sub <> ":") or String.starts_with?(sub, pub <> ":")
    end)
  end

  # ---------------------------------------------------------------------------
  # Group 0 — structural well-formedness
  # ---------------------------------------------------------------------------

  defp structural(catalog) do
    catalog
    |> sorted_stages()
    |> Enum.flat_map(fn {name, stage} -> structural_for(name, stage) end)
  end

  defp structural_for(name, %Stage{} = stage) when is_binary(name) do
    List.flatten([
      check_name(name, stage),
      check_string_list(name, "routes", stage.routes),
      check_string_list(name, "output", stage.output),
      check_string_list(name, "subscribes", stage.subscribes),
      check_string_list(name, "publishes", stage.publishes),
      check_input_shape(name, stage.input),
      check_lock_shape(name, stage.lock),
      check_unit_shape(name, stage.unit),
      check_optional_string(name, "task", stage.task),
      check_optional_string(name, "lens", stage.lens),
      check_enum(name, "guard", stage.guard, [:sticky, nil]),
      check_enum(name, "model", stage.model, [:fast, :capable, nil]),
      check_enum(name, "effort", stage.effort, [:low, :medium, :high, nil]),
      check_emit(name, stage.emit)
    ])
  end

  defp structural_for(name, %Stage{}),
    do: ["#{inspect(name)}: catalog key must be a string"]

  defp structural_for(name, _other),
    do: ["#{inspect(name)}: catalog entry must be a %JidoClaw.RouteComposer.Stage{}"]

  defp check_name(name, %Stage{name: name}), do: []

  defp check_name(name, %Stage{name: other}),
    do: ["#{name}: stage name #{inspect(other)} does not match catalog key #{inspect(name)}"]

  defp check_string_list(name, field, value) do
    cond do
      not is_list(value) -> ["#{name}: `#{field}` must be a list of strings"]
      not Enum.all?(value, &is_binary/1) -> ["#{name}: `#{field}` must contain only strings"]
      true -> []
    end
  end

  defp check_optional_string(_name, _field, value) when is_nil(value) or is_binary(value), do: []

  defp check_optional_string(name, field, _value),
    do: ["#{name}: `#{field}` must be a string or nil"]

  defp check_input_shape(name, %{required: req, optional: opt})
       when is_list(req) and is_list(opt) do
    if Enum.all?(req, &is_binary/1) and Enum.all?(opt, &is_binary/1) do
      []
    else
      ["#{name}: `input` required/optional must be lists of strings"]
    end
  end

  defp check_input_shape(name, _other),
    do: ["#{name}: `input` must be %{required: [string], optional: [string]}"]

  defp check_emit(_name, :default), do: []
  defp check_emit(_name, {:mapper, mapper}) when is_binary(mapper), do: []

  defp check_emit(name, emit),
    do: ["#{name}: `emit` must be :default or {:mapper, string}, got #{inspect(emit)}"]

  defp check_lock_shape(name, locks) when is_list(locks),
    do: Enum.flat_map(locks, fn entry -> check_lock_entry(name, entry) end)

  defp check_lock_shape(name, _other), do: ["#{name}: `lock` must be a list"]

  defp check_lock_entry(_name, %{while: w, until: u}) when is_binary(w) and is_binary(u), do: []

  defp check_lock_entry(name, _entry),
    do: ["#{name}: each `lock` entry must be %{while: string, until: string}"]

  defp check_enum(name, field, value, allowed) do
    if value in allowed do
      []
    else
      ["#{name}: `#{field}` must be one of #{inspect(allowed)}"]
    end
  end

  defp check_unit_shape(_name, {tag, value}) when tag in @unit_tags and is_binary(value), do: []

  defp check_unit_shape(name, unit),
    do: [
      "#{name}: `unit` must be {:seed | :worker_template | :skill | :gate, string}, got #{inspect(unit)}"
    ]

  # ---------------------------------------------------------------------------
  # Groups 1–8 — coherence
  # ---------------------------------------------------------------------------

  defp coherence(catalog) do
    published = union_field(catalog, fn stage -> stage.publishes end)
    produced = union_field(catalog, fn stage -> stage.output end)

    catalog
    |> sorted_stages()
    |> Enum.flat_map(fn {name, stage} -> coherence_for(name, stage, published, produced) end)
  end

  defp coherence_for(name, stage, published, produced) do
    List.flatten([
      check_routes(name, stage),
      check_scope_shift(name, stage),
      check_subscribes(name, stage, published),
      check_required(name, stage, produced),
      check_task(name, stage),
      check_locks(name, stage, published),
      check_self_dep(name, stage),
      check_verdict_publishes(name, stage)
    ])
  end

  defp check_routes(name, %Stage{routes: routes}) do
    cond do
      routes == [] ->
        ["#{name}: missing `routes`"]

      not subset_of_paths?(routes) ->
        ["#{name}: routes #{inspect(routes)} not a subset of #{inspect(@paths)}"]

      true ->
        []
    end
  end

  defp subset_of_paths?(routes) do
    Enum.all?(routes, fn route -> route in @paths end)
  end

  defp check_scope_shift(name, %Stage{publishes: pubs}) do
    if "scope-shift" in pubs, do: [], else: ["#{name}: does not publish `scope-shift`"]
  end

  defp check_subscribes(name, %Stage{subscribes: subs}, published) do
    for sub <- subs, not (seed_signal?(sub) or family_match?(sub, published)) do
      "#{name}: subscribes `#{sub}` — no publisher or seed"
    end
  end

  defp check_required(name, %Stage{input: %{required: req}}, produced) do
    for art <- req, not (seed_artifact?(art) or MapSet.member?(produced, art)) do
      "#{name}: requires `#{art}` — no producer or seed"
    end
  end

  defp check_task(name, stage) do
    if required_task_missing?(name, stage) do
      ["#{name}: has required input but empty `task`"]
    else
      []
    end
  end

  defp required_task_missing?(name, %Stage{
         unit: {:worker_template, _},
         input: %{required: req},
         task: task
       }),
       do: req != [] and name not in @template_exempt and blank?(task)

  defp required_task_missing?(_name, _stage), do: false

  defp check_locks(name, %Stage{lock: locks}, published),
    do: Enum.flat_map(locks, fn lock -> lock_signal_problems(name, lock, published) end)

  defp lock_signal_problems(name, %{while: w, until: u}, published) do
    for sig <- [w, u], not (seed_signal?(sig) or family_match?(sig, published)) do
      "#{name}: lock signal `#{sig}` has no publisher or seed"
    end
  end

  defp check_self_dep(name, %Stage{input: %{required: req}, output: out}) do
    if MapSet.disjoint?(MapSet.new(req), MapSet.new(out)) do
      []
    else
      ["#{name}: required input intersects output (self-dependency)"]
    end
  end

  # A `emit: :default` + `lens` stage derives BOTH verdict families
  # (`clean:<lens>` / `findings:<lens>`), so both must be declared `publishes`
  # topics — otherwise the strict ⊆-publishes emit check would fail for one
  # verdict mid-wave. Catch the authoring error at load (AR-2 Decisions).
  defp check_verdict_publishes(name, %Stage{emit: :default, lens: lens, publishes: pubs})
       when is_binary(lens) do
    for topic <- ["clean:#{lens}", "findings:#{lens}"], topic not in pubs do
      "#{name}: emit :default + lens #{inspect(lens)} must declare `#{topic}` in publishes"
    end
  end

  defp check_verdict_publishes(_name, _stage), do: []

  # ---------------------------------------------------------------------------
  # Cycle — the producer → consumer data graph must be acyclic
  # ---------------------------------------------------------------------------

  defp cycle(catalog) do
    case Graph.kahn(catalog, Map.keys(catalog)) do
      {:ok, _order, _waves} ->
        []

      {:error, undrained} ->
        ["catalog: precedence graph has a cycle (undrained: #{inspect(undrained)})"]
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp sorted_stages(catalog) do
    catalog
    |> Map.to_list()
    |> Enum.sort_by(fn {name, _stage} -> name end)
  end

  defp union_field(catalog, fun) do
    Enum.reduce(catalog, MapSet.new(), fn {_name, stage}, acc ->
      MapSet.union(acc, MapSet.new(fun.(stage)))
    end)
  end

  defp seed_signal?(sig), do: sig in @seed_signals

  defp seed_artifact?(art), do: art in @seed_artifacts

  defp blank?(task) when is_binary(task), do: String.trim(task) == ""
  defp blank?(_task), do: true
end
