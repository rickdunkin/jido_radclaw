defmodule JidoClaw.RouteComposer.Premises.Lint do
  @moduledoc """
  The deterministic premises lint (queue item 9) — the ouroboros `GradeGate`
  checks ported per the signed-off semantics map
  `docs/exploration/ouroboros/PORT-OB1-2.md`. Vague-term bank, observable-
  criterion patterns, and finding vocabulary are verbatim from
  Q00/ouroboros @ e905a41c (MIT, © 2025 Q00) `src/ouroboros/auto/grading.py`;
  the meaningless-criterion bank is the orca OR2-5 fold
  (`apps/desktop/src-tauri/src/briefing.rs:539-549`, MIT).

  Pure and total — no persistence, no LLM. Two modes:

    * `run(premises, mode: :clarify, ledger: items)` — the compose-time lint
      on the clarify lane. May emit **blockers** (exclusively the
      ledger-derived safety set: `high_risk_assumptions`, `ledger_open_gap`,
      `high_ambiguity_score`); the front door loops them back into a clarify
      round below the round cap. Degraded premises (`"degraded" => true` —
      the post-ack/at-cap compose) demote ALL blockers to findings: the #8
      hold-for-ack ack IS the human confirmation (map decision (B)).
    * `run(premises, mode: :gate)` — the plan-gate payload re-lint.
      **Structurally blocker-free**: blocker-class checks demote to findings.
      An invalid or missing `:mode` fails closed to gate behavior — a future
      caller can never mint clarify blockers by default.

  ALL acceptance-criteria quality checks (missing / empty / vague /
  untestable / meaningless) are findings-only in every mode (map decision 1);
  `over_fragmented_criteria` is advisory-only and never flips the grade.
  Grade: blockers ⇒ `:c`, findings ⇒ `:b`, else `:a` (source scores dropped —
  see the map).

  Entries are maps (`%{code:, message:, target:}`), never tuples — the report
  must survive a JSONB boundary via `to_details/1`.
  """

  alias JidoClaw.RouteComposer.Premises
  alias JidoClaw.Security.Redaction.Patterns

  @typedoc "One lint entry (blocker, finding, or advisory)."
  @type entry :: %{code: String.t(), message: String.t(), target: String.t()}

  @type report :: %{
          grade: :a | :b | :c,
          blockers: [entry()],
          findings: [entry()],
          advisories: [entry()]
        }

  # Q00/ouroboros @ e905a41c grading.py:23-33 — verbatim, word-boundary,
  # case-insensitive.
  @vague_terms ~w(easy intuitive robust scalable better improve optimized user-friendly seamless)

  # grading.py:34-57 — verbatim substring pre-filter.
  @observable_hints [
    "command",
    "exit",
    "prints",
    "returns",
    "creates",
    "writes",
    "file",
    "test",
    "api",
    "status",
    "displays",
    "contains",
    "includes",
    "artifact",
    "report",
    "non-zero",
    "stdout",
    "stderr",
    "exits",
    "exit code",
    "http",
    "200"
  ]

  # grading.py:485-497 — the 11 observable patterns, verbatim (input is
  # pre-downcased, as in the source).
  @observable_patterns [
    ~r/`[^`]+`\s+(prints|returns|creates|writes|exits|displays)/,
    ~r/\b(prints|returns|creates|writes|exits|displays|contains)\b.+\b(stdout|stderr|file|artifact|status|response|output|non-zero|exit code)\b/,
    ~r/\b(stdout|stderr|file|artifact|status|response|output|non-zero|exit code)\b.+\b(contains|equals|includes|is|exists|created|written)\b/,
    ~r/\b(test|check)\b.+\b(passes|fails|asserts|verifies)\b/,
    ~r/\btargeted command\b.+\bpytest\b.+\b[^\s]+\.py(?:::[^\s]+)?(?=\s).+\bpasses\b/,
    ~r/\b[\w.]+\([^)]*\)\s+returns\s+[`"'][^`"']+[`"']/,
    ~r/\b(api|endpoint|request)\b.+\b(returns|responds|status)\b/,
    ~r/\b(cli|command|process)\b.+\b(exits|returns)\b\s+(with\s+)?(exit\s+code\s+)?0\b/,
    ~r/\b(exit\s+code|status)\s+0\b/,
    ~r/\b(get|post|put|patch|delete)\b.+\b(returns|responds|status)\b\s+(with\s+)?(http\s+)?2\d\d\b/,
    ~r/\b(http\s+)?status\s+2\d\d\b/
  ]

  # orca briefing.rs:546-550 — the meaningless-spec bank over the
  # lowercase-alphanumeric normalization.
  @meaningless_bank ~w(todo tbd na none acceptancecriteria)

  # grading.py:214 / :276 boundaries.
  @ambiguity_blocker_threshold 0.20
  @over_fragmentation_threshold 9

  # `to_details/1` bounds: the payload lands in operator-visible AgentCase
  # jsonb — capped counts, clipped messages, redacted text.
  @details_max_entries 16
  @details_message_bytes 240
  # Criterion text embedded in messages (before the details clip).
  @criterion_excerpt_bytes 160

  @doc """
  Run the lint. Options:

    * `:mode` — `:clarify` (may emit blockers) or `:gate` (never); anything
      else fails closed to `:gate`.
    * `:ledger` — the clarify question ledger (`Clarify.Ledger` items);
      enables the ledger-derived checks. Clarify-lane callers pass it; the
      gate re-lint has none.
  """
  @spec run(term(), keyword()) :: report()
  def run(premises, opts \\ []) do
    mode = if Keyword.get(opts, :mode) == :clarify, do: :clarify, else: :gate
    ledger = as_ledger(Keyword.get(opts, :ledger))
    premises = if is_map(premises), do: premises, else: %{}
    degraded? = Map.get(premises, "degraded") == true

    {ac_findings, advisories} = criteria_checks(premises, ledger)
    blocker_class = blocker_class_checks(premises, ledger)

    {blockers, demoted} =
      if mode == :clarify and not degraded? do
        {blocker_class, []}
      else
        {[], blocker_class}
      end

    findings = ac_findings ++ demoted

    %{
      grade: grade(blockers, findings),
      blockers: blockers,
      findings: findings,
      advisories: advisories
    }
  end

  @doc """
  The bounded, redactor-safe, string-keyed persistence form for the plan-gate
  payload: `%{"premises_lint" => %{"grade" => …, "findings" => […],
  "advisories" => […]}}` — namespaced so the `AgentCase.details` merge can
  never collide with `summary`/`gate_title`/`gate_description`/`fields`.
  A clean report (no blockers, findings, or advisories) is `%{}` so the gate
  details stay byte-identical. Blockers fold into the findings list here:
  `to_details/1` is only ever fed gate-mode (blocker-free) reports, but a
  clarify-lane report must not lose its highest-severity entries at a
  persistence boundary either.
  """
  @spec to_details(report()) :: map()
  def to_details(%{blockers: [], findings: [], advisories: []}), do: %{}

  def to_details(%{grade: grade, blockers: blockers, findings: findings, advisories: advisories}) do
    %{
      "premises_lint" => %{
        "grade" => Atom.to_string(grade),
        "findings" => detail_entries(blockers ++ findings),
        "advisories" => detail_entries(advisories)
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Acceptance-criteria quality checks (findings-only in every mode) + advisory
  # ---------------------------------------------------------------------------

  defp criteria_checks(premises, ledger) do
    criteria = Premises.criteria(premises)

    findings =
      missing_criteria(premises, ledger, criteria) ++
        empty_criteria(premises, criteria) ++ per_criterion(criteria)

    {findings, over_fragmented(criteria)}
  end

  # grading.py:234-243, gated per the map: absence is a defect only when a
  # clarify loop ran — detected via the `:ledger` opt (the compose-time lint)
  # or the clarify fingerprint `"ambiguity_score"` (the gate re-lint, which
  # has no ledger).
  defp missing_criteria(premises, ledger, []) do
    clarify_ran? = is_list(ledger) or Map.has_key?(premises, "ambiguity_score")

    if clarify_ran? and not Map.has_key?(premises, "acceptance_criteria") do
      [
        entry(
          "missing_acceptance_criteria",
          "No acceptance criteria were established despite a clarify loop",
          "acceptance_criteria"
        )
      ]
    else
      []
    end
  end

  defp missing_criteria(_premises, _ledger, _criteria), do: []

  # orca ≥1-AC-when-key-present: the key is a claim; an empty list breaks it.
  defp empty_criteria(premises, []) do
    if Map.has_key?(premises, "acceptance_criteria") do
      [
        entry(
          "empty_acceptance_criteria",
          "Acceptance criteria list is present but empty",
          "acceptance_criteria"
        )
      ]
    else
      []
    end
  end

  defp empty_criteria(_premises, _criteria), do: []

  # Per-criterion checks are independent (grading.py:244-264): one criterion
  # can fire vague AND untestable AND meaningless.
  defp per_criterion(criteria) do
    criteria
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {criterion, index} ->
      target = "AC#{index}"
      excerpt = excerpt(criterion)

      List.flatten([
        if(vague?(criterion),
          do: [
            entry(
              "vague_acceptance_criteria",
              "Acceptance criterion is vague: #{excerpt}",
              target
            )
          ],
          else: []
        ),
        if(observable?(criterion),
          do: [],
          else: [
            entry(
              "untestable_acceptance_criteria",
              "Acceptance criterion is not clearly observable: #{excerpt}",
              target
            )
          ]
        ),
        if(meaningless?(criterion),
          do: [
            entry(
              "meaningless_acceptance_criteria",
              "Acceptance criterion is a placeholder: #{excerpt}",
              target
            )
          ],
          else: []
        )
      ])
    end)
  end

  # grading.py:275-289 — advisory only, > 9, never flips the grade.
  defp over_fragmented(criteria) do
    count = length(criteria)

    if count > @over_fragmentation_threshold do
      [
        entry(
          "over_fragmented_criteria",
          "#{count} acceptance criteria; this often means outcome-level goals " <>
            "were pre-decomposed into implementation steps",
          "acceptance_criteria"
        )
      ]
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Blocker-class checks (blockers in clarify mode, findings otherwise)
  # ---------------------------------------------------------------------------

  defp blocker_class_checks(premises, ledger) do
    high_ambiguity(premises) ++ ledger_gaps(ledger) ++ high_risk_assumptions(ledger)
  end

  # grading.py:214 — same `> 0.20` boundary as #8's `≤ 0.2` pass gate (no
  # gap). Belt-and-braces on the clarify lane: a clean pass can't carry one.
  defp high_ambiguity(premises) do
    case Map.get(premises, "ambiguity_score") do
      score when is_number(score) and score > @ambiguity_blocker_threshold ->
        [
          entry(
            "high_ambiguity_score",
            "Ambiguity score is too high to compose without another round: " <>
              :erlang.float_to_binary(score * 1.0, decimals: 2),
            "ambiguity_score"
          )
        ]

      _ok_or_absent ->
        []
    end
  end

  # grading.py:291-340 mapped onto the OR2-5 ledger: an unresolved
  # (`open`/`conflicting`) item with `user_input_required: true` is the
  # BLOCKED analogue (blocker-class); other unresolved items are findings —
  # folded here into the same demote lane so only required gaps ever block.
  defp ledger_gaps(nil), do: []

  defp ledger_gaps(ledger) do
    ledger
    |> Enum.filter(fn item ->
      item_status(item) in ["open", "conflicting"] and
        Map.get(item, "user_input_required") == true
    end)
    |> Enum.map(fn item ->
      entry(
        "ledger_open_gap",
        "A clarify question requiring user input is still unresolved: " <>
          excerpt(Map.get(item, "question")),
        "ledger"
      )
    end)
  end

  # grading.py:556-571 — the 6 risky terms over `assumed` items' assumed
  # content (`recommended_default_assumption`, question fallback when blank);
  # ONE blocker regardless of count, as in the source.
  @risky_terms ["credential", "api key", "production", "payment", "legal", "medical"]

  defp high_risk_assumptions(nil), do: []

  defp high_risk_assumptions(ledger) do
    risky? =
      ledger
      |> Enum.filter(&(item_status(&1) == "assumed"))
      |> Enum.any?(fn item ->
        text = String.downcase(assumed_content(item))
        Enum.any?(@risky_terms, &String.contains?(text, &1))
      end)

    if risky? do
      [entry("high_risk_assumptions", "Ledger contains high-risk assumptions", "assumptions")]
    else
      []
    end
  end

  defp assumed_content(item) do
    case Map.get(item, "recommended_default_assumption") do
      default when is_binary(default) and default != "" -> default
      _blank -> binary_or_empty(Map.get(item, "question"))
    end
  end

  defp item_status(%{"status" => status}) when is_binary(status), do: status
  defp item_status(_item), do: "open"

  # Only a list enables the ledger-derived checks; anything else reads as
  # "no ledger" (the gate re-lint's shape).
  defp as_ledger(ledger) when is_list(ledger), do: ledger
  defp as_ledger(_other), do: nil

  # ---------------------------------------------------------------------------
  # Scans (grading.py:474-498)
  # ---------------------------------------------------------------------------

  defp vague?(criterion) do
    lowered = String.downcase(criterion)
    Enum.any?(@vague_terms, &Regex.match?(~r/\b#{Regex.escape(&1)}\b/, lowered))
  end

  # Two-stage: the hint pre-filter alone never passes (their
  # `…_not_keywords` test); a pattern must confirm.
  defp observable?(criterion) do
    lowered = String.downcase(criterion)

    Enum.any?(@observable_hints, &String.contains?(lowered, &1)) and
      Enum.any?(@observable_patterns, &Regex.match?(&1, lowered))
  end

  # orca briefing.rs:539-549: lowercase, strip non-alphanumerics, reject the
  # bank (an empty normalization is a placeholder too — nothing verifiable).
  defp meaningless?(criterion) do
    normalized =
      criterion
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    normalized == "" or normalized in @meaningless_bank
  end

  # ---------------------------------------------------------------------------
  # Result assembly
  # ---------------------------------------------------------------------------

  defp grade(blockers, findings) do
    cond do
      blockers != [] -> :c
      findings != [] -> :b
      true -> :a
    end
  end

  defp entry(code, message, target), do: %{code: code, message: message, target: target}

  defp detail_entries(entries) do
    entries
    |> Enum.take(@details_max_entries)
    |> Enum.map(fn %{code: code, message: message, target: target} ->
      %{
        "code" => code,
        "message" => clip(Patterns.redact(message), @details_message_bytes),
        "target" => target
      }
    end)
  end

  defp excerpt(text) when is_binary(text), do: clip(text, @criterion_excerpt_bytes)
  defp excerpt(_text), do: ""

  defp binary_or_empty(value) when is_binary(value), do: value
  defp binary_or_empty(_other), do: ""

  # UTF-8-safe byte clip (the PremisesContext shape).
  defp clip(text, budget) when byte_size(text) <= budget, do: text

  defp clip(text, budget) do
    prefix = binary_part(text, 0, budget)

    if String.valid?(prefix),
      do: prefix <> "…",
      else: clip(text, budget - 1)
  end
end
