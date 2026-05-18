defmodule Mix.Tasks.Compile.JidoclawReleasePatches do
  @moduledoc false
  use Mix.Task.Compiler

  @patched_dependency_beams [
    {Anubis.Server.Handlers.Tools, :anubis_mcp},
    {Jido.Shell.Command.Registry, :jido_shell},
    {Jido.Shell.ShellSession, :jido_shell},
    {Jido.Shell.ShellSessionServer, :jido_shell}
  ]

  @impl Mix.Task.Compiler
  def run(_args) do
    if Mix.env() == :prod do
      Enum.each(@patched_dependency_beams, &relocate_patch!/1)
      :ok
    else
      :noop
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

  defp format_file_error(reason), do: reason |> :file.format_error() |> List.to_string()
end
