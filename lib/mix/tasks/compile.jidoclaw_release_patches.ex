defmodule Mix.Tasks.Compile.JidoclawReleasePatches do
  @moduledoc false
  use Mix.Task.Compiler

  alias JidoClaw.Core.DependencyPatches
  alias JidoClaw.Core.JidoExecPatch
  alias Mix.Task.Compiler.Diagnostic

  @doc """
  The `{module, dependency_app}` beams to relocate, read from the SINGLE
  source of truth (`JidoClaw.Core.DependencyPatches.patched_modules/0`) so the
  release-relocation list can never drift from the boot force-load list.

  Compile ordering is safe: `compilers/0` in mix.exs inserts
  `:jidoclaw_release_patches` AFTER `:elixir`, so `DependencyPatches` is already
  compiled when this task runs; `Code.ensure_loaded!/1` is a belt-and-suspenders
  guard.
  """
  @spec patched_beams() :: [{module(), atom()}]
  def patched_beams do
    Code.ensure_loaded!(DependencyPatches)
    DependencyPatches.patched_modules()
  end

  @impl Mix.Task.Compiler
  def run(_args) do
    {fork_status, diagnostics} = ensure_exec_fork!()

    if Mix.env() == :prod do
      Enum.each(patched_beams(), &relocate_patch!/1)
      {:ok, diagnostics}
    else
      {fork_status, diagnostics}
    end
  end

  @doc """
  Convert a `Code.with_diagnostics/2` captured map into the
  `Mix.Task.Compiler.Diagnostic` struct the compiler-task return carries —
  the shape `jidoclaw.compile_check` runs through its strict allowlist
  split, so a warning emitted by the GENERATED fork module cannot bypass
  the gate.
  """
  @spec to_compiler_diagnostic(map()) :: Diagnostic.t()
  def to_compiler_diagnostic(%{} = captured) do
    %Diagnostic{
      compiler_name: "jidoclaw_release_patches",
      file: Map.get(captured, :file),
      source: Map.get(captured, :source),
      severity: Map.get(captured, :severity, :warning),
      message: Map.get(captured, :message, ""),
      position: Map.get(captured, :position, 0),
      stacktrace: Map.get(captured, :stacktrace, []),
      span: Map.get(captured, :span)
    }
  end

  # Durable incremental-build owner for the GENERATED Jido.Exec fork
  # (lib/jido_claw/core/jido_exec_patch.ex): runs on EVERY compile in EVERY
  # env, verifying the app-side BEAM carries the persisted patch marker with
  # the CURRENT pins (upstream sha + patch revision) and regenerating it
  # otherwise. Without this, a deps rebuild could restore the upstream
  # target after prod relocation removed the app-side BEAM — and
  # relocate_patch!/1 deliberately accepts an existing target — or a hunk
  # edit at an unchanged jido_action version could keep serving an old fork
  # BEAM. Regenerating into the app ebin ALSO means prod relocation always
  # has a fresh, verified source and never falls into its
  # accept-existing-target arm for this module. A regeneration returns the
  # fork compile's captured diagnostics (converted + shell-printed here —
  # `Code.with_diagnostics/2` captures INSTEAD of printing, so a plain
  # `mix compile` must keep them visible).
  defp ensure_exec_fork! do
    Code.ensure_loaded!(JidoExecPatch)

    case JidoExecPatch.verify_or_regenerate!(
           JidoExecPatch.upstream_source_path(),
           jido_claw_beam_path(Jido.Exec)
         ) do
      :current ->
        {:noop, []}

      {:generated, captured} ->
        diagnostics = Enum.map(captured, &to_compiler_diagnostic/1)
        Enum.each(diagnostics, &print_diagnostic/1)
        {:ok, diagnostics}
    end
  end

  defp print_diagnostic(diagnostic) do
    text =
      "#{diagnostic.severity} (Jido.Exec fork compile): #{diagnostic.message} " <>
        "(#{diagnostic.file}:#{inspect(diagnostic.position)})"

    case diagnostic.severity do
      :warning -> Mix.shell().info(text)
      _error_or_other -> Mix.shell().error(text)
    end
  end

  defp relocate_patch!({module, app}) do
    source = jido_claw_beam_path(module)
    target = dependency_beam_path(app, module)

    cond do
      File.exists?(source) ->
        replace_beam!(source, target)

      File.exists?(target) ->
        :ok

      true ->
        Mix.raise("patched BEAM for #{inspect(module)} not found at #{source} or #{target}")
    end
  end

  defp replace_beam!(source, target) do
    :ok = remove_beam(target)
    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    :ok = remove_beam(source)
  end

  defp remove_beam(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Mix.raise("failed to remove #{path}: #{format_file_error(reason)}")
    end
  end

  defp jido_claw_beam_path(module), do: build_beam_path(:jido_claw, module)
  defp dependency_beam_path(app, module), do: build_beam_path(app, module)

  defp build_beam_path(app, module) do
    Path.join([
      Mix.Project.build_path(),
      "lib",
      Atom.to_string(app),
      "ebin",
      Atom.to_string(module) <> ".beam"
    ])
  end

  defp format_file_error(reason) do
    reason
    |> :file.format_error()
    |> List.to_string()
  end
end
