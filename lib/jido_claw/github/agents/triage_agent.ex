defmodule JidoClaw.GitHub.Agents.TriageAgent do
  @bug_keywords ~w(bug error crash fail broken exception timeout 500 nil undefined)
  @feature_keywords ~w(feature request add implement support enhance improve)
  @doc_keywords ~w(docs documentation typo readme guide example)

  def classify(issue) do
    text = String.downcase("#{issue.title} #{issue.body}")
    labels = Enum.map(issue.labels || [], &String.downcase/1)

    {classification, confidence} =
      cond do
        "bug" in labels -> {"bug", 0.95}
        "enhancement" in labels or "feature" in labels -> {"feature", 0.90}
        "documentation" in labels -> {"documentation", 0.90}
        matches?(text, @bug_keywords) -> {"bug", 0.70}
        matches?(text, @feature_keywords) -> {"feature", 0.65}
        matches?(text, @doc_keywords) -> {"documentation", 0.60}
        true -> {"question", 0.50}
      end

    {:ok, %{classification: classification, confidence: confidence, issue_number: issue.number}}
  end

  defp matches?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end
end
