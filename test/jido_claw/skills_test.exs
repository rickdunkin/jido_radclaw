defmodule JidoClaw.SkillsTest do
  # async: false because each test starts a named GenServer (JidoClaw.Skills).
  use ExUnit.Case, async: false

  alias JidoClaw.Skills

  @default_skill_names ~w[full_review refactor_safe explore_codebase security_audit implement_feature debug_issue onboard_dev iterative_feature]
  @default_filenames ~w[full_review.yaml refactor_safe.yaml explore_codebase.yaml security_audit.yaml implement_feature.yaml debug_issue.yaml onboard_dev.yaml iterative_feature.yaml]

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  # Stops the app-managed Skills GenServer via the supervisor (prevents restart),
  # starts a test-scoped instance registered under the same name, and restores
  # the app-managed child on test exit.
  defp start_skills!(dir) do
    app_sup = Process.whereis(JidoClaw.Supervisor)

    if app_sup && Process.alive?(app_sup) do
      # Terminate through the supervisor so it doesn't immediately restart
      Supervisor.terminate_child(app_sup, JidoClaw.Skills)
    else
      # Fallback: stop directly if supervisor isn't around (e.g. isolated test run)
      if pid = Process.whereis(JidoClaw.Skills), do: Process.exit(pid, :kill)
    end

    {:ok, pid} = GenServer.start_link(JidoClaw.Skills, [project_dir: dir], name: JidoClaw.Skills)

    on_exit(fn ->
      # Stop our test instance and let the supervisor restart the real one
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)

      if app_sup && Process.alive?(app_sup) do
        Supervisor.restart_child(app_sup, JidoClaw.Skills)
      end
    end)

    pid
  end

  # ---------------------------------------------------------------------------
  # ensure_defaults/1
  # ---------------------------------------------------------------------------

  describe "ensure_defaults/1" do
    test "should return :ok", %{dir: dir} do
      assert :ok = Skills.ensure_defaults(dir)
    end

    test "should create .jido/skills/ directory when it does not exist", %{dir: dir} do
      skills_dir = Path.join([dir, ".jido", "skills"])
      refute File.exists?(skills_dir)

      Skills.ensure_defaults(dir)

      assert File.dir?(skills_dir)
    end

    test "should write all default YAML files", %{dir: dir} do
      Skills.ensure_defaults(dir)

      skills_dir = Path.join([dir, ".jido", "skills"])

      for filename <- @default_filenames do
        path = Path.join(skills_dir, filename)
        assert File.exists?(path), "Expected default skill file: #{filename}"
      end
    end

    test "should not overwrite an existing YAML file", %{dir: dir} do
      skills_dir = Path.join([dir, ".jido", "skills"])
      File.mkdir_p!(skills_dir)

      custom_content =
        "name: full_review\ndescription: custom override\nsteps: []\nsynthesis: custom\n"

      path = Path.join(skills_dir, "full_review.yaml")
      File.write!(path, custom_content)

      # Call ensure_defaults — should NOT overwrite our custom file
      Skills.ensure_defaults(dir)

      assert File.read!(path) == custom_content
    end

    test "should backfill missing defaults alongside existing custom skills", %{dir: dir} do
      skills_dir = Path.join([dir, ".jido", "skills"])
      File.mkdir_p!(skills_dir)

      # Write a custom skill so the directory is non-empty
      File.write!(Path.join(skills_dir, "custom.yaml"), "name: custom\nsteps: []\n")

      Skills.ensure_defaults(dir)

      # Default files SHOULD be written — backfill missing without overwriting
      for filename <- @default_filenames do
        assert File.exists?(Path.join(skills_dir, filename)),
               "Expected backfilled default skill file: #{filename}"
      end

      # Custom file should still exist untouched
      assert File.exists?(Path.join(skills_dir, "custom.yaml"))
    end

    test "should be idempotent — calling twice does not error", %{dir: dir} do
      assert :ok = Skills.ensure_defaults(dir)
      assert :ok = Skills.ensure_defaults(dir)
    end
  end

  # ---------------------------------------------------------------------------
  # all/0 (replaces the removed load/1)
  # ---------------------------------------------------------------------------

  describe "all/0" do
    test "should return a list", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)
      assert is_list(Skills.all())
    end

    test "should return list of %JidoClaw.Skills{} structs", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      for skill <- Skills.all() do
        assert %Skills{} = skill
      end
    end

    test "should return all default skills after loading defaults", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)
      assert length(Skills.all()) == length(@default_skill_names)
    end

    test "each skill has a non-empty name", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      for skill <- Skills.all() do
        assert is_binary(skill.name)
        assert skill.name != ""
      end
    end

    test "each skill has a description", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      for skill <- Skills.all() do
        assert is_binary(skill.description)
      end
    end

    test "each skill has a steps list", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      for skill <- Skills.all() do
        assert is_list(skill.steps)
        assert length(skill.steps) > 0
      end
    end

    test "each skill has a synthesis string", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      for skill <- Skills.all() do
        assert is_binary(skill.synthesis)
        assert skill.synthesis != ""
      end
    end

    test "should return empty list when directory does not exist", %{dir: dir} do
      non_existent = Path.join(dir, "no_such_subdir")
      start_skills!(non_existent)
      assert Skills.all() == []
    end

    test "should return empty list when skills dir is empty", %{dir: dir} do
      skills_dir = Path.join([dir, ".jido", "skills"])
      File.mkdir_p!(skills_dir)
      start_skills!(dir)

      assert Skills.all() == []
    end

    test "should ignore non-YAML files in skills directory", %{dir: dir} do
      skills_dir = Path.join([dir, ".jido", "skills"])
      File.mkdir_p!(skills_dir)

      File.write!(Path.join(skills_dir, "readme.txt"), "just a note")
      File.write!(Path.join(skills_dir, ".hidden"), "hidden file")

      start_skills!(dir)
      assert Skills.all() == []
    end

    test "full_review skill has steps", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      {:ok, skill} = Skills.get("full_review")
      assert length(skill.steps) >= 2
    end

    test "refactor_safe skill has 3 steps", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      {:ok, skill} = Skills.get("refactor_safe")
      assert length(skill.steps) == 3
    end

    test "explore_codebase skill has 2 steps", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      {:ok, skill} = Skills.get("explore_codebase")
      assert length(skill.steps) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # get/1 (GenServer-backed; get/2 compat wrapper delegates to it)
  # ---------------------------------------------------------------------------

  describe "get/1" do
    for name <- ~w[full_review refactor_safe explore_codebase] do
      test "should find default skill by name '#{name}'", %{dir: dir} do
        Skills.ensure_defaults(dir)
        start_skills!(dir)

        assert {:ok, skill} = Skills.get(unquote(name))
        assert %Skills{} = skill
        assert skill.name == unquote(name)
      end
    end

    test "should return {:error, message} for unknown skill name", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      assert {:error, message} = Skills.get("nonexistent_skill")
      assert is_binary(message)
    end

    test "error message includes the requested skill name", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      assert {:error, message} = Skills.get("bogus")
      assert message =~ "bogus"
    end

    test "should return error when no skills were loaded", %{dir: dir} do
      # Don't call ensure_defaults — GenServer starts with empty skill list
      start_skills!(dir)
      assert {:error, _} = Skills.get("full_review")
    end
  end

  # ---------------------------------------------------------------------------
  # list/0 (GenServer-backed; list/1 compat wrapper delegates to it)
  # ---------------------------------------------------------------------------

  describe "list/0" do
    test "should return a list of skill name strings", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      names = Skills.list()
      assert is_list(names)

      for name <- names do
        assert is_binary(name)
      end
    end

    test "should return all default skill names", %{dir: dir} do
      Skills.ensure_defaults(dir)
      start_skills!(dir)

      names = Skills.list()
      assert length(names) == length(@default_skill_names)

      for expected <- @default_skill_names do
        assert expected in names, "Expected '#{expected}' in list/0 result"
      end
    end

    test "should return empty list when no skills exist", %{dir: dir} do
      start_skills!(dir)
      assert Skills.list() == []
    end
  end
end
