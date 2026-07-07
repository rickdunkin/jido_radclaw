defmodule JidoClaw.Agent.TemplatesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias JidoClaw.Agent.Templates

  # The literal spawnable (non-composer-private) set, sorted — pinned against
  # `Templates.spawnable_names/0` below. Deliberate friction: adding/removing/
  # renaming a template must touch this list consciously (like the JIDO.md refresh).
  @spawnable_names ~w[coder docs_writer fixer refactorer researcher reviewer test_runner verifier]

  describe "get/1 with valid template names" do
    for name <- @spawnable_names do
      test "should return {:ok, template} for '#{name}'" do
        assert {:ok, template} = Templates.get(unquote(name))
        assert is_map(template)
      end
    end

    test "should return a template with :module key" do
      for name <- @spawnable_names do
        assert {:ok, %{module: module}} = Templates.get(name)
        assert is_atom(module)
      end
    end

    test "should return a template with :description key" do
      for name <- @spawnable_names do
        assert {:ok, %{description: desc}} = Templates.get(name)
        assert is_binary(desc)
        assert desc != ""
      end
    end

    test "should return a template with :model key" do
      for name <- @spawnable_names do
        assert {:ok, %{model: model}} = Templates.get(name)
        assert is_atom(model)
      end
    end

    test "should return a template with :max_iterations key" do
      for name <- @spawnable_names do
        assert {:ok, %{max_iterations: iters}} = Templates.get(name)
        assert is_integer(iters)
        assert iters > 0
      end
    end

    test "max_iterations is derived from the worker module strategy options" do
      for name <- @spawnable_names do
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

      for name <- @spawnable_names do
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

    test "should contain all 16 templates" do
      # 7 general-purpose workers + the AR-4 `fixer` + the AR-8b composer-private
      # `sketch_build` + the AR-8b-2 composer-private `sketch_reviewer` + the
      # AR-8b-2 F2 composer-private `sketch_build_exec` + the AR-8c composer-private
      # `system_executor` + `system_verifier` + the AR-9 composer-private
      # `plan_drafter` + `plan_challenger` + `plan_arbiter`.
      assert map_size(Templates.list()) == 16
    end

    test "should have all expected template names as keys" do
      templates = Templates.list()

      for name <- @spawnable_names do
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

    test "should return exactly 16 names" do
      assert Enum.count(Templates.names()) == 16
    end

    test "should include all spawnable template names" do
      names = Templates.names()

      for expected <- @spawnable_names do
        assert expected in names, "Expected '#{expected}' in names/0 result"
      end
    end

    test "should return binary strings" do
      Enum.each(Templates.names(), fn name ->
        assert is_binary(name)
      end)
    end
  end

  describe "spawnable_names/0" do
    test "returns exactly the literal spawnable set (sorted)" do
      assert Templates.spawnable_names() == @spawnable_names
    end

    test "never includes a composer-private template" do
      for name <- Templates.spawnable_names() do
        refute Templates.composer_private?(name),
               "spawnable_names/0 must not include composer-private '#{name}'"
      end
    end
  end

  describe "exists?/1" do
    for name <- @spawnable_names do
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
      for name <- @spawnable_names do
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
      for name <- @spawnable_names do
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

  # Every composer-private template shares one set of structural invariants,
  # asserted table-driven over the registry itself — so the NEXT private template
  # is covered by adding it to the expected-name list, never by re-growing a
  # bespoke exists?/external_tools? block. Per-template FIELD pins (module,
  # forward_context, sandbox, composer_private) stay in their own describes below.
  describe "composer-private templates — shared invariants (table-driven)" do
    test "every composer-private template resolves, is external-tool-free, and stays out of the public set" do
      private =
        for {name, _template} <- Templates.list(), Templates.composer_private?(name), do: name

      # 3 sketch (AR-8b/AR-8b-2) + 2 system (AR-8c) + 3 plan-wave (AR-9) templates.
      assert Enum.sort(private) ==
               ~w(plan_arbiter plan_challenger plan_drafter sketch_build sketch_build_exec
                  sketch_reviewer system_executor system_verifier)

      for name <- private do
        assert {:ok, template} = Templates.get(name)
        assert is_atom(template.module), "#{name} must resolve to a worker module"
        assert Templates.composer_private_template?(template)
        # External MCP tools are withheld from every private template.
        refute Templates.external_tools?(name)
        # Deliberately NOT in @spawnable_names (the public forward_context: :public loop).
        refute name in @spawnable_names
        assert Templates.exists?(name)
        assert name in Templates.names()
      end
    end
  end

  # The composer-private sketch templates are deliberately NOT in @spawnable_names
  # (the public workers looped above asserting forward_context: :public): both
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
  end

  # AR-8c: the system-path workers. Unlike the sketch templates, they are
  # `sandbox: :none` (they run on the real machine — that is the point), so their
  # composer-privacy rides the explicit `:composer_private` flag, NOT the sandbox
  # tier. Also `forward_context: :none`, so (like the sketch templates) they are
  # deliberately NOT in @spawnable_names (the public-forward-context set).
  describe "AR-8c composer-private system templates" do
    test "system_executor is composer_private + forward_context: :none + sandbox: :none" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.SystemExecutor,
                forward_context: :none,
                sandbox: :none,
                composer_private: true
              }} = Templates.get("system_executor")
    end

    test "system_verifier is composer_private + forward_context: :none + sandbox: :none" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.SystemVerifier,
                forward_context: :none,
                sandbox: :none,
                composer_private: true
              }} = Templates.get("system_verifier")
    end
  end

  # AR-9: the plan-wave workers (multi-plan judge panel). Like the AR-8c system
  # workers they are `sandbox: :none` with the explicit `composer_private: true`
  # flag (they run plain read-only tools; privacy rides the flag, not a sandbox
  # tier) and `forward_context: :none`. The TIER lives on the `plan-arbiter`
  # STAGE (`model: :capable, effort: :high` — PR-4), never on the template.
  describe "AR-9 composer-private plan-wave templates" do
    test "plan_drafter is composer_private + forward_context: :none + sandbox: :none" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.PlanDrafter,
                forward_context: :none,
                sandbox: :none,
                composer_private: true,
                model: :fast
              }} = Templates.get("plan_drafter")
    end

    test "plan_challenger is composer_private + forward_context: :none + sandbox: :none" do
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.PlanChallenger,
                forward_context: :none,
                sandbox: :none,
                composer_private: true,
                model: :fast
              }} = Templates.get("plan_challenger")
    end

    test "plan_arbiter is composer_private + forward_context: :none + sandbox: :none + model: :fast" do
      # `model: :fast` on the TEMPLATE is deliberate — the arbiter's `:capable`
      # tier is a STAGE declaration applied per turn by the request transformer.
      assert {:ok,
              %{
                module: JidoClaw.Agent.Workers.PlanArbiter,
                forward_context: :none,
                sandbox: :none,
                composer_private: true,
                model: :fast
              }} = Templates.get("plan_arbiter")
    end
  end

  describe "composer_private?/1 (AR-8c central predicate)" do
    # The per-private-template positive cases live in the table-driven shared
    # invariants above; this describe keeps the negative/edge surface.
    test "is false for the public workers" do
      for name <- @spawnable_names do
        refute Templates.composer_private?(name)
      end
    end

    test "is false for the AR-4 fixer (a regular, reachable worker — not composer-private)" do
      refute Templates.composer_private?("fixer")
      assert Templates.external_tools?("fixer")
    end

    test "is false for main / unknown templates" do
      refute Templates.composer_private?("main")
      refute Templates.composer_private?("nonexistent")
      refute Templates.composer_private?("")
    end

    test "honours an override template that is sandbox: :none but composer_private: true" do
      override = %{
        "priv_stub" => %{
          module: JidoClaw.Agent.Workers.Coder,
          sandbox: :none,
          composer_private: true
        }
      }

      Application.put_env(:jido_claw, :agent_templates_override, override)
      on_exit(fn -> Application.delete_env(:jido_claw, :agent_templates_override) end)

      assert Templates.composer_private?("priv_stub")
      # And external MCP tools are withheld from it (the derived reader).
      refute Templates.external_tools?("priv_stub")
    end

    test "external_tools?/1 is false for composer-private templates, true for public ones" do
      refute Templates.external_tools?("system_executor")
      refute Templates.external_tools?("system_verifier")
      refute Templates.external_tools?("sketch_build")
      assert Templates.external_tools?("coder")
      assert Templates.external_tools?("main")
    end

    test "composer_private_template?/1 gates on an already-resolved map (provider-seam guard)" do
      # The map-shaped companion the provider-seam tools (spawn_agent /
      # send_to_agent) gate on: a sandboxed tier OR the explicit flag → private.
      assert Templates.composer_private_template?(%{sandbox: :prototype})
      assert Templates.composer_private_template?(%{sandbox: :docker})
      assert Templates.composer_private_template?(%{composer_private: true})

      # Defensive defaults: an un-hydrated provider map with no :sandbox /
      # :composer_private keys reads as public, as does an explicit :none.
      refute Templates.composer_private_template?(%{sandbox: :none})
      refute Templates.composer_private_template?(%{})

      refute Templates.composer_private_template?(%{
               module: JidoClaw.Agent.Workers.Coder,
               description: "public-looking provider map"
             })
    end
  end

  # Item 7 (camus C1-1) PR-1: the executor seam binding. Unlike the fc/ra/
  # sandbox policies, a malformed value RAISES at hydration (the tight
  # direction is refuse-to-run — silently mapping a typo to :in_process would
  # hand execution to the wrong executor).
  describe "executor hydration (item 7, camus C1-1 PR-1)" do
    test "every static template hydrates executor: :in_process + executor_config: %{} (byte-identity guard)" do
      for {name, template} <- Templates.list() do
        assert template.executor == :in_process, "expected :in_process executor for '#{name}'"
        assert template.executor_config == %{}, "expected %{} executor_config for '#{name}'"
      end

      assert {:ok, %{executor: :in_process, executor_config: %{}}} = Templates.get("coder")
    end

    test "{:forge, :fake} hydrates unchanged" do
      with_template_override("exec_fake", exec_template(executor: {:forge, :fake}), fn ->
        assert {:ok, %{executor: {:forge, :fake}, executor_config: %{}}} =
                 Templates.get("exec_fake")
      end)
    end

    test "{:forge, :shell} with a command hydrates unchanged" do
      template = exec_template(executor: {:forge, :shell}, executor_config: %{command: "true"})

      with_template_override("exec_shell", template, fn ->
        assert {:ok, %{executor: {:forge, :shell}, executor_config: %{command: "true"}}} =
                 Templates.get("exec_shell")
      end)
    end

    test "a command-less {:forge, :shell} raises at hydration (never a silent echo)" do
      with_template_override("exec_shell", exec_template(executor: {:forge, :shell}), fn ->
        assert_raise ArgumentError, ~r/requires :executor_config/, fn ->
          Templates.get("exec_shell")
        end
      end)
    end

    test "an empty-string shell command raises too" do
      template = exec_template(executor: {:forge, :shell}, executor_config: %{command: ""})

      with_template_override("exec_shell", template, fn ->
        assert_raise ArgumentError, ~r/requires :executor_config/, fn ->
          Templates.get("exec_shell")
        end
      end)
    end

    # `sh -c "   "` exits 0 with empty output — the same silent green a
    # command-less template forecloses.
    test "a whitespace-only shell command raises too" do
      template = exec_template(executor: {:forge, :shell}, executor_config: %{command: " \n\t "})

      with_template_override("exec_shell", template, fn ->
        assert_raise ArgumentError, ~r/requires :executor_config/, fn ->
          Templates.get("exec_shell")
        end
      end)
    end

    test "a typo'd executor raises with the expected union" do
      with_template_override("exec_typo", exec_template(executor: {:forge, :fkae}), fn ->
        assert_raise ArgumentError, ~r/invalid :executor/, fn -> Templates.get("exec_typo") end
      end)
    end

    test ":custom hydrates — dispatch refuses it, not hydration" do
      with_template_override("exec_unbuilt", exec_template(executor: {:forge, :custom}), fn ->
        assert {:ok, %{executor: {:forge, :custom}, executor_config: %{}}} =
                 Templates.get("exec_unbuilt")
      end)
    end

    test "a {:forge, _} executor refuses a sandboxed template (combo rule)" do
      template = exec_template(executor: {:forge, :fake}, sandbox: :prototype)

      with_template_override("exec_sbx", template, fn ->
        assert_raise ArgumentError, ~r/cannot combine with sandbox/, fn ->
          Templates.get("exec_sbx")
        end
      end)
    end

    test "a non-map executor_config raises for every kind (even :in_process)" do
      template = exec_template(executor_config: [command: "true"])

      with_template_override("exec_cfg", template, fn ->
        assert_raise ArgumentError, ~r/invalid :executor_config/, fn ->
          Templates.get("exec_cfg")
        end
      end)
    end
  end

  # Executor-seam PR-2: the vendor `executor_config` surface. P2a — the
  # normalizing return path: the `workspace: :repo` default is WRITTEN INTO
  # the hydrated config, not just implied by a reader-side fallback.
  describe "vendor executor_config hydration (item 7, camus C1-1 PR-2)" do
    test "vendor kinds with %{} hydrate workspace: :repo into the config (P2a)" do
      for kind <- [:codex, :claude_code] do
        with_template_override("exec_vendor", exec_template(executor: {:forge, kind}), fn ->
          assert {:ok, %{executor: {:forge, ^kind}, executor_config: %{workspace: :repo}}} =
                   Templates.get("exec_vendor")
        end)
      end
    end

    test "every workspace enum value is accepted and preserved" do
      for workspace <- [:repo, :scratch, :none] do
        template =
          exec_template(executor: {:forge, :codex}, executor_config: %{workspace: workspace})

        with_template_override("exec_vendor", template, fn ->
          assert {:ok, %{executor_config: %{workspace: ^workspace}}} =
                   Templates.get("exec_vendor")
        end)
      end
    end

    test "the full optional key surface hydrates unchanged" do
      config = %{
        workspace: :scratch,
        model: "gpt-5-codex",
        thinking_effort: "high",
        max_turns: 10,
        timeout_ms: 120_000
      }

      template = exec_template(executor: {:forge, :codex}, executor_config: config)

      with_template_override("exec_vendor", template, fn ->
        assert {:ok, %{executor_config: ^config}} = Templates.get("exec_vendor")
      end)
    end

    test "a bad workspace raises with the expected enum" do
      template = exec_template(executor: {:forge, :codex}, executor_config: %{workspace: :rpeo})

      with_template_override("exec_vendor", template, fn ->
        assert_raise ArgumentError, ~r/expected :repo \| :scratch \| :none/, fn ->
          Templates.get("exec_vendor")
        end
      end)
    end

    test "bad optional values raise — present keys are strict" do
      bad_configs = [
        %{model: ""},
        %{model: nil},
        %{thinking_effort: :high},
        %{max_turns: 0},
        %{max_turns: "40"},
        %{timeout_ms: -1}
      ]

      for config <- bad_configs do
        template = exec_template(executor: {:forge, :claude_code}, executor_config: config)

        with_template_override("exec_vendor", template, fn ->
          assert_raise ArgumentError, ~r/invalid :executor_config/, fn ->
            Templates.get("exec_vendor")
          end
        end)
      end
    end

    test "unknown keys raise — deliberately NO access/sandbox knobs this wave" do
      for config <- [%{access: :read_only}, %{sandbox: :local}, %{workspce: :repo}] do
        template = exec_template(executor: {:forge, :codex}, executor_config: config)

        with_template_override("exec_vendor", template, fn ->
          assert_raise ArgumentError, ~r/unknown :executor_config keys/, fn ->
            Templates.get("exec_vendor")
          end
        end)
      end
    end

    test "a workspace key on any NON-vendor kind raises" do
      non_vendor = [
        exec_template(executor_config: %{workspace: :repo}),
        exec_template(executor: {:forge, :fake}, executor_config: %{workspace: :repo}),
        exec_template(
          executor: {:forge, :shell},
          executor_config: %{command: "true", workspace: :repo}
        ),
        exec_template(executor: {:forge, :custom}, executor_config: %{workspace: :repo})
      ]

      for template <- non_vendor do
        with_template_override("exec_nonvendor", template, fn ->
          assert_raise ArgumentError, ~r/only valid on \{:forge, :codex \| :claude_code\}/, fn ->
            Templates.get("exec_nonvendor")
          end
        end)
      end
    end
  end

  # Item 7 PR-3: the `.jido/config.yaml` review-binding entry into the SAME
  # private validators — raises converted to operator-facing {:error, message}.
  describe "hydrate_review_binding/3 (item 7, camus C1-1 PR-3)" do
    test "a vendor kind over the real reviewer base hydrates workspace: :repo" do
      {:ok, base} = Templates.get("reviewer")

      for kind <- [:codex, :claude_code] do
        assert {:ok, {{:forge, ^kind}, %{workspace: :repo}}} =
                 Templates.hydrate_review_binding(kind, %{}, base)
      end
    end

    test "the optional key surface passes through the PR-1 validators" do
      {:ok, base} = Templates.get("reviewer")
      config = %{workspace: :scratch, model: "gpt-5-codex", max_turns: 10}

      assert {:ok, {{:forge, :codex}, ^config}} =
               Templates.hydrate_review_binding(:codex, config, base)
    end

    test "an unknown config key is an operator-facing error, not a raise" do
      {:ok, base} = Templates.get("reviewer")

      assert {:error, msg} = Templates.hydrate_review_binding(:codex, %{sandbox: :local}, base)
      assert msg =~ "unknown :executor_config keys"
    end

    test "a bad workspace value is an operator-facing error" do
      {:ok, base} = Templates.get("reviewer")

      assert {:error, msg} =
               Templates.hydrate_review_binding(:codex, %{workspace: "sideways"}, base)

      assert msg =~ "expected :repo | :scratch | :none"
    end

    test "a non-vendor kind is refused" do
      {:ok, base} = Templates.get("reviewer")

      for kind <- [:shell, :fake, :custom, :in_process, "codex"] do
        assert {:error, msg} = Templates.hydrate_review_binding(kind, %{}, base)
        assert msg =~ "expected :codex or :claude_code"
      end
    end

    test "a sandboxed base template refuses the combo — the REAL base is checked" do
      # The combo check must see the actual resolved template's :sandbox — a
      # synthetic sandbox-less base would make this refusal vacuous.
      sandboxed = exec_template(sandbox: :prototype)

      assert {:error, msg} = Templates.hydrate_review_binding(:codex, %{}, sandboxed)
      assert msg =~ "cannot combine with sandbox"
    end
  end

  defp exec_template(overrides) do
    Map.merge(%{module: JidoClaw.Agent.Workers.Coder, max_iterations: 1}, Map.new(overrides))
  end

  # Register a one-off named template map via the override hook, run `fun`,
  # then restore the prior override (the executor-seam sibling of the
  # field-shaped fc/ra helpers below — takes the WHOLE template).
  defp with_template_override(name, template, fun) do
    original = Application.get_env(:jido_claw, :agent_templates_override, %{})
    Application.put_env(:jido_claw, :agent_templates_override, Map.put(original, name, template))

    try do
      fun.()
    after
      Application.put_env(:jido_claw, :agent_templates_override, original)
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
