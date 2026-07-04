defmodule JidoClaw.Orchestration.Verdict.IterativeEval do
  # Ported from mateodaza/camus @ 53da91b3, MIT (the infra-vs-verdict exit
  # vocabulary); the map/text parsing subsumes the retired
  # `JidoClaw.Skills.Steps.IterativeStep.parse_verdict/1`.
  @moduledoc """
  Normalizes an iterative-skill evaluator's output into the three-exit
  `Verdict` contract: a typed map (`%{verdict: :pass | :fail}`, atom- or
  string-keyed — the shape `JidoClaw.Agent.Workers.Verifier` emits via Jido.AI
  structured output) or the legacy free-form text carrying `VERDICT: PASS` /
  `VERDICT: FAIL` (last-token-wins).

  The old `parse_verdict/1` mapped every garbled/missing verdict to `:fail`,
  consuming a loop iteration exactly like a real fail — camus's "#1 cause of
  runaway loops". Here those inputs fail closed to `{:infra, _}` instead:
  `nil`/empty → `:empty_output`, text without a token → `:no_verdict_token`,
  a map without / with an out-of-enum verdict (and any other shape) →
  `{:invalid_verdict, raw}`.
  """

  alias JidoClaw.Orchestration.Verdict

  @behaviour Verdict

  @verdicts %{"pass" => :pass, "fail" => :fail}

  @impl Verdict
  @spec normalize(term()) :: Verdict.result()
  def normalize(raw) do
    cond do
      Verdict.blank?(raw) -> {:infra, :empty_output}
      is_map(raw) -> normalize_map(raw)
      is_binary(raw) -> normalize_text(raw)
      true -> {:infra, {:invalid_verdict, raw}}
    end
  end

  defp normalize_map(map) do
    raw = Verdict.field(map, :verdict)

    case Verdict.decode_enum(raw, @verdicts) do
      {:ok, decision} -> {:verdict, verdict(decision, map)}
      :error -> {:infra, {:invalid_verdict, raw}}
    end
  end

  defp normalize_text(text) do
    # Find the LAST VERDICT: token — earlier mentions may be instructions like
    # "To get VERDICT: PASS, fix X" followed by "VERDICT: FAIL".
    case Regex.scan(~r/VERDICT:\s*(PASS|FAIL)/i, text) do
      [] ->
        {:infra, :no_verdict_token}

      matches ->
        # "Last VERDICT wins" is intentional (see comment above); Regex.scan
        # results are bounded by the small number of verdict tokens an LLM emits.
        # credo:disable-for-next-line ExSlop.Check.Refactor.ListLast
        token = List.last(List.last(matches))
        decision = if String.upcase(token) == "PASS", do: :pass, else: :fail
        {:verdict, verdict(decision, %{})}
    end
  end

  defp verdict(decision, source) do
    %Verdict{clean?: decision == :pass, decision: decision, findings: [], source: source}
  end
end
