defmodule Mix.Tasks.Jidoclaw.CompileCheck do
  @shortdoc "Strict compile gate that tolerates an explicit allowlist of known warnings"
  @moduledoc """
  Like `mix compile --warnings-as-errors`, but tolerates an explicit, documented
  allowlist of known warnings so the `precommit` / CI gate is not permanently red
  on Elixir 1.20+ (whose set-theoretic type checker flags upstream-generated and
  intentional-scaffolding code we cannot cleanly fix).

  Force-recompiles the app's Elixir sources — `--return-errors` only surfaces
  diagnostics for files compiled *this* run, so a force is required to re-check
  unchanged files — then fails on any error, or any warning not in `@allowlist`.

  Because the gate hand-sequences compile tasks (so mix.exs `compilers/0`
  ordering never applies here), it must also rerun
  `compile.jidoclaw_release_patches` — the generated `Jido.Exec` fork's only
  writer — between `compile.elixir` and `compile.app`, run the fork compile's
  own diagnostics through the same allowlist split, and self-assert the fork
  artifact at the end (`assert_exec_fork!/2`). Without that, the gate's
  `clean` would leave the build serving upstream `Jido.Exec` until the next
  full `mix compile`.

  Wire it into `precommit` in place of `compile --warnings-as-errors`.

  ## Maintaining the allowlist

  Each entry is `{path_suffix, :file | message_substring}`: a diagnostic is
  tolerated when its file ends with `path_suffix` and either the entry is `:file`
  (tolerate any warning in that file — only safe for modules whose body is
  entirely macro-generated) or its message contains `message_substring`. Keep
  this list short, justify every entry, and re-check it on every dep bump /
  Elixir upgrade. See AGENTS.md "Known limitations".
  """
  use Mix.Task

  alias JidoClaw.Core.JidoExecPatch

  # Empty by design: there are currently no tolerated warnings. Add an entry only
  # when a warning is genuinely unavoidable (upstream-generated code or
  # intentional scaffolding), justified inline, and re-checked on every dep bump /
  # Elixir upgrade. See AGENTS.md "Known limitations".
  @allowlist []

  @impl Mix.Task
  def run(_args) do
    alias Mix.Task

    # Clean the app build, then recompile its Elixir sources fresh. A clean
    # recompile (rather than `--force`) surfaces ALL warnings, not just those
    # from changed files, AND runs before protocol consolidation — so it avoids
    # the spurious "protocol already consolidated" warnings that a `--force`
    # recompile triggers in :test/:prod (where consolidation is enabled). Deps
    # are left intact (`clean` only cleans this project).
    Task.rerun("clean", [])

    {_status, diagnostics} =
      Task.rerun("compile.elixir", ["--return-errors"])

    {tolerated, blocking} = split_diagnostics(diagnostics)
    report_tolerated(tolerated)

    # Fail BEFORE the artifact tasks below: with compile errors the
    # JidoExecPatch beam may not exist, and the patch compiler would raise
    # `Code.ensure_loaded!` noise INSTEAD of the real diagnostics list.
    # Skipping the artifact restoration on a failing gate is safe —
    # precommit halts, no later same-session tasks run.
    raise_on_blocking!(blocking)

    # `clean` removed `_build/<env>/lib/<app>` (including the `priv`/`include`
    # symlinks), and `compile.elixir` rebuilds only `ebin` — not the app
    # structure. Restore the symlinks so later **same-session** `precommit`
    # steps (notably `test`, which reads `:code.priv_dir/1`) still find `priv`.
    # A fresh `mix` session rebuilds the structure on its own; the single
    # `mix precommit` session does not, because Mix only builds it once per run.
    Mix.Project.build_structure()

    # This compiler is the generated `Jido.Exec` fork's only writer: `clean`
    # removed the app-side fork BEAM and `compile.elixir` never runs custom
    # compilers, so skipping it here leaves the build serving upstream
    # `Jido.Exec`. It must precede `compile.app`, whose `:modules` list is an
    # ebin beam scan. Its diagnostics — the fork's own `Code.compile_string`
    # warnings — go through the SAME allowlist split: the generated module
    # must not bypass the strict gate.
    {_patch_status, patch_diagnostics} = Task.rerun("compile.jidoclaw_release_patches", [])

    {patch_tolerated, patch_blocking} = split_diagnostics(patch_diagnostics)
    report_tolerated(patch_tolerated)
    raise_on_blocking!(patch_blocking)

    # Same class of same-session artifact: `clean` also removed
    # `ebin/<app>.app`, which `compile.elixir` never regenerates (that is
    # `compile.app`'s job). Later same-session steps that
    # `Application.load/1` the project (`jidoclaw.jido_md.check` reads the
    # app vsn) would otherwise see a blank spec — but ONLY when the build
    # was already current at entry, since a stale entry triggers a full
    # regular compile that loads the app first (a build-state-dependent
    # gate flake).
    Task.rerun("compile.app", [])

    assert_exec_fork!()

    Mix.shell().info(
      "[compile_check] OK — #{length(tolerated) + length(patch_tolerated)} tolerated, 0 blocking"
    )

    :ok
  end

  @doc """
  Split diagnostics into `{tolerated, blocking}` under `@allowlist`. Public
  so the allowlist policy is unit-testable without running the gate; `run/1`
  routes BOTH diagnostic sources (compile.elixir and the release-patches
  compiler) through this one split.
  """
  @spec split_diagnostics([map()]) :: {[map()], [map()]}
  def split_diagnostics(diagnostics), do: Enum.split_with(diagnostics, &allowed?/1)

  @doc """
  Assert the generated `Jido.Exec` fork survived the gate's hand-run compile
  sequence, at the ENV'S owner. Non-prod (precommit's `:test`, bare dev):
  the app-ebin BEAM must be marker-current AND `jido_claw.app` must list
  `Jido.Exec` (the ordering pin — a fork written after `compile.app` would
  pass the marker check but leave a stale `.app`). `:prod`: the
  release-patches compiler RELOCATES the BEAM into the `jido_action` ebin,
  so the relocated copy must be marker-current, `jido_action.app` must list
  the module, and the single-owner invariant holds — no lingering app-side
  BEAM, no `Jido.Exec` in `jido_claw.app` (a move→copy relocation regression
  would restore code-path-order-dependent module loading). Raises via
  `Mix.raise` on any violation.
  """
  @spec assert_exec_fork!(atom(), Path.t()) :: :ok
  def assert_exec_fork!(:prod, build_lib) do
    app_beam = Path.join(build_lib, "jido_claw/ebin/Elixir.Jido.Exec.beam")

    assert_fork_beam!(Path.join(build_lib, "jido_action/ebin/Elixir.Jido.Exec.beam"))
    assert_app_modules!(Path.join(build_lib, "jido_action/ebin/jido_action.app"), :include)

    if File.exists?(app_beam) do
      Mix.raise(
        "compile_check: prod relocation left TWO Jido.Exec owners — the app-side " <>
          "#{app_beam} must be absent after compile.jidoclaw_release_patches moves " <>
          "the fork into the jido_action ebin (single-owner invariant)."
      )
    end

    assert_app_modules!(Path.join(build_lib, "jido_claw/ebin/jido_claw.app"), :exclude)
  end

  def assert_exec_fork!(_dev_or_test, build_lib) do
    assert_fork_beam!(Path.join(build_lib, "jido_claw/ebin/Elixir.Jido.Exec.beam"))
    assert_app_modules!(Path.join(build_lib, "jido_claw/ebin/jido_claw.app"), :include)
  end

  defp assert_exec_fork! do
    assert_exec_fork!(Mix.env(), Path.join(Mix.Project.build_path(), "lib"))
  end

  defp assert_fork_beam!(beam_path) do
    unless JidoExecPatch.patched_beam_current?(beam_path) do
      Mix.raise(
        "compile_check: the generated Jido.Exec fork is missing or stale at " <>
          "#{beam_path} after the gate's clean → compile.elixir → " <>
          "compile.jidoclaw_release_patches → compile.app sequence — the " <>
          "compile.jidoclaw_release_patches rerun (the fork's only writer) " <>
          "must regenerate it before compile.app."
      )
    end

    :ok
  end

  defp assert_app_modules!(app_file, expectation) do
    modules =
      case :file.consult(String.to_charlist(app_file)) do
        {:ok, [{:application, _app, spec}]} ->
          Keyword.get(spec, :modules, [])

        other ->
          Mix.raise(
            "compile_check: cannot read #{app_file} (#{inspect(other)}) — " <>
              "compile.app must regenerate it after compile.jidoclaw_release_patches."
          )
      end

    case {expectation, Jido.Exec in modules} do
      {:include, true} ->
        :ok

      {:exclude, false} ->
        :ok

      {:include, false} ->
        Mix.raise(
          "compile_check: #{app_file} does not list Jido.Exec — compile.app scans " <>
            "the ebin, so the compile.jidoclaw_release_patches rerun must have " <>
            "written the fork BEAM BEFORE compile.app (ordering pin)."
        )

      {:exclude, true} ->
        Mix.raise(
          "compile_check: #{app_file} still lists Jido.Exec after prod relocation — " <>
            "compile.jidoclaw_release_patches must MOVE (not copy) the fork out of " <>
            "the app ebin before compile.app (single-owner invariant)."
        )
    end
  end

  defp report_tolerated(tolerated) do
    for d <- tolerated do
      Mix.shell().info("[compile_check] tolerated #{relative(d.file)}: #{first_line(d.message)}")
    end

    :ok
  end

  defp raise_on_blocking!([]), do: :ok

  defp raise_on_blocking!(blocking) do
    for d <- blocking do
      Mix.shell().error(
        "[compile_check] #{d.severity} #{relative(d.file)}:#{line(d.position)}: #{first_line(d.message)}"
      )
    end

    Mix.raise(
      "compile_check failed: #{length(blocking)} non-allowlisted diagnostic(s). " <>
        "Fix them, or — only if genuinely unavoidable — add to @allowlist in " <>
        "lib/mix/tasks/jidoclaw.compile_check.ex."
    )
  end

  defp allowed?(%{severity: :warning, file: file, message: message}) when is_binary(file) do
    msg = to_string(message)

    Enum.any?(@allowlist, fn
      {suffix, :file} -> String.ends_with?(file, suffix)
      {suffix, substr} -> String.ends_with?(file, suffix) and String.contains?(msg, substr)
    end)
  end

  defp allowed?(_), do: false

  defp relative(file) when is_binary(file), do: Path.relative_to_cwd(file)
  defp relative(other), do: inspect(other)

  defp line({l, _col}), do: l
  defp line(l) when is_integer(l), do: l
  defp line(_), do: 0

  defp first_line(message) do
    message
    |> to_string()
    |> String.split("\n", parts: 2)
    |> hd()
  end
end
