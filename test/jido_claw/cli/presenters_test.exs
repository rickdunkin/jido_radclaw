defmodule JidoClaw.CLI.PresentersTest do
  # Presenters are pure functions — no process touches, so async is safe.
  use ExUnit.Case, async: true

  alias JidoClaw.CLI.Presenters
  alias JidoClaw.Solutions.Solution

  describe "status_lines/1" do
    test "renders core header lines with running/spawned counts and uptime" do
      snapshot = %{
        tracker: %{
          agents: %{
            "main" => %{status: :running},
            "child-1" => %{status: :running},
            "child-2" => %{status: :done}
          },
          order: ["main", "child-1", "child-2"]
        },
        sessions: {:ok, []},
        stats: %{agents_spawned: 2, uptime_seconds: 65}
      }

      lines = Presenters.status_lines(snapshot)

      assert "JidoClaw Status" in lines
      assert Enum.any?(lines, &String.contains?(&1, "1 running / 2 spawned"))
      assert Enum.any?(lines, &String.contains?(&1, "1m 5s"))
    end

    test "renders per-session breakdown when sessions is an ok list" do
      snapshot = %{
        tracker: %{agents: %{"main" => %{status: :running}}, order: ["main"]},
        sessions:
          {:ok,
           [
             %{name: "forge-one", phase: :running},
             %{name: "forge-two", phase: :ready}
           ]},
        stats: %{agents_spawned: 0, uptime_seconds: 0}
      }

      lines = Presenters.status_lines(snapshot)

      assert Enum.any?(lines, &String.contains?(&1, "2 active session(s)"))
      assert Enum.any?(lines, &String.contains?(&1, "forge-one (running)"))
      assert Enum.any?(lines, &String.contains?(&1, "forge-two (ready)"))
    end

    test "gracefully degrades when sessions fetch returned an error" do
      snapshot = %{
        tracker: %{agents: %{}, order: []},
        sessions: {:error, "db down"},
        stats: %{agents_spawned: 0, uptime_seconds: 10}
      }

      lines = Presenters.status_lines(snapshot)

      assert Enum.any?(lines, &String.contains?(&1, "sessions unavailable: db down"))

      refute Enum.any?(lines, fn line ->
               String.contains?(line, "forge") and String.contains?(line, "active session")
             end)
    end

    test "renders 'profile     default' header line when :profile is omitted" do
      snapshot = %{
        tracker: %{agents: %{"main" => %{status: :running}}, order: ["main"]},
        sessions: {:ok, []},
        stats: %{agents_spawned: 0, uptime_seconds: 0}
      }

      lines = Presenters.status_lines(snapshot)

      assert "  profile     default" in lines
    end

    test "renders the provided :profile in the header" do
      snapshot = %{
        tracker: %{agents: %{"main" => %{status: :running}}, order: ["main"]},
        sessions: {:ok, []},
        stats: %{agents_spawned: 0, uptime_seconds: 0},
        profile: "staging"
      }

      lines = Presenters.status_lines(snapshot)

      assert "  profile     staging" in lines
    end

    test "renders the provided :ssh_sessions count line" do
      snapshot = %{
        tracker: %{agents: %{"main" => %{status: :running}}, order: ["main"]},
        sessions: {:ok, []},
        stats: %{agents_spawned: 0, uptime_seconds: 0},
        ssh_sessions: 3
      }

      lines = Presenters.status_lines(snapshot)

      assert "  ssh         3 active session(s)" in lines
    end

    test "defaults :ssh_sessions to 0 when key is omitted (back-compat)" do
      snapshot = %{
        tracker: %{agents: %{"main" => %{status: :running}}, order: ["main"]},
        sessions: {:ok, []},
        stats: %{agents_spawned: 0, uptime_seconds: 0}
      }

      lines = Presenters.status_lines(snapshot)

      assert "  ssh         0 active session(s)" in lines
    end
  end

  describe "memory_search_lines/2" do
    test "renders the empty-results line when results is []" do
      lines = Presenters.memory_search_lines("needle", [])

      assert "Memory search: needle" in lines
      assert Enum.any?(lines, &String.contains?(&1, "no memories matched"))
    end

    test "renders header plus two lines per result for populated results" do
      results = [
        %{key: "boot-sequence", type: "fact", content: "VM boots in 40ms"},
        %{key: "pref-tabs", type: "preference", content: "2-space indent"}
      ]

      lines = Presenters.memory_search_lines("boot", results)

      assert "Memory search: boot" in lines
      assert Enum.any?(lines, &String.contains?(&1, "2 result(s)"))
      assert Enum.any?(lines, &String.contains?(&1, "[fact] boot-sequence"))
      assert Enum.any?(lines, &String.contains?(&1, "VM boots in 40ms"))
      assert Enum.any?(lines, &String.contains?(&1, "[preference] pref-tabs"))
    end
  end

  describe "solution_lines/1" do
    test "renders the not-found message for :not_found" do
      assert Presenters.solution_lines(:not_found) == [
               "No solution with that signature."
             ]
    end

    test "renders a structured block for {:ok, solution}" do
      solution = %Solution{
        id: "sol-123",
        problem_signature: "abcd1234",
        solution_content: "def hello, do: :world",
        language: "elixir",
        framework: "phoenix",
        tags: ["ci", "hello"],
        trust_score: 0.75,
        inserted_at: "2026-04-20T00:00:00Z"
      }

      lines = Presenters.solution_lines({:ok, solution})

      assert Enum.any?(lines, &(&1 == "Solution sol-123"))
      assert Enum.any?(lines, &String.contains?(&1, "signature   abcd1234"))
      assert Enum.any?(lines, &String.contains?(&1, "language    elixir"))
      assert Enum.any?(lines, &String.contains?(&1, "framework   phoenix"))
      assert Enum.any?(lines, &String.contains?(&1, "trust       0.75"))
      assert Enum.any?(lines, &String.contains?(&1, "tags        ci, hello"))
      assert Enum.any?(lines, &String.contains?(&1, "inserted    2026-04-20T00:00:00Z"))
      assert Enum.any?(lines, &(&1 == "def hello, do: :world"))
    end
  end
end
