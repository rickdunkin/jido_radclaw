defmodule JidoClaw.GitHub.Agents.PullRequestCoordinatorTest do
  use ExUnit.Case, async: true
  # async: pure functional pipeline — no GenServer, no ETS, no global state.
  @moduletag :capture_log

  alias JidoClaw.GitHub.Agents.PullRequestCoordinator

  # A well-formed webhook event (the only fields the coordinator reads).
  defp event do
    %{issue: %{number: 42, title: "Boom"}, repo: %{full_name: "owner/repo"}}
  end

  defp triage, do: %{classification: :bug}

  describe "create_pr/3 — happy path" do
    test "should succeed on the first attempt with valid event and research" do
      research = %{code_search: %{results: [%{path: "lib/foo.ex"}]}}

      assert {:ok, result} = PullRequestCoordinator.create_pr(event(), triage(), research)
      assert result.attempts == 1
      assert result.quality.passed == true
    end
  end

  describe "create_pr/3 — retry exhaustion" do
    test "should retry to exhaustion when research yields no files" do
      # Empty research → empty patch files → :quality_failed every attempt.
      assert {:error, {:max_attempts_reached, history}} =
               PullRequestCoordinator.create_pr(event(), triage(), %{})

      # Newest-first, exactly one entry per attempt, each failing files_present.
      assert [
               %{attempt: 3, error: [:files_present]},
               %{attempt: 2, error: [:files_present]},
               %{attempt: 1, error: [:files_present]}
             ] = history
    end

    test "should retry to exhaustion when research yields no usable files" do
      no_files = [
        # pathless entry
        %{code_search: %{results: [%{}]}},
        # whitespace-only path (not a real file)
        %{code_search: %{results: [%{path: "   "}]}}
      ]

      for research <- no_files do
        assert {:error, {:max_attempts_reached, history}} =
                 PullRequestCoordinator.create_pr(event(), triage(), research),
               "expected exhaustion for #{inspect(research)}"

        assert [_, _, _] = history
      end
    end
  end

  describe "create_pr/3 — terminal abort (no retry)" do
    test "should abort immediately for malformed events" do
      malformed = [
        # empty event
        %{},
        # wrong shape: string repo (would have raised under the old dot-access)
        %{repo: "owner/repo", issue: %{number: 1}},
        # invalid value: non-positive issue number
        %{issue: %{number: 0}, repo: %{full_name: "o/r"}},
        # invalid value: blank repo full_name
        %{issue: %{number: 1}, repo: %{full_name: ""}}
      ]

      for bad_event <- malformed do
        assert {:error, {:generation_failed, :missing_issue_context}} =
                 PullRequestCoordinator.create_pr(bad_event, triage(), %{}),
               "expected terminal abort for #{inspect(bad_event)}"
      end
    end

    # The attempt log line runs *before* the `with`, building its label from the
    # raw event. The old `event.repo.full_name` interpolation raised on
    # wrong-shaped events (here, a string `repo`); the total `event_label/1`
    # makes that label safe, so create_pr returns the terminal tuple cleanly
    # instead of crashing in the logger.
    test "should not raise while logging a wrong-shaped event" do
      assert {:error, {:generation_failed, :missing_issue_context}} =
               PullRequestCoordinator.create_pr(
                 %{repo: "owner/repo", issue: %{number: 1}},
                 triage(),
                 %{}
               )
    end
  end
end
