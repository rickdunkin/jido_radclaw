defmodule JidoClaw.GitHub.Agents.ResearchCoordinatorTest do
  use ExUnit.Case, async: true

  alias JidoClaw.GitHub.Agents.ResearchCoordinator

  @moduletag capture_log: true

  @event %{
    repo: %{full_name: "acme/widgets"},
    issue: %{title: "Crash on boot", number: 42}
  }
  @triage %{classification: :bug}

  test "aggregates all four research lanes on success" do
    assert {:ok, research} = ResearchCoordinator.research(@event, @triage)

    assert %{
             code_search: %{repo: "acme/widgets", query: "Crash on boot"},
             reproduction: %{issue: 42},
             root_cause: %{classification: :bug, issue: 42},
             related_prs: %{repo: "acme/widgets"}
           } = research
  end

  # Regression: a crashing sub-task must surface as `{:error, :research_failed}`,
  # not abort the caller. The old linked `Task.async` + `rescue` shape let the
  # task's EXIT propagate through the link and kill the caller — a link EXIT is
  # a signal, not an exception, so the `rescue` never ran.
  test "a crashing sub-task surfaces as {:error, :research_failed}, caller survives" do
    assert {:error, :research_failed} = ResearchCoordinator.research(%{}, @triage)
  end
end
