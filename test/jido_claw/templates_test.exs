defmodule JidoClaw.Agent.TemplatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias JidoClaw.Agent.Templates

  @valid_names ~w[coder test_runner reviewer docs_writer researcher refactorer verifier]

  describe "get/1 with valid template names" do
    for name <- ~w[coder test_runner reviewer docs_writer researcher refactorer verifier] do
      test "should return {:ok, template} for '#{name}'" do
        assert {:ok, template} = Templates.get(unquote(name))
        assert is_map(template)
      end
    end

    test "should return a template with :module key" do
      for name <- @valid_names do
        assert {:ok, %{module: module}} = Templates.get(name)
        assert is_atom(module)
      end
    end

    test "should return a template with :description key" do
      for name <- @valid_names do
        assert {:ok, %{description: desc}} = Templates.get(name)
        assert is_binary(desc)
        assert desc != ""
      end
    end

    test "should return a template with :model key" do
      for name <- @valid_names do
        assert {:ok, %{model: model}} = Templates.get(name)
        assert is_atom(model)
      end
    end

    test "should return a template with :max_iterations key" do
      for name <- @valid_names do
        assert {:ok, %{max_iterations: iters}} = Templates.get(name)
        assert is_integer(iters)
        assert iters > 0
      end
    end

    test "max_iterations is derived from the worker module strategy options" do
      for name <- @valid_names do
        assert {:ok, %{module: module, max_iterations: template_iters}} = Templates.get(name)
        assert Keyword.fetch!(module.strategy_opts(), :max_iterations) == template_iters
      end
    end

    test "coder template has full capability max_iterations of 25" do
      assert {:ok, %{max_iterations: 25}} = Templates.get("coder")
    end

    test "refactorer template has max_iterations of 25" do
      assert {:ok, %{max_iterations: 25}} = Templates.get("refactorer")
    end

    test "read-only templates have lower max_iterations of 15" do
      for name <- ~w[test_runner reviewer docs_writer researcher] do
        assert {:ok, %{max_iterations: 15}} = Templates.get(name)
      end
    end

    test "coder uses WorkerCoder module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.Coder}} = Templates.get("coder")
    end

    test "test_runner uses WorkerTestRunner module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.TestRunner}} = Templates.get("test_runner")
    end

    test "reviewer uses WorkerReviewer module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.Reviewer}} = Templates.get("reviewer")
    end

    test "docs_writer uses WorkerDocsWriter module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.DocsWriter}} = Templates.get("docs_writer")
    end

    test "researcher uses WorkerResearcher module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.Researcher}} = Templates.get("researcher")
    end

    test "refactorer uses WorkerRefactorer module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.Refactorer}} = Templates.get("refactorer")
    end

    test "verifier uses WorkerVerifier module" do
      assert {:ok, %{module: JidoClaw.Agent.Workers.Verifier}} = Templates.get("verifier")
    end

    test "verifier template has max_iterations of 20" do
      assert {:ok, %{max_iterations: 20}} = Templates.get("verifier")
    end
  end

  describe "get/1 with invalid template names" do
    test "should return {:error, message} for unknown name" do
      assert {:error, message} = Templates.get("nonexistent")
      assert is_binary(message)
    end

    test "error message mentions the unknown name" do
      assert {:error, message} = Templates.get("bogus_template")
      assert message =~ "bogus_template"
    end

    test "error message lists available template names" do
      assert {:error, message} = Templates.get("unknown")

      for name <- @valid_names do
        assert message =~ name
      end
    end

    test "should return error for empty string" do
      assert {:error, _} = Templates.get("")
    end

    test "should return error for wrong casing" do
      assert {:error, _} = Templates.get("Coder")
      assert {:error, _} = Templates.get("CODER")
    end
  end

  describe "list/0" do
    test "should return a map" do
      assert is_map(Templates.list())
    end

    test "should contain all 10 templates" do
      # 7 general-purpose workers + the AR-8b composer-private `sketch_build` +
      # the AR-8b-2 composer-private `sketch_reviewer` + the AR-8b-2 F2
      # composer-private `sketch_build_exec`.
      assert map_size(Templates.list()) == 10
    end

    test "should have all expected template names as keys" do
      templates = Templates.list()

      for name <- @valid_names do
        assert Map.has_key?(templates, name), "Expected key '#{name}' in list/0 result"
      end
    end

    test "should return maps with all required keys as values" do
      Enum.each(Templates.list(), fn {_name, template} ->
        assert Map.has_key?(template, :module)
        assert Map.has_key?(template, :description)
        assert Map.has_key?(template, :model)
        assert Map.has_key?(template, :max_iterations)
      end)
    end
  end

  describe "names/0" do
    test "should return a list" do
      assert is_list(Templates.names())
    end

    test "should return exactly 10 names" do
      assert Enum.count(Templates.names()) == 10
    end

    test "should include all 7 expected template names" do
      names = Templates.names()

      for expected <- @valid_names do
        assert expected in names, "Expected '#{expected}' in names/0 result"
      end
    end

    test "should return binary strings" do
      Enum.each(Templates.names(), fn name ->
        assert is_binary(name)
      end)
    end
  end

  describe "exists?/1" do
    for name <- ~w[coder test_runner reviewer docs_writer researcher refactorer verifier] do
      test "should return true for valid name '#{name}'" do
        assert Templates.exists?(unquote(name)) == true
      end
    end

    test "should return false for unknown name" do
      assert Templates.exists?("unknown_template") == false
    end

    test "should return false for empty string" do
      assert Templates.exists?("") == false
    end

    test "should return false for wrong casing" do
      assert Templates.exists?("Coder") == false
      assert Templates.exists?("REVIEWER") == false
    end

    test "should return false for nil-like strings" do
      assert Templates.exists?("nil") == false
    end
  end

  describe "forward_context hydration" do
    test "static templates default to :public" do
      for name <- @valid_names do
        assert {:ok, %{forward_context: :public}} = Templates.get(name)
      end

      assert {:ok, %{forward_context: :public}} = Templates.get("coder")
    end

    test "a valid {:only, [...]} policy survives hydration unchanged" do
      with_fc_override({:only, [:user_id]}, fn ->
        assert {:ok, %{forward_context: {:only, [:user_id]}}} = Templates.get("fc_test")
      end)
    end

    test ~s(string-key policy {:only, ["user_id"]} fails closed to :none) do
      assert_fc_fails_closed({:only, ["user_id"]})
    end

    test "typo'd-atom policy {:except, [:usr_id]} fails closed to :none (would else fail OPEN)" do
      assert_fc_fails_closed({:except, [:usr_id]})
    end

    test "a bogus value fails closed to :none" do
      assert_fc_fails_closed(:nope)
    end
  end

  describe "require_approval hydration" do
    test "static templates default to []" do
      for name <- @valid_names do
        assert {:ok, %{require_approval: []}} = Templates.get(name)
      end
    end

    test "a valid list of real tool names survives hydration unchanged" do
      with_ra_override(["read_file", "write_file"], fn ->
        assert {:ok, %{require_approval: ["read_file", "write_file"]}} = Templates.get("ra_test")
      end)
    end

    test ":all survives hydration unchanged" do
      with_ra_override(:all, fn ->
        assert {:ok, %{require_approval: :all}} = Templates.get("ra_test")
      end)
    end

    test "a non-list value falls back to [] (the global floor) with a warning" do
      assert_ra_floor("read_file")
    end

    test "a list with a non-binary element falls back to []" do
      assert_ra_floor(["read_file", :write_file])
    end

    test "a list with an empty-string element falls back to []" do
      assert_ra_floor(["read_file", ""])
    end

    test "require_approval/1 resolves through get/1 (honours the override hook)" do
      with_ra_override(["read_file"], fn ->
        assert Templates.require_approval("ra_test") == ["read_file"]
      end)
    end

    test "require_approval/1 returns [] for an unknown template (e.g. main)" do
      assert Templates.require_approval("main") == []
      assert Templates.require_approval("nonexistent") == []
    end
  end

  # The composer-private sketch templates are deliberately NOT in @valid_names
  # (the 7 public workers looped above asserting forward_context: :public): both
  # are forward_context: :none + sandbox: :prototype, so they are pinned here.
  describe "AR-8b / AR-8b-2 composer-private sketch templates" do
    test "sketch_build is forward_context: :none, sandbox: :prototype" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.SketchBuild,
                forward_context: :none,
                sandbox: :prototype
              }} =
               Templates.get("sketch_build")
    end

    test "sketch_reviewer is forward_context: :none, sandbox: :prototype" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.SketchReviewer,
                forward_context: :none,
                sandbox: :prototype
              }} = Templates.get("sketch_reviewer")
    end

    test "sketch_build_exec is forward_context: {:only, [:forge_session_key]}, sandbox: :docker" do
      # AR-8b-2 F2: strict isolation (like `:none`) EXCEPT the Forge session key
      # passes through (D5), and `sandbox: :docker` routes `run_command` into the
      # Forge microVM.
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.SketchBuildExec,
                forward_context: {:only, [:forge_session_key]},
                sandbox: :docker
              }} = Templates.get("sketch_build_exec")
    end

    test "exists?/1 + names/0 include all three sketch templates" do
      assert Templates.exists?("sketch_build")
      assert Templates.exists?("sketch_reviewer")
      assert Templates.exists?("sketch_build_exec")
      assert "sketch_build" in Templates.names()
      assert "sketch_reviewer" in Templates.names()
      assert "sketch_build_exec" in Templates.names()
    end
  end

  # Register a one-off `"fc_test"` template carrying `forward_context: fc`
  # via the override hook, run `fun`, then restore the prior override.
  defp with_fc_override(fc, fun) do
    original = Application.get_env(:jido_claw, :agent_templates_override, %{})

    template = %{module: JidoClaw.Agent.Workers.Coder, max_iterations: 1, forward_context: fc}

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      Map.put(original, "fc_test", template)
    )

    try do
      fun.()
    after
      Application.put_env(:jido_claw, :agent_templates_override, original)
    end
  end

  defp assert_fc_fails_closed(fc) do
    with_fc_override(fc, fn ->
      log =
        capture_log(fn ->
          assert {:ok, %{forward_context: :none}} = Templates.get("fc_test")
        end)

      assert log =~ "invalid :forward_context"
    end)
  end

  # Register a one-off `"ra_test"` template carrying `require_approval: ra`
  # via the override hook, run `fun`, then restore the prior override.
  defp with_ra_override(ra, fun) do
    original = Application.get_env(:jido_claw, :agent_templates_override, %{})

    template = %{module: JidoClaw.Agent.Workers.Coder, max_iterations: 1, require_approval: ra}

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      Map.put(original, "ra_test", template)
    )

    try do
      fun.()
    after
      Application.put_env(:jido_claw, :agent_templates_override, original)
    end
  end

  defp assert_ra_floor(ra) do
    with_ra_override(ra, fn ->
      log =
        capture_log(fn ->
          assert {:ok, %{require_approval: []}} = Templates.get("ra_test")
        end)

      assert log =~ "invalid :require_approval"
    end)
  end
end
