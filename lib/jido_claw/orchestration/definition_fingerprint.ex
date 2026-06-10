defmodule JidoClaw.Orchestration.DefinitionFingerprint do
  @moduledoc """
  Pure fingerprints of a workflow definition, recorded on the `WorkflowRun` at
  launch and re-checked by `JidoClaw.Orchestration.Replay`'s definition gate:
  skills are LLM-edited YAML, so a replay against a silently-changed definition
  must be refused (override: `force:`), not executed.

  Two definition kinds, two fingerprints:

    * `for_skill/1` — sha256 hex (64 chars) over a **canonical semantic term**
      built from the `%JidoClaw.Skills{}` struct. Raw YAML text is not hashed:
      `Skills.parse_skill_file/1` does not retain it, tests/tools build skill
      structs directly, and comment/whitespace edits should not invalidate
      replay. The compiled `%Reactor{}` can't be hashed either —
      `Reactor.Builder.new/1` stamps a fresh `make_ref()` id per compile.
    * `for_module/1` — the BEAM's own code digest,
      `module.module_info(:md5)` as hex (32 chars). Recompiling a changed
      module yields a new md5.

  The two kinds intentionally differ in length; the replay gate only ever
  compares a stored fingerprint to a freshly computed one of the same kind.

  ## Canonical semantic term (skills)

  The term mirrors what `JidoClaw.Skills.Compiler` actually consumes, so a
  change hashes differently iff it changes run semantics:

    * `mode` is `Skills.execution_mode/1` (`:iterative | :dag | :sequential`)
      — the compiler's construction branch, not the raw `mode` field.
    * `max_iterations` is included **only** for `:iterative` skills (inert
      elsewhere), normalized `nil → 3` (`IterativeStep`'s runtime default).
    * **Graph modes** (`:dag`/`:sequential`): steps go through
      `StepNormalizer.normalize/1` first (string-keyed ≡ atom-keyed by
      construction), then each becomes a fixed-order pair list over the
      canonical key allowlist with compiler-equivalent defaults:
      `retry` nil→`0`, `irreversible` nil→`false`,
      `depends_on`/`consumes` listified **preserving order** (order IS
      semantic: the compiler wires `upstream`/`consumes_tuples` in YAML order
      and `ContextBuilder` renders dependency/artifact prompt sections in that
      order — reordering changes the prompt the LLM sees), `produces`
      recursively stringified + key-sorted (map key order is not semantic).
    * **`:iterative`**: the raw step list is NOT hashed — the compiler runs
      only the resolved generator/evaluator (`IterativeStep.extract_roles/1`)
      as a single loop step. The term holds the two role maps (the fields
      `IterativeStep.run/3` + `ContextBuilder` consume), the generator's
      `retry` budget (it governs the whole loop), and `irreversible` OR'd
      across the roles (the loop is one execution-tracked unit). Evaluator
      `retry`, `compensate`, `depends_on`, extra roleless steps, and YAML
      step order are all runtime-inert for the loop, so fingerprint-inert.
      Roleless iterative skills never compile (hence never store a hash);
      `for_skill/1` stays total by falling back to the generic step list.
    * `description` is excluded — documentation, not semantics.

  The term is encoded with `:erlang.term_to_binary({:v1, term},
  [:deterministic])` and sha256-hashed. Caveat: deterministic external-term
  encoding is guaranteed stable within an OTP major; an OTP upgrade could in
  principle shift encodings, surfacing as mass `:definition_changed` refusals
  — recoverable via `force:`. Bump the `:v1` tag when a change could make two
  DIFFERENT definitions hash equal; a change that merely re-shapes the term
  (old hashes refuse, `force:` recovers) can keep the tag.
  """

  alias JidoClaw.Skills
  alias JidoClaw.Skills.Steps.IterativeStep
  alias JidoClaw.Workflows.StepNormalizer

  # The IterativeStep runtime default (`@default_max_iterations`), mirrored so
  # `max_iterations: nil` and an explicit `3` hash identically.
  @default_max_iterations 3

  @doc """
  Fingerprint a skill definition: sha256 hex over its canonical semantic term.
  """
  @spec for_skill(Skills.t()) :: String.t()
  def for_skill(%Skills{} = skill) do
    blob = :erlang.term_to_binary({:v1, canonical_term(skill)}, [:deterministic])
    :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
  end

  @doc """
  Fingerprint a reactor module: the BEAM code md5 as lowercase hex.
  """
  @spec for_module(module()) :: String.t()
  def for_module(module) when is_atom(module) do
    module.module_info(:md5) |> Base.encode16(case: :lower)
  end

  # -- Canonicalization --

  defp canonical_term(%Skills{} = skill) do
    mode = Skills.execution_mode(skill)

    [
      mode: mode,
      name: skill.name,
      steps: canonical_steps(skill, mode),
      synthesis: skill.synthesis
    ] ++ mode_extras(skill, mode)
  end

  # :iterative — mirror the compiler exactly: only the resolved generator and
  # evaluator run (IterativeStep.extract_roles/1), the generator's retry budget
  # governs the loop, and irreversible is OR'd onto the single loop step.
  # Compensate, evaluator retry, depends_on, extra roleless steps, and the
  # YAML ordering are all runtime-inert there, so fingerprint-inert.
  defp canonical_steps(skill, :iterative) do
    case IterativeStep.extract_roles(skill) do
      {:ok, gen, eval} ->
        [
          evaluator: canonical_role(eval),
          generator: canonical_role(gen),
          irreversible: gen.irreversible or eval.irreversible,
          retry: canonical_retry(gen.retry)
        ]

      # Roleless iterative skills never compile (Compiler.validate/3 calls
      # extract_roles), so no run ever stores this hash — but for_skill/1 is
      # pure and total, so fall back to the generic step list.
      {:error, _} ->
        generic_steps(skill)
    end
  end

  defp canonical_steps(skill, _graph_mode), do: generic_steps(skill)

  defp generic_steps(skill) do
    skill.steps
    |> StepNormalizer.normalize()
    |> Enum.map(&canonical_step/1)
  end

  # Exactly the role-map fields IterativeStep.run/3 + ContextBuilder consume —
  # no per-role retry/irreversible/compensate/depends_on (the loop-level
  # entries above carry the two the compiler threads).
  defp canonical_role(role) do
    [
      consumes: canonical_list(role.consumes),
      name: role.name,
      produces: canonical_produces(role.produces),
      role: role.role,
      task: role.task,
      template: role.template
    ]
  end

  # `max_iterations` is semantic only for `:iterative` (the loop bound,
  # nil → the runtime default); inert for graph modes, so excluded there.
  defp mode_extras(skill, :iterative),
    do: [max_iterations: skill.max_iterations || @default_max_iterations]

  defp mode_extras(_skill, _graph_mode), do: []

  # Fixed-order pair list over the canonical step-key allowlist
  # (`StepNormalizer.@canonical_keys`), with the compiler's defaults applied so
  # an omitted key and its explicit default hash identically.
  defp canonical_step(step) when is_map(step) and not is_struct(step) do
    [
      compensate: Map.get(step, :compensate),
      consumes: canonical_list(Map.get(step, :consumes)),
      depends_on: canonical_list(Map.get(step, :depends_on)),
      irreversible: Map.get(step, :irreversible) || false,
      name: Map.get(step, :name),
      produces: canonical_produces(Map.get(step, :produces)),
      retry: canonical_retry(Map.get(step, :retry)),
      role: Map.get(step, :role),
      task: Map.get(step, :task),
      template: Map.get(step, :template)
    ]
  end

  # `StepNormalizer.normalize/1` passes non-map elements through; such a step
  # can never compile, but the fingerprint is pure and must not raise.
  defp canonical_step(other), do: other

  # Mirrors the compiler's `normalize_list/1`: nil → [], list → to_string each
  # (ORDER PRESERVED — it is prompt-semantic), scalar → one-element list.
  defp canonical_list(nil), do: []
  defp canonical_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp canonical_list(value), do: [to_string(value)]

  # Mirrors the compiler's `step_retry/1` default: anything but a non-negative
  # integer hashes as 0 (no retry).
  defp canonical_retry(retry) when is_integer(retry) and retry >= 0, do: retry
  defp canonical_retry(_other), do: 0

  # Mirrors the compiler's `step_produces/1` (map or nil), then canonicalizes:
  # map key order / atom-vs-string keying are not semantic.
  defp canonical_produces(value) when is_map(value) and not is_struct(value),
    do: canonical_map(value)

  defp canonical_produces(_other), do: nil

  defp canonical_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical_value(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp canonical_value(map) when is_map(map) and not is_struct(map), do: canonical_map(map)
  defp canonical_value(list) when is_list(list), do: Enum.map(list, &canonical_value/1)
  defp canonical_value(other), do: other
end
