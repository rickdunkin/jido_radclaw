defmodule JidoClaw.Orchestration.Replay.Diagnostics do
  # The diagnostics struct, its `definition` sub-map, the per-gate summary, and
  # the bounded MCP wire map are explicit API shapes (the @type t contract), not
  # incidental duplication — the recurring shapes are pinned here, the error.ex
  # precedent.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  A pure, never-decrypting projection of a terminal (or in-flight) `WorkflowRun`
  for replay preflight: what is the recorded run's health, and — separately —
  can it be replayed, and if not, *why* (all reasons, not just the first).

  Built entirely from data that already exists (`WorkflowRun`, `WorkflowStep`,
  `WorkflowEvent`, `AgentCase`, plus a fresh definition re-resolution). It
  **never** executes providers and **never** decrypts the inputs blob.

  ## Two distinct axes

  A run's *recorded health* and its *replay-safety* are different questions: a
  run can be perfectly `:complete` (all steps finished, no failures) yet
  un-replayable because its skill YAML changed on disk since. So both are
  reported, separately:

    * `status` (`:complete | :waiting | :failed | :incomplete`) — the
      recorded-run-health axis. A definition change does **not** make this
      `:failed`. Precedence (first match wins):

        1. `pending_gates != []` → `:waiting`
        2. `run.status == :failed` or any `failed_steps` → `:failed`
        3. not terminal, or any `unresolved_steps` → `:incomplete`
        4. else → `:complete`

    * `blockers` + `preflight_clear?` — the replay-safety axis: the union of
      every refusal `Replay.replay/2` would raise (un-forced) **that diagnose
      can determine without decrypting**, and whether that set is empty.

  ## `preflight_clear?` is NOT a replay guarantee

  `preflight_clear?: true` asserts only that the checks diagnose *performed*
  found no blocker — it is **not** a guarantee replay will succeed, because the
  input blob's integrity is intentionally never decrypt-verified here. The
  separate `input_status` surfaces exactly that residual: a `:present_unverified`
  blob is the one gate left unchecked. A present-but-corrupt blob therefore
  diagnoses as `input_status: :present_unverified`, `preflight_clear?: true`,
  and would still fail `replay/2` with `:corrupt_inputs`. A consumer wanting
  certainty must attempt the replay. (This is why the convenience flag is named
  `preflight_clear?`, never `replayable?`.)

  ## Never decrypt

  `diagnose/2` reads only `WorkflowRun.by_id`, `WorkflowStep.for_run`,
  `WorkflowEvent.for_run`, and `AgentCase.pending_for_run`. It never calls
  `Ash.load(run, :replay_inputs)` (no vault decrypt). Input presence is read off
  the encrypted column directly (`encrypted_replay_inputs`, the `GateResume`
  precedent for `encrypted_resume_checkpoint`): `nil` → `:missing` (+ blocker
  `{:not_replayable, :no_inputs}`), present → `:present_unverified`.

  ## `definition.status`

  `:match | :changed | :unavailable | :no_hash`, computed by re-resolving the
  *current* definition exactly the way the replay gate does (fresh from disk for
  skills, BEAM md5 for modules — both via
  `JidoClaw.Orchestration.Replay.DefinitionResolver`, so the two paths can never
  drift). Precedence mirrors replay's kind-then-resolve-then-hash order: no
  `definition_kind` → `:unavailable` (detail `:no_definition_kind`) reported
  *before* the hash gate even when `definition_hash` is also nil; kind present,
  resolve fails → `:unavailable` (detail one of `:skill_unavailable |
  {:compile_failed, _} | {:disallowed_module, _} | :module_unavailable |
  {:duplicate_skill_name, _}`) — reported even on a hash-less run, since replay
  resolves before the hash gate; resolve OK + hash nil → `:no_hash`; resolve OK +
  hash present → `:match` / `:changed`. A malformed-YAML-on-disk *raise* (outside
  `Skills.load_skill/2`'s typed error set) is caught and mapped to `:unavailable`
  + a `warnings` entry rather than crashing — `Replay.replay/2` keeps its
  raise-through behavior.

  ## `unresolved_steps`

  `WorkflowStep` is a *projection* of observed `step_*` events, **not** a
  complete expected-step inventory — so `unresolved_steps` means "projected step
  rows still `:pending`/`:running` on a terminal run," never "steps absent from
  the definition" (a definition-DAG diff is out of scope).

  All operator-facing error/output snippets route through `Visibility` at
  `:operator` scope (redacted + truncated). This module emits no telemetry — it
  is a pure read, consistent with `WorkflowView`.
  """

  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Replay.DefinitionResolver
  alias JidoClaw.Orchestration.Replay.EventReader
  alias JidoClaw.Orchestration.Replay.Safety
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Tools.OutputLimit

  @statuses [:complete, :waiting, :failed, :incomplete]

  # Per-list cap for the MCP wire map; the excess count rides in `*_omitted`.
  @max_list 10

  # Byte cap on an inspect-ed blocker / definition detail (a `{:compile_failed,
  # _}` term can be arbitrarily large; `OutputLimit` caps leaves but not total
  # map size, so bounding must happen here before encode).
  @max_detail_bytes 512

  @type status :: :complete | :waiting | :failed | :incomplete

  @type definition :: %{
          kind: String.t() | nil,
          status: :match | :changed | :unavailable | :no_hash,
          stored_hash: String.t() | nil,
          current_hash: String.t() | nil,
          detail: term()
        }

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          status: status(),
          terminal?: boolean(),
          preflight_clear?: boolean(),
          input_status: :present_unverified | :missing,
          definition: definition(),
          irreversible_executed?: boolean(),
          failed_steps: [map()],
          unresolved_steps: [map()],
          pending_gates: [map()],
          blockers: [term()],
          warnings: [String.t()],
          generated_at: DateTime.t() | nil
        }

  defstruct run_id: nil,
            status: :complete,
            terminal?: false,
            preflight_clear?: false,
            input_status: :missing,
            definition: %{
              kind: nil,
              status: :no_hash,
              stored_hash: nil,
              current_hash: nil,
              detail: nil
            },
            irreversible_executed?: false,
            failed_steps: [],
            unresolved_steps: [],
            pending_gates: [],
            blockers: [],
            warnings: [],
            generated_at: nil

  @doc """
  The recorded-run-health enum (the `status` axis).
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Diagnose `run_id` for the actor's tenant. A *findable* run with blockers is
  `{:ok, struct}` — only a genuinely missing run / missing opt errors.

  Required opts: `:tenant`, `:actor`.
  """
  @spec diagnose(String.t(), keyword()) ::
          {:ok, t()} | {:error, :missing_required_opt | :not_found}
  def diagnose(run_id, opts \\ []) do
    # Tenant-scoped read inline (no `load_run` helper) — a cross-tenant id is
    # filtered by the read policy and falls through to `:not_found`, exactly
    # like `Replay`'s own gate.
    with {:ok, tenant} <- Keyword.fetch(opts, :tenant),
         {:ok, actor} <- Keyword.fetch(opts, :actor),
         {:ok, %WorkflowRun{} = run} <-
           WorkflowRun.by_id(run_id, tenant: tenant, actor: actor) do
      {:ok, build(run, tenant, actor)}
    else
      :error -> {:error, :missing_required_opt}
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  A bounded, JSON-safe map of `diagnostics` for the MCP refusal detail.

  Bounding splits across `JsonSafe.encode/1` (the legacy `Error.normalize/1`
  details clause passes the map through unsanitized, and `OutputLimit` caps
  string/list leaves but not total serialized map size). Shape, list-count, and
  detail bounds run **before** encode: the four growable lists are truncated to
  the first #{@max_list} each with a companion `*_omitted` count, blocker tuples
  normalize to `%{code, detail}` with each inspect-ed detail byte-capped, and
  `definition.detail` is byte-capped too. The final string-leaf byte-cap runs
  **after** encode — walking the encoded string-keyed shape so the list-item
  `name`/`step_type`/`step_name` fields and the warnings (none pre-capped) are
  bounded uniformly with every other string leaf.
  """
  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = diag) do
    {failed, failed_omitted} = bound_list(diag.failed_steps)
    {unresolved, unresolved_omitted} = bound_list(diag.unresolved_steps)
    {gates, gates_omitted} = bound_list(diag.pending_gates)
    {warnings, warnings_omitted} = bound_list(diag.warnings)

    wire = %{
      run_id: diag.run_id,
      status: diag.status,
      terminal?: diag.terminal?,
      preflight_clear?: diag.preflight_clear?,
      input_status: diag.input_status,
      definition: bounded_definition(diag.definition),
      irreversible_executed?: diag.irreversible_executed?,
      blockers: Enum.map(diag.blockers, &normalize_blocker/1),
      failed_steps: failed,
      failed_steps_omitted: failed_omitted,
      unresolved_steps: unresolved,
      unresolved_steps_omitted: unresolved_omitted,
      pending_gates: gates,
      pending_gates_omitted: gates_omitted,
      warnings: warnings,
      warnings_omitted: warnings_omitted,
      generated_at: diag.generated_at
    }

    wire
    |> JsonSafe.encode()
    |> cap_wire_strings()
  end

  # -- Build --

  defp build(run, tenant, actor) do
    now = DateTime.utc_now()
    terminal? = Safety.terminal_status?(run.status)

    {definition, def_blockers, def_warnings} = diagnose_definition(run)
    {input_status, input_blockers} = diagnose_input(run)
    {irreversible?, irr_blockers, irr_warnings} = diagnose_irreversible(run, tenant, actor)
    {steps, step_warnings} = load_steps(run, tenant, actor)
    {pending_gates, gate_warnings} = diagnose_gates(run, tenant, actor)

    failed_steps = failed_step_views(steps, now)
    unresolved_steps = unresolved_step_views(steps, terminal?, now)

    blockers = terminal_blockers(terminal?) ++ def_blockers ++ input_blockers ++ irr_blockers
    warnings = def_warnings ++ irr_warnings ++ step_warnings ++ gate_warnings

    %__MODULE__{
      run_id: run.id,
      status:
        compute_status(run.status, terminal?, pending_gates, failed_steps, unresolved_steps),
      terminal?: terminal?,
      preflight_clear?: blockers == [],
      input_status: input_status,
      definition: definition,
      irreversible_executed?: irreversible?,
      failed_steps: failed_steps,
      unresolved_steps: unresolved_steps,
      pending_gates: pending_gates,
      blockers: blockers,
      warnings: warnings,
      generated_at: now
    }
  end

  defp terminal_blockers(true), do: []
  defp terminal_blockers(false), do: [{:not_replayable, :run_not_terminal}]

  defp compute_status(run_status, terminal?, pending_gates, failed_steps, unresolved_steps) do
    cond do
      pending_gates != [] -> :waiting
      run_status == :failed or failed_steps != [] -> :failed
      not terminal? or unresolved_steps != [] -> :incomplete
      true -> :complete
    end
  end

  # -- Definition axis (shares DefinitionResolver with the replay gate) --

  defp diagnose_definition(run) do
    case DefinitionResolver.definition_kind(run) do
      {:error, {:not_replayable, :no_definition_kind}} ->
        unavailable(nil, run.definition_hash, :no_definition_kind)

      {:ok, kind} ->
        diagnose_kind(run, kind)
    end
  end

  # kind present → resolve fresh, then classify. Replay resolves the definition
  # BEFORE its no-hash gate, so a hash-less run whose skill/module is now
  # unavailable must surface the resolution failure, not be masked by :no_hash.
  # Never crashes.
  defp diagnose_kind(%WorkflowRun{definition_hash: stored} = run, kind) do
    kind
    |> DefinitionResolver.resolve(run)
    |> classify_resolution(kind, stored)
  rescue
    # A malformed-YAML-on-disk raise is outside Skills.load_skill/2's typed
    # error set; report :unavailable + a warning rather than crash (replay
    # itself keeps its current raise-through behavior).
    # reach:disable-next-line bare_rescue
    error ->
      {definition_map(kind, :unavailable, stored, nil, :definition_unresolved),
       [{:not_replayable, :definition_unresolved}],
       ["definition re-resolution raised: #{Exception.message(error)}"]}
  end

  # resolve OK but no stored hash to compare → :no_hash. Replay reaches its
  # no-hash gate only AFTER a successful resolve, so :no_hash applies only when
  # resolution succeeds. We have the freshly-resolved hash in hand, so surface it
  # as current_hash (no stored baseline to diff against, but useful diagnostic
  # data). MUST precede the `when current == stored` clause.
  defp classify_resolution({:ok, %{hash: current}}, kind, nil) do
    {definition_map(kind, :no_hash, nil, current, nil), [{:not_replayable, :no_hash}], []}
  end

  defp classify_resolution({:ok, %{hash: current}}, kind, stored) when current == stored do
    {definition_map(kind, :match, stored, stored, nil), [], []}
  end

  defp classify_resolution({:ok, %{hash: current}}, kind, stored) do
    {definition_map(kind, :changed, stored, current, nil),
     [{:definition_changed, stored, current}], []}
  end

  defp classify_resolution({:error, {:not_replayable, detail}}, kind, stored) do
    unavailable(kind, stored, detail)
  end

  defp unavailable(kind, stored, detail) do
    {definition_map(kind, :unavailable, stored, nil, detail), [{:not_replayable, detail}], []}
  end

  defp definition_map(kind, status, stored, current, detail) do
    %{kind: kind, status: status, stored_hash: stored, current_hash: current, detail: detail}
  end

  # -- Input axis (encrypted-column presence only — NEVER decrypt) --

  defp diagnose_input(%WorkflowRun{encrypted_replay_inputs: blob}) when is_binary(blob),
    do: {:present_unverified, []}

  defp diagnose_input(_run), do: {:missing, [{:not_replayable, :no_inputs}]}

  # -- Irreversible axis (shares Safety with the replay gate) --

  defp diagnose_irreversible(run, tenant, actor) do
    # O-M1: only the step kinds `Safety.irreversible_executed?/1` inspects
    # (single-sourced in `Safety.irreversible_kinds/0`) — the preflight no longer
    # loads the ENTIRE event log next to the byte-paginated feed. Bounded by step
    # count; no `kind` index, so the win is fewer rows folded.
    case EventReader.for_run(run.id,
           query: [filter: [kind: [in: Safety.irreversible_kinds()]]],
           tenant: tenant,
           actor: actor
         ) do
      {:ok, events} ->
        executed? = Safety.irreversible_executed?(events)
        blockers = if executed?, do: [:irreversible_steps_executed], else: []
        {executed?, blockers, []}

      {:error, reason} ->
        # Replay refuses this read failure as `{:not_replayable,
        # :irreversible_check_failed}` (replay.ex check_irreversible): an unsafe
        # replay is never permitted when the irreversible check can't run. Report
        # the SAME determinable blocker so preflight_clear? cannot be true while
        # replay would refuse. Keep the warning for the underlying read detail.
        {false, [{:not_replayable, :irreversible_check_failed}],
         ["irreversible-event read failed: #{inspect(reason)}"]}
    end
  end

  # -- Steps (the projection — see the moduledoc on unresolved_steps) --

  defp load_steps(run, tenant, actor) do
    case WorkflowStep.for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, steps} -> {steps, []}
      {:error, reason} -> {[], ["step read failed: #{inspect(reason)}"]}
    end
  end

  defp failed_step_views(steps, now) do
    steps
    |> Enum.filter(&(&1.status == :failed))
    |> Enum.map(&Visibility.step_view(&1, :operator, now))
  end

  defp unresolved_step_views(_steps, false = _terminal?, _now), do: []

  defp unresolved_step_views(steps, true = _terminal?, now) do
    steps
    |> Enum.filter(&(&1.status in [:pending, :running]))
    |> Enum.map(&Visibility.step_view(&1, :operator, now))
  end

  # -- Pending gates --

  defp diagnose_gates(run, tenant, actor) do
    case AgentCase.pending_for_run(run.id, tenant: tenant, actor: actor) do
      {:ok, cases} -> {Enum.map(cases, &gate_summary/1), []}
      {:error, reason} -> {[], ["pending-gate read failed: #{inspect(reason)}"]}
    end
  end

  defp gate_summary(%AgentCase{} = agent_case) do
    %{
      id: agent_case.id,
      step_name: agent_case.step_name,
      kind: agent_case.kind,
      status: agent_case.status
    }
  end

  # -- MCP bounding: shape/list-count/detail bounds run before JsonSafe.encode;
  # the final string-leaf byte-cap (cap_wire_strings) runs after, on the encoded
  # string-keyed shape --

  defp bound_list(list) do
    {Enum.take(list, @max_list), max(length(list) - @max_list, 0)}
  end

  defp bounded_definition(definition) do
    Map.update(definition, :detail, nil, &cap_detail/1)
  end

  defp normalize_blocker({:definition_changed, stored, current}),
    do: %{code: :definition_changed, detail: cap_detail({stored, current})}

  defp normalize_blocker({:not_replayable, detail}),
    do: %{code: :not_replayable, detail: cap_detail(detail)}

  defp normalize_blocker(code) when is_atom(code), do: %{code: code, detail: nil}

  defp normalize_blocker(other), do: %{code: :unknown, detail: cap_detail(other)}

  defp cap_detail(nil), do: nil
  defp cap_detail(detail) when is_atom(detail), do: detail
  defp cap_detail(detail) when is_binary(detail), do: byte_cap(detail)
  defp cap_detail(detail), do: byte_cap(inspect(detail))

  defp byte_cap(str) when byte_size(str) > @max_detail_bytes do
    str
    |> binary_part(0, @max_detail_bytes)
    |> OutputLimit.valid_utf8_prefix()
  end

  defp byte_cap(str), do: str

  # Byte-cap every string leaf in the final string-keyed wire shape. The
  # list-item name/step_type/step_name fields and the warnings are not pre-capped
  # (only blocker codes and definition.detail are), so this is their uniform
  # length bound. Runs AFTER JsonSafe.encode so it walks the encoded shape;
  # re-capping an already-within-@max_detail_bytes string is an idempotent no-op.
  defp cap_wire_strings(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, cap_wire_strings(value)} end)

  defp cap_wire_strings(list) when is_list(list),
    do: Enum.map(list, &cap_wire_strings/1)

  defp cap_wire_strings(value) when is_binary(value), do: byte_cap(value)

  defp cap_wire_strings(value), do: value
end
