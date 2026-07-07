defmodule JidoClaw.Orchestration.ReviewIndependenceTest do
  @moduledoc """
  Resolver + invariant unit coverage for
  `JidoClaw.Orchestration.ReviewIndependence` (item 7 PR-3): the strict YAML
  boundary (closed executor parser, whitelisted keys, loud refusals), the
  provider-identity map (`vendor_of/2` incl. the alias-shape edge cases), the
  dispatch overlay (`apply_executor/3` incl. test-seam precedence + the
  present-nil context trap), and `check_route/2` over fixture catalogs
  (same-vendor held, cross-vendor ok, producer-own tier, degraded pass,
  indeterminate producer, optional-input producers, nil-safety).

  Non-async: mutates global app env (`:jido_ai, :model_aliases`,
  `:agent_templates_override`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Orchestration.ReviewIndependence
  alias JidoClaw.RouteComposer.TestFixtures

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp project_with_config!(yaml) do
    dir = Path.join(System.tmp_dir!(), "jido_ri_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".jido"))
    File.write!(Path.join([dir, ".jido", "config.yaml"]), yaml)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp empty_project! do
    dir = Path.join(System.tmp_dir!(), "jido_ri_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp put_aliases!(aliases) do
    previous = Application.get_env(:jido_ai, :model_aliases)
    Application.put_env(:jido_ai, :model_aliases, aliases)
    on_exit(fn -> restore_env(:jido_ai, :model_aliases, previous) end)
  end

  defp put_override!(override) do
    previous = Application.get_env(:jido_claw, :agent_templates_override)
    Application.put_env(:jido_claw, :agent_templates_override, override)
    on_exit(fn -> restore_env(:jido_claw, :agent_templates_override, previous) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp attach_telemetry! do
    handler_id = "ri-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:jido_claw, :review_independence],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:ri_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # implementer(coder) → quality-reviewer(reviewer); `:producer` / `:reviewer`
  # keyword extras PREPEND so they win Keyword.get in the stage builder.
  defp review_catalog(opts \\ []) do
    producer_extra = Keyword.get(opts, :producer, [])
    reviewer_extra = Keyword.get(opts, :reviewer, [])

    %{
      "implementer" =>
        TestFixtures.stage(
          producer_extra ++
            [
              name: "implementer",
              unit: {:worker_template, "coder"},
              task: "implement",
              routes: ["code"],
              sub: ["request-received"],
              req: ["request"],
              out: ["diff"],
              pub: ["code-written", "scope-shift"]
            ]
        ),
      "quality-reviewer" =>
        TestFixtures.stage(
          reviewer_extra ++
            [
              name: "quality-reviewer",
              unit: {:worker_template, "reviewer"},
              lens: "quality",
              task: "review",
              routes: ["code"],
              sub: ["code-written"],
              req: ["diff"],
              out: ["findings"],
              pub: ["clean:quality", "findings:quality", "scope-shift"]
            ]
        )
    }
  end

  defp fixer_catalog do
    Map.put(
      review_catalog(reviewer: [opt: ["fix"]]),
      "fixer",
      TestFixtures.stage(
        name: "fixer",
        unit: {:worker_template, "fixer"},
        task: "fix findings",
        routes: ["code"],
        sub: ["findings"],
        req: ["diff"],
        out: ["fix"],
        pub: ["code-written", "scope-shift"]
      )
    )
  end

  # ---------------------------------------------------------------------------
  # mode/1
  # ---------------------------------------------------------------------------

  describe "mode/1" do
    test "absent section (and absent config file) is :strict" do
      assert {:ok, :strict} = ReviewIndependence.mode(empty_project!())

      dir = project_with_config!("provider: ollama\n")
      assert {:ok, :strict} = ReviewIndependence.mode(dir)
    end

    test "strict and degraded parse as named" do
      strict_dir = project_with_config!("review:\n  executor: codex\n  independence: strict\n")
      assert {:ok, :strict} = ReviewIndependence.mode(strict_dir)

      degraded_dir =
        project_with_config!("review:\n  executor: codex\n  independence: degraded\n")

      assert {:ok, :degraded} = ReviewIndependence.mode(degraded_dir)
    end

    test "a typo'd independence value is a LOUD error, never silently strict" do
      dir = project_with_config!("review:\n  executor: codex\n  independence: degrated\n")

      assert {:error, {:invalid_review_config, msg}} = ReviewIndependence.mode(dir)
      assert msg =~ "independence"
      assert msg =~ "strict | degraded"
    end

    test "nil / blank / non-binary project dirs read no config (:strict)" do
      assert {:ok, :strict} = ReviewIndependence.mode(nil)
      assert {:ok, :strict} = ReviewIndependence.mode("")
      assert {:ok, :strict} = ReviewIndependence.mode(:not_a_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # configured_reviewer_binding/1 + section shape
  # ---------------------------------------------------------------------------

  describe "configured_reviewer_binding/1" do
    test "absent section / absent executor key is :default" do
      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(empty_project!())

      dir = project_with_config!("review:\n  independence: degraded\n")
      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(dir)

      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(nil)
    end

    test "codex and claude_code parse via the closed parser" do
      codex_dir = project_with_config!("review:\n  executor: codex\n")
      assert {:ok, {:codex, %{}}} = ReviewIndependence.configured_reviewer_binding(codex_dir)

      claude_dir = project_with_config!("review:\n  executor: claude_code\n")

      assert {:ok, {:claude_code, %{}}} =
               ReviewIndependence.configured_reviewer_binding(claude_dir)
    end

    test "any other executor value is a loud error — never String.to_atom" do
      for executor_yaml <- ["gpt", "shell", "fake", "in_process"] do
        dir = project_with_config!("review:\n  executor: #{executor_yaml}\n")

        assert {:error, {:invalid_review_config, msg}} =
                 ReviewIndependence.configured_reviewer_binding(dir)

        assert msg =~ "codex | claude_code"
      end

      dir = project_with_config!("review:\n  executor:\n    - codex\n")

      assert {:error, {:invalid_review_config, _msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)
    end

    test "a non-map review: section is a loud error, never treated as absent" do
      dir = project_with_config!("review: codex\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "must be a map"
    end

    test "an unknown top-level key (the `executer:` typo) refuses loudly" do
      dir = project_with_config!("review:\n  executer: codex\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "executer"
      assert msg =~ "allowed keys"
    end

    test "executor_config without executor refuses loudly (never silently :default)" do
      dir = project_with_config!("review:\n  executor_config:\n    workspace: repo\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "executor_config without executor"
    end

    test "executor_config keys are whitelisted + translated; workspace value coerced" do
      dir =
        project_with_config!("""
        review:
          executor: claude_code
          executor_config:
            workspace: scratch
            model: claude-opus-4-6
            max_turns: 12
            timeout_ms: 60000
            thinking_effort: high
        """)

      assert {:ok, {:claude_code, config}} = ReviewIndependence.configured_reviewer_binding(dir)

      assert config == %{
               workspace: :scratch,
               model: "claude-opus-4-6",
               max_turns: 12,
               timeout_ms: 60_000,
               thinking_effort: "high"
             }
    end

    test "an unknown executor_config key refuses loudly" do
      dir =
        project_with_config!("review:\n  executor: codex\n  executor_config:\n    sandbox: x\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "sandbox"
      assert msg =~ "allowed keys"
    end

    test "a non-map executor_config refuses loudly" do
      dir = project_with_config!("review:\n  executor: codex\n  executor_config: repo\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "executor_config must be a map"
    end

    test "an unknown workspace VALUE passes through for the PR-1 validator to reject" do
      dir =
        project_with_config!(
          "review:\n  executor: codex\n  executor_config:\n    workspace: sideways\n"
        )

      assert {:ok, {:codex, %{workspace: "sideways"}}} =
               ReviewIndependence.configured_reviewer_binding(dir)
    end

    test "a malformed independence: refuses the binding read too — the section validates as a whole" do
      for independence_yaml <- ["independence: degrated", "independence:"] do
        dir = project_with_config!("review:\n  executor: codex\n  #{independence_yaml}\n")

        assert {:error, {:invalid_review_config, msg}} =
                 ReviewIndependence.configured_reviewer_binding(dir)

        assert msg =~ "strict | degraded"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # strict config read (fail closed)
  # ---------------------------------------------------------------------------

  describe "strict config read (fail closed)" do
    # A file that exists but cannot parse — the P1 fail-open hole: the old
    # tolerant `Config.load/1` collapsed this to %{} and the knob read as
    # "unconfigured" at both seams.
    @malformed_yaml "review:\n  executor: codex\n  independence: [\n"

    test "a malformed config.yaml refuses loudly from every entry point (never absent)" do
      dir = project_with_config!(@malformed_yaml)

      assert {:error, {:invalid_review_config, mode_msg}} = ReviewIndependence.mode(dir)
      assert mode_msg =~ "config.yaml"

      assert {:error, {:invalid_review_config, binding_msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert binding_msg =~ "config.yaml"

      assert {:error, {:invalid_review_config, route_msg}} =
               ReviewIndependence.check_route(review_catalog(), dir)

      assert route_msg =~ "config.yaml"

      {:ok, template} = Templates.get("reviewer")

      assert {:error, {:invalid_review_config, dispatch_msg}} =
               ReviewIndependence.apply_executor(template, "reviewer", %{project_dir: dir})

      assert dispatch_msg =~ "config.yaml"
    end

    test "a present-null review: section is a loud error, never treated as absent" do
      dir = project_with_config!("review:\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "must be a map"
    end

    test "a present-null executor: is a loud error, never silently :default" do
      dir = project_with_config!("review:\n  executor:\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "codex | claude_code"
    end

    test "a present-null independence: is a loud error, never silently :strict" do
      dir = project_with_config!("review:\n  executor: codex\n  independence:\n")

      assert {:error, {:invalid_review_config, msg}} = ReviewIndependence.mode(dir)
      assert msg =~ "strict | degraded"
    end

    test "a present-null executor_config: is a loud error, never silently %{}" do
      dir = project_with_config!("review:\n  executor: codex\n  executor_config:\n")

      assert {:error, {:invalid_review_config, msg}} =
               ReviewIndependence.configured_reviewer_binding(dir)

      assert msg =~ "executor_config must be a map"
    end

    test "an unreadable config.yaml (a directory) refuses loudly — enoent-only absence" do
      dir = Path.join(System.tmp_dir!(), "jido_ri_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([dir, ".jido", "config.yaml"]))
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, {:invalid_review_config, msg}} = ReviewIndependence.mode(dir)
      assert msg =~ "config.yaml"
    end

    test "absent file / absent section / empty-map section stay byte-identical" do
      assert {:ok, :strict} = ReviewIndependence.mode(empty_project!())
      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(empty_project!())

      no_section = project_with_config!("provider: ollama\n")
      assert {:ok, :strict} = ReviewIndependence.mode(no_section)
      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(no_section)

      # An empty MAP section (unlike present-null) is a valid no-op.
      empty_map = project_with_config!("review: {}\n")
      assert {:ok, :strict} = ReviewIndependence.mode(empty_map)
      assert {:ok, :default} = ReviewIndependence.configured_reviewer_binding(empty_map)
    end
  end

  # ---------------------------------------------------------------------------
  # vendor_of/2
  # ---------------------------------------------------------------------------

  describe "vendor_of/2" do
    test "vendor CLI kinds carry their explicit provider identity" do
      assert ReviewIndependence.vendor_of({:forge, :codex}, nil) == {:provider, "openai"}
      assert ReviewIndependence.vendor_of({:forge, :claude_code}, nil) == {:provider, "anthropic"}
    end

    test "non-LLM/test forge kinds are :none (never collide)" do
      for kind <- [:shell, :fake, :custom] do
        assert ReviewIndependence.vendor_of({:forge, kind}, :fast) == :none
      end
    end

    test ":in_process resolves the tier's provider prefix — ollama is determinate" do
      put_aliases!(%{fast: "ollama:nemotron-3-super:cloud"})
      assert ReviewIndependence.vendor_of(:in_process, :fast) == {:provider, "ollama"}
    end

    test ":in_process with a binary tier reads its prefix directly" do
      assert ReviewIndependence.vendor_of(:in_process, "openai:gpt-4.1") ==
               {:provider, "openai"}
    end

    test "an unresolvable alias is :indeterminate (rescued ArgumentError)" do
      assert ReviewIndependence.vendor_of(:in_process, :never_configured_alias) == :indeterminate
      assert ReviewIndependence.vendor_of(:in_process, nil) == :indeterminate
    end

    test "an alias pointing at a TUPLE (non-binary) model spec is :indeterminate" do
      put_aliases!(%{fast: {:openai, "gpt-4.1", []}})
      assert ReviewIndependence.vendor_of(:in_process, :fast) == :indeterminate
    end

    test "anything unrecognized is :indeterminate (total, fail closed)" do
      assert ReviewIndependence.vendor_of(:garbage, :fast) == :indeterminate
      assert ReviewIndependence.vendor_of({:forge, :unknown_kind}, :fast) == :indeterminate
    end
  end

  # ---------------------------------------------------------------------------
  # apply_executor/3 (the dispatch overlay)
  # ---------------------------------------------------------------------------

  describe "apply_executor/3" do
    test "overlays the knob onto the reviewer template (workspace :repo defaulted)" do
      dir = project_with_config!("review:\n  executor: codex\n")
      {:ok, template} = Templates.get("reviewer")

      assert {:ok, bound} =
               ReviewIndependence.apply_executor(template, "reviewer", %{project_dir: dir})

      assert bound.executor == {:forge, :codex}
      assert bound.executor_config == %{workspace: :repo}
      # Everything else untouched.
      assert bound.module == template.module
    end

    test "every other template returns unchanged BEFORE any config read" do
      # A NON-MAP review section would refuse loudly if read — the coder path
      # returning {:ok, _} proves the config is never consulted for it.
      dir = project_with_config!("review: broken\n")
      {:ok, template} = Templates.get("coder")

      assert {:ok, ^template} =
               ReviewIndependence.apply_executor(template, "coder", %{project_dir: dir})
    end

    test "an :agent_templates_override entry for the reviewer beats the knob" do
      dir = project_with_config!("review:\n  executor: codex\n")

      put_override!(%{
        "reviewer" => %{
          module: JidoClaw.Agent.Workers.Reviewer,
          description: "override reviewer",
          model: :fast,
          max_iterations: 1
        }
      })

      {:ok, template} = Templates.get("reviewer")

      assert {:ok, ^template} =
               ReviewIndependence.apply_executor(template, "reviewer", %{project_dir: dir})

      assert template.executor == :in_process
    end

    test "nil / present-nil / blank / missing project_dir dispatches unchanged (no config read)" do
      {:ok, template} = Templates.get("reviewer")

      for context <- [%{}, %{project_dir: nil}, %{project_dir: ""}, nil] do
        assert {:ok, ^template} =
                 ReviewIndependence.apply_executor(template, "reviewer", context)
      end

      assert template.executor == :in_process
    end

    test "an invalid executor_config value fails the overlay closed (the PR-1 validator text)" do
      dir =
        project_with_config!(
          "review:\n  executor: codex\n  executor_config:\n    workspace: sideways\n"
        )

      {:ok, template} = Templates.get("reviewer")

      assert {:error, msg} =
               ReviewIndependence.apply_executor(template, "reviewer", %{project_dir: dir})

      assert msg =~ "workspace"
    end

    test "a malformed independence: fails the overlay closed — dispatch never honors a partial section" do
      # The dispatch seam reads only the binding, but the fail-closed contract
      # covers the WHOLE knob: a typo'd (or present-null) independence must be
      # a step error here too, never an applied executor with the mode ignored.
      for independence_yaml <- ["independence: degrated", "independence:"] do
        dir = project_with_config!("review:\n  executor: codex\n  #{independence_yaml}\n")
        {:ok, template} = Templates.get("reviewer")

        assert {:error, {:invalid_review_config, msg}} =
                 ReviewIndependence.apply_executor(template, "reviewer", %{project_dir: dir})

        assert msg =~ "strict | degraded"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # check_route/2 (the launch invariant)
  # ---------------------------------------------------------------------------

  describe "check_route/2" do
    test "same-vendor pairing is HELD under strict — details.scope is :catalog" do
      attach_telemetry!()
      put_aliases!(%{fast: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n")

      assert {:error, {:review_independence_held, details}} =
               ReviewIndependence.check_route(review_catalog(), dir)

      assert details.scope == :catalog
      assert details.remedy =~ "catalog-level"
      assert details.remedy =~ "not a failure of the requested route"

      assert [violation] = details.violations
      assert violation.stage == "quality-reviewer"
      assert violation.producer == "implementer"
      assert violation.reviewer_provider == "openai"
      assert violation.producer_provider == "openai"

      assert_receive {:ri_telemetry, %{total: 1}, %{outcome: :held}}
    end

    test "cross-vendor pairing passes — provider-identity comparison" do
      put_aliases!(%{fast: "ollama:nemotron-3-super:cloud"})
      dir = project_with_config!("review:\n  executor: codex\n")

      assert :ok = ReviewIndependence.check_route(review_catalog(), dir)
    end

    test "the producer's OWN stage tier is resolved, never the reviewer's" do
      put_aliases!(%{fast: "ollama:nemotron-3-super:cloud", capable: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n")

      # The tiered producer resolves :capable → openai — collision.
      tiered = review_catalog(producer: [model: :capable])

      assert {:error, {:review_independence_held, details}} =
               ReviewIndependence.check_route(tiered, dir)

      assert [%{producer: "implementer", producer_provider: "openai"}] = details.violations

      # The SAME catalog minus the stage tier resolves :fast → ollama — passes.
      assert :ok = ReviewIndependence.check_route(review_catalog(), dir)
    end

    test "degraded mode passes a collision with a warning + telemetry" do
      attach_telemetry!()
      put_aliases!(%{fast: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n  independence: degraded\n")

      log =
        capture_log(fn ->
          assert :ok = ReviewIndependence.check_route(review_catalog(), dir)
        end)

      assert log =~ "degraded independence accepted"
      assert_receive {:ri_telemetry, %{total: 1}, %{outcome: :degraded_pass}}
    end

    test "an :indeterminate producer is a collision — cannot prove independence" do
      # A tuple-spec alias makes the in-process producer's provider unprovable.
      put_aliases!(%{fast: {:openai, "gpt-4.1", []}})
      dir = project_with_config!("review:\n  executor: codex\n")

      assert {:error, {:review_independence_held, details}} =
               ReviewIndependence.check_route(review_catalog(), dir)

      assert [%{producer_provider: :indeterminate}] = details.violations
    end

    test "an in-process or {:forge, :fake} reviewer keeps the invariant INACTIVE" do
      put_aliases!(%{fast: "openai:gpt-4.1"})

      # No knob: the default in-process reviewer never activates the check,
      # even with a same-provider in-process producer.
      assert :ok = ReviewIndependence.check_route(review_catalog(), empty_project!())

      # A :fake reviewer binding (test route) stays inactive too.
      put_override!(%{
        "reviewer" => %{
          module: JidoClaw.Agent.Workers.Reviewer,
          description: "fake-bound reviewer",
          model: :fast,
          executor: {:forge, :fake}
        }
      })

      assert :ok = ReviewIndependence.check_route(review_catalog(), empty_project!())
    end

    test "an optional-input producer (the fixer) collides too" do
      put_aliases!(%{fast: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n")

      assert {:error, {:review_independence_held, details}} =
               ReviewIndependence.check_route(fixer_catalog(), dir)

      producers = Enum.sort(Enum.map(details.violations, & &1.producer))
      assert producers == ["fixer", "implementer"]
    end

    test "an :agent_templates_override reviewer is authoritative — the knob never overlays" do
      put_aliases!(%{fast: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n")

      put_override!(%{
        "reviewer" => %{
          module: JidoClaw.Agent.Workers.Reviewer,
          description: "override reviewer",
          model: :fast,
          max_iterations: 1
        }
      })

      # Override executor is :in_process → invariant inactive → :ok, despite
      # the knob naming codex over an openai producer.
      assert :ok = ReviewIndependence.check_route(review_catalog(), dir)
    end

    test "a malformed review section refuses the launch with the config error" do
      dir = project_with_config!("review:\n  executer: codex\n")

      assert {:error, {:invalid_review_config, _msg}} =
               ReviewIndependence.check_route(review_catalog(), dir)
    end

    test "nil-safety: nil/blank project dirs read no config and pass a default catalog" do
      put_aliases!(%{fast: "openai:gpt-4.1"})

      # A nil project_dir must never reach Config.load (Path.join would
      # crash); the default in-process reviewer keeps the invariant inactive.
      assert :ok = ReviewIndependence.check_route(review_catalog(), nil)
      assert :ok = ReviewIndependence.check_route(review_catalog(), "")
    end

    test "stages without a lens or without a worker unit are ignored" do
      put_aliases!(%{fast: "openai:gpt-4.1"})
      dir = project_with_config!("review:\n  executor: codex\n")

      # A lens-less reviewer-templated stage and a {:verify, _} lens stage
      # are both out of scope.
      catalog = %{
        "post-check" =>
          TestFixtures.stage(
            name: "post-check",
            unit: {:worker_template, "reviewer"},
            task: "no lens",
            routes: ["code"],
            sub: ["code-written"],
            req: ["diff"],
            out: ["report"]
          ),
        "verify" =>
          TestFixtures.stage(
            name: "verify",
            unit: {:verify, "default"},
            lens: "verify",
            routes: ["code"],
            sub: ["code-written"],
            opt: ["diff"],
            out: ["findings"]
          ),
        "implementer" =>
          TestFixtures.stage(
            name: "implementer",
            unit: {:worker_template, "coder"},
            task: "implement",
            routes: ["code"],
            sub: ["request-received"],
            req: ["request"],
            out: ["diff"],
            pub: ["code-written"]
          )
      }

      assert :ok = ReviewIndependence.check_route(catalog, dir)
    end
  end
end
