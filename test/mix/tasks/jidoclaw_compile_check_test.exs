defmodule Mix.Tasks.Jidoclaw.CompileCheckTest do
  @moduledoc """
  Fixture rows for the gate's fork self-assert (`assert_exec_fork!/2`) —
  driven against ExUnit tmp lib dirs ONLY, never the live `_build/<env>`
  (precommit's test partitions share one build dir) — plus the diagnostics
  plumbing (captured-map → `Diagnostic` conversion, the allowlist split).
  The self-assert itself runs live at the end of every
  `mix jidoclaw.compile_check` (the operator-approved integration check);
  these rows pin its per-shape behavior at both env owners.
  """

  # async: false — the setup_all fork generation compiles Jido.Exec into
  # this VM (Code.compile_string loads what it compiles); the real fork is
  # restored via DependencyPatches.ensure_loaded!/0 immediately after.
  use ExUnit.Case, async: false

  alias JidoClaw.Core.DependencyPatches
  alias JidoClaw.Core.JidoExecPatch
  alias Mix.Task.Compiler.Diagnostic
  alias Mix.Tasks.Compile.JidoclawReleasePatches
  alias Mix.Tasks.Jidoclaw.CompileCheck

  @project_root Path.expand("../../..", __DIR__)

  setup_all do
    # Generate the fork BEAM once (same fixture technique as
    # jido_exec_patch_test.exs's incremental-build rows); rows copy it into
    # their per-test owner layouts.
    tmp =
      Path.join(System.tmp_dir!(), "compile-check-fork-#{System.unique_integer([:positive])}")

    fork_beam = Path.join(tmp, "Elixir.Jido.Exec.beam")
    source = Path.join(@project_root, JidoExecPatch.upstream_source_path())
    [] = JidoExecPatch.generate!(source, fork_beam)
    DependencyPatches.ensure_loaded!()

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, fork_beam: fork_beam}
  end

  defp place_beam!(lib, app, beam_source) do
    target = Path.join(lib, "#{app}/ebin/Elixir.Jido.Exec.beam")
    File.mkdir_p!(Path.dirname(target))
    File.cp!(beam_source, target)
    target
  end

  defp write_app!(lib, app, modules) do
    path = Path.join(lib, "#{app}/ebin/#{app}.app")
    File.mkdir_p!(Path.dirname(path))
    spec = {:application, app, [vsn: ~c"0.0.0", modules: modules]}
    File.write!(path, :io_lib.format(~c"~p.~n", [spec]))
    path
  end

  defp upstream_beam do
    Application.app_dir(:jido_action, "ebin/Elixir.Jido.Exec.beam")
  end

  describe "assert_exec_fork!/2 — non-prod owner (the app ebin)" do
    @describetag :tmp_dir

    test "a marker-current BEAM + a jido_claw.app listing Jido.Exec passes", ctx do
      place_beam!(ctx.tmp_dir, :jido_claw, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_claw, [Jido.Exec, JidoClaw.Application])

      assert :ok = CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
    end

    test "a missing fork BEAM raises, naming the writer task", ctx do
      write_app!(ctx.tmp_dir, :jido_claw, [Jido.Exec])

      assert_raise Mix.Error, ~r/compile\.jidoclaw_release_patches/, fn ->
        CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
      end
    end

    test "the UPSTREAM dep BEAM at the target raises (gate-leaves-upstream-Exec)", ctx do
      place_beam!(ctx.tmp_dir, :jido_claw, upstream_beam())
      write_app!(ctx.tmp_dir, :jido_claw, [Jido.Exec])

      assert_raise Mix.Error, ~r/missing or stale/, fn ->
        CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
      end
    end

    test "a current BEAM with jido_claw.app MISSING Jido.Exec raises (ordering pin)", ctx do
      # A fork written AFTER compile.app would pass the marker check but
      # leave the .app modules scan stale — the .app membership is what
      # pins the compiler rerun BEFORE compile.app.
      place_beam!(ctx.tmp_dir, :jido_claw, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_claw, [JidoClaw.Application])

      assert_raise Mix.Error, ~r/does not list Jido\.Exec/, fn ->
        CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
      end
    end

    test "a missing or unparseable jido_claw.app raises", ctx do
      place_beam!(ctx.tmp_dir, :jido_claw, ctx.fork_beam)

      assert_raise Mix.Error, ~r/cannot read/, fn ->
        CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
      end

      app = Path.join(ctx.tmp_dir, "jido_claw/ebin/jido_claw.app")
      File.mkdir_p!(Path.dirname(app))
      File.write!(app, "{not valid erlang")

      assert_raise Mix.Error, ~r/cannot read/, fn ->
        CompileCheck.assert_exec_fork!(:test, ctx.tmp_dir)
      end
    end
  end

  describe "assert_exec_fork!/2 — :prod owner (the relocated jido_action ebin)" do
    @describetag :tmp_dir

    test "the post-relocation shape passes: dep-side current BEAM, no app-side copy", ctx do
      place_beam!(ctx.tmp_dir, :jido_action, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_action, [Jido.Exec, Jido.Action])
      write_app!(ctx.tmp_dir, :jido_claw, [JidoClaw.Application])

      assert :ok = CompileCheck.assert_exec_fork!(:prod, ctx.tmp_dir)
    end

    test "an upstream (unmarked) BEAM at the dep location raises", ctx do
      place_beam!(ctx.tmp_dir, :jido_action, upstream_beam())
      write_app!(ctx.tmp_dir, :jido_action, [Jido.Exec])
      write_app!(ctx.tmp_dir, :jido_claw, [])

      assert_raise Mix.Error, ~r/missing or stale/, fn ->
        CompileCheck.assert_exec_fork!(:prod, ctx.tmp_dir)
      end
    end

    test "an app-side-only current BEAM raises — relocation did not run", ctx do
      place_beam!(ctx.tmp_dir, :jido_claw, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_action, [Jido.Exec])
      write_app!(ctx.tmp_dir, :jido_claw, [Jido.Exec])

      assert_raise Mix.Error, ~r/missing or stale/, fn ->
        CompileCheck.assert_exec_fork!(:prod, ctx.tmp_dir)
      end
    end

    test "BOTH owner BEAMs present raises (single-owner pin vs move→copy regression)", ctx do
      place_beam!(ctx.tmp_dir, :jido_action, ctx.fork_beam)
      place_beam!(ctx.tmp_dir, :jido_claw, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_action, [Jido.Exec])
      write_app!(ctx.tmp_dir, :jido_claw, [JidoClaw.Application])

      assert_raise Mix.Error, ~r/TWO Jido\.Exec owners/, fn ->
        CompileCheck.assert_exec_fork!(:prod, ctx.tmp_dir)
      end
    end

    test "a jido_claw.app still listing Jido.Exec raises (single-owner pin, .app side)", ctx do
      place_beam!(ctx.tmp_dir, :jido_action, ctx.fork_beam)
      write_app!(ctx.tmp_dir, :jido_action, [Jido.Exec])
      write_app!(ctx.tmp_dir, :jido_claw, [Jido.Exec])

      assert_raise Mix.Error, ~r/still lists Jido\.Exec/, fn ->
        CompileCheck.assert_exec_fork!(:prod, ctx.tmp_dir)
      end
    end
  end

  describe "diagnostics plumbing" do
    test "a captured map converts to a well-formed Diagnostic struct" do
      captured = %{
        severity: :warning,
        message: ~s(variable "unused" is unused),
        position: {12, 5},
        file: "/abs/lib/jido_action/exec.ex",
        stacktrace: [],
        source: nil,
        span: nil
      }

      diagnostic = JidoclawReleasePatches.to_compiler_diagnostic(captured)

      assert %Diagnostic{} = diagnostic
      assert diagnostic.compiler_name == "jidoclaw_release_patches"
      assert diagnostic.severity == :warning
      assert diagnostic.file == "/abs/lib/jido_action/exec.ex"
      assert diagnostic.message =~ "unused"
      assert diagnostic.position == {12, 5}
    end

    test "split_diagnostics/1 blocks a warning under the (deliberately empty) allowlist" do
      warning =
        JidoclawReleasePatches.to_compiler_diagnostic(%{
          severity: :warning,
          message: "synthetic warning",
          position: 3,
          file: "/abs/lib/jido_action/exec.ex"
        })

      assert {[], [^warning]} = CompileCheck.split_diagnostics([warning])
    end
  end
end
