defmodule JidoClaw.Core.DependencyPatches do
  @moduledoc false

  @patched_modules [
    {Anubis.Server.Handlers.Tools, :anubis_mcp},
    {Jido.MCP.Transport.STDIO, :jido_mcp},
    {Jido.Shell.Command.Registry, :jido_shell},
    {Jido.Shell.ShellSession, :jido_shell},
    {Jido.Shell.ShellSessionServer, :jido_shell}
  ]

  @doc """
  Force-load JidoClaw's patched dependency modules from this app's ebin.

  The project intentionally carries a small number of duplicate module
  definitions while waiting on upstream dependency fixes. Code-path order can
  otherwise load the dependency BEAM first in fresh Mix processes, which makes
  the patch depend on test ordering.
  """
  @spec ensure_loaded!() :: :ok
  def ensure_loaded! do
    Enum.each(@patched_modules, fn {module, dependency_app} ->
      module
      |> candidate_beam_base_paths(dependency_app)
      |> load_module!(module)
    end)

    :ok
  end

  defp jido_claw_ebin_dir! do
    case :code.which(JidoClaw.Application) do
      path when is_list(path) ->
        path
        |> List.to_string()
        |> Path.dirname()

      other ->
        raise "cannot locate jido_claw ebin directory: #{inspect(other)}"
    end
  end

  defp beam_base_path(module, ebin_dir) do
    Path.join(ebin_dir, Atom.to_string(module))
  end

  defp candidate_beam_base_paths(module, dependency_app) do
    Enum.reject(
      [
        beam_base_path(module, jido_claw_ebin_dir!()),
        dependency_beam_base_path(module, dependency_app)
      ],
      &is_nil/1
    )
  end

  defp dependency_beam_base_path(module, dependency_app) do
    dependency_app
    |> Application.app_dir("ebin")
    |> then(&beam_base_path(module, &1))
  rescue
    ArgumentError -> nil
  end

  defp load_module!(candidate_base_paths, module) do
    beam_base_path =
      Enum.find(candidate_base_paths, fn path ->
        File.exists?(path <> ".beam")
      end)

    unless beam_base_path do
      raise "patched BEAM for #{inspect(module)} not found in #{inspect(candidate_base_paths)}"
    end

    _ = :code.purge(module)
    _ = :code.delete(module)

    case :code.load_abs(String.to_charlist(beam_base_path)) do
      {:module, ^module} ->
        :ok

      {:error, :nofile} ->
        raise "patched BEAM for #{inspect(module)} not found at #{beam_base_path}.beam"

      {:error, reason} ->
        raise "failed to load patched #{inspect(module)} from #{beam_base_path}.beam: #{inspect(reason)}"
    end
  end
end
