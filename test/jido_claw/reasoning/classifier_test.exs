defmodule JidoClaw.Reasoning.ClassifierTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.{Classifier, TaskProfile}

  describe "profile/2" do
    test "returns a TaskProfile with populated core fields" do
      profile = Classifier.profile("Explain how to add a new user to the system")
      assert %TaskProfile{} = profile
      assert profile.word_count > 0
      assert profile.prompt_length > 0
      assert is_boolean(profile.has_code_block)
      assert is_integer(profile.has_constraints)
    end

    test "detects error signal from stack-trace-like prompts" do
      prompt = """
      I'm seeing a NullPointerException in UserService.create when I submit the
      signup form. traceback shows it's crashing at line 42.
      """

      profile = Classifier.profile(prompt)
      assert profile.error_signal
      assert profile.task_type == :debugging
    end

    test "classifies debugging tasks" do
      prompt = "Fix the bug in the login handler that crashes when email is nil"
      profile = Classifier.profile(prompt)
      assert profile.task_type == :debugging
    end

    test "classifies planning tasks with numbered questions" do
      prompt = """
      Plan a migration strategy for moving from Ecto to Ash in the Accounts domain.

      1. What resources need to be converted first?
      2. How do we handle the transition period?
      3. What tests should cover the migration?
      """

      profile = Classifier.profile(prompt)
      assert profile.task_type == :planning
      assert profile.has_enumeration
    end

    test "classifies simple QA tasks" do
      profile = Classifier.profile("What is a GenServer?")
      assert profile.task_type == :qa
      assert profile.complexity == :simple
      # Regression guard: simple QA must prefer cot over cod.
      assert {:ok, "cot", _} = Classifier.recommend(profile)
    end

    test "classifies refactoring tasks" do
      profile =
        Classifier.profile("Refactor the auth module to extract token logic into a separate file")

      assert profile.task_type == :refactoring
    end

    test "detects code blocks" do
      prompt = """
      Review this:

      ```elixir
      def hello, do: :world
      ```
      """

      profile = Classifier.profile(prompt)
      assert profile.has_code_block
    end

    test "detects multi-file mentions via path patterns" do
      prompt = "Update lib/foo.ex and lib/bar.ex to use the new API"
      profile = Classifier.profile(prompt)
      assert profile.mentions_multiple_files
    end

    test "returns :open_ended when no keywords match" do
      profile = Classifier.profile("Hello there friend")
      assert profile.task_type == :open_ended
    end

    test "bumps complexity with enumeration + constraints" do
      prompt = """
      Plan the following:
      1. must implement user creation
      2. should not break existing flows
      3. cannot drop data
      4. must validate inputs
      """

      profile = Classifier.profile(prompt)
      assert profile.complexity in [:complex, :highly_complex]
    end

    test "is deterministic for the same input" do
      prompt = "Verify the migration is safe under concurrent writes"
      assert Classifier.profile(prompt) == Classifier.profile(prompt)
    end
  end

  describe "recommend/2" do
    test "recommends react for debugging tasks" do
      profile = Classifier.profile("Fix the traceback crashing on login")
      assert {:ok, "react", confidence} = Classifier.recommend(profile)
      assert confidence > 0.0
    end

    test "recommends tot for complex planning tasks" do
      prompt = """
      Plan the architecture for a new authentication system.
      1. Decide on token storage
      2. Choose session management
      3. Design the authorization layer
      4. Plan rollout
      """

      profile = Classifier.profile(prompt)
      assert {:ok, strategy, _} = Classifier.recommend(profile)
      assert strategy in ["tot", "got"]
    end

    test "never returns adaptive" do
      for prompt <- [
            "Fix this bug",
            "Plan the migration",
            "What is an atom?",
            "Refactor this module",
            "Verify correctness"
          ] do
        profile = Classifier.profile(prompt)
        {:ok, strategy, _} = Classifier.recommend(profile)
        refute strategy == "adaptive"
      end
    end

    test "accepts but ignores opts[:history] in 0.4.1" do
      profile = Classifier.profile("What is a GenServer?")
      without = Classifier.recommend(profile)
      with_hist = Classifier.recommend(profile, history: %{foo: :bar})
      assert without == with_hist
    end

    test "falls back to cot when no candidate scores" do
      # Synthesize a profile with no task/complexity matches by hand.
      profile = %TaskProfile{
        prompt_length: 10,
        word_count: 2,
        domain: nil,
        target: nil,
        task_type: :open_ended,
        complexity: :simple,
        has_code_block: false,
        has_constraints: 0,
        has_enumeration: false,
        mentions_multiple_files: false,
        error_signal: false,
        keyword_buckets: %{}
      }

      assert {:ok, "cot", _} = Classifier.recommend(profile)
    end
  end

  describe "recommend_for/2" do
    test "returns profile + recommendation in one call" do
      assert {:ok, strategy, confidence, %TaskProfile{} = profile} =
               Classifier.recommend_for("Fix the null pointer in login")

      assert strategy in ["react", "cot"]
      assert confidence > 0.0
      assert profile.task_type == :debugging
    end
  end

  describe "golden fixtures" do
    @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "classifier_prompts"])

    for fixture_path <- Path.wildcard(Path.join(@fixtures_dir, "*.md")) do
      name = Path.basename(fixture_path, ".md")

      test "fixture: #{name}" do
        %{meta: meta, body: prompt} = load_fixture(unquote(fixture_path))
        profile = Classifier.profile(prompt)

        if expected = Map.get(meta, "expected_task_type") do
          assert Atom.to_string(profile.task_type) == expected,
                 "fixture #{unquote(name)}: expected task_type=#{expected}, got #{profile.task_type}"
        end

        if expected = Map.get(meta, "expected_complexity") do
          assert Atom.to_string(profile.complexity) == expected,
                 "fixture #{unquote(name)}: expected complexity=#{expected}, got #{profile.complexity}"
        end

        if expected = Map.get(meta, "expected_strategy") do
          assert {:ok, actual, _conf} = Classifier.recommend(profile)

          assert actual == expected,
                 "fixture #{unquote(name)}: expected strategy=#{expected}, got #{actual}"
        end
      end
    end

    defp load_fixture(path) do
      contents = File.read!(path)

      [_, frontmatter, body] =
        Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, contents)

      meta =
        frontmatter
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {String.trim(k), String.trim(v)}
        end)
        |> Map.new()

      %{meta: meta, body: String.trim(body)}
    end
  end
end
