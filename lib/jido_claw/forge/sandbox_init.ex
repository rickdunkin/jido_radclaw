defmodule JidoClaw.Forge.SandboxInit do
  @moduledoc """
  Boot-time task that validates the `sbx` CLI is available and cleans up
  any orphaned Forge sandboxes from previous runs.

  Started in the supervision tree only when the DockerSandbox sprite client
  is configured. Runs once and exits (restart: :temporary).
  """

  use Task, restart: :temporary
  require Logger

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    check_sbx_binary()
    cleanup_orphaned_sandboxes()
  end

  defp check_sbx_binary do
    case System.find_executable("sbx") do
      nil ->
        Logger.error(
          "[Forge.SandboxInit] sbx CLI not found on PATH. " <>
            "Docker Sandbox sprite client will not work. " <>
            "Install Docker Desktop >= 4.40 and run 'sbx login'."
        )

      path ->
        Logger.info("[Forge.SandboxInit] sbx CLI found at #{path}")

        case System.cmd(path, ["version"], stderr_to_stdout: true) do
          {version_output, 0} ->
            Logger.info("[Forge.SandboxInit] #{String.trim(version_output)}")

          {error, _code} ->
            Logger.warning(
              "[Forge.SandboxInit] Could not determine sbx version: #{String.trim(error)}"
            )
        end
    end
  end

  @doc false
  def cleanup_orphaned_sandboxes do
    case System.cmd("sbx", ["ls", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, sandboxes} when is_list(sandboxes) ->
            orphans =
              Enum.filter(sandboxes, fn sb ->
                is_map(sb) and String.starts_with?(Map.get(sb, "name", ""), "forge-")
              end)

            for sb <- orphans do
              name = sb["name"]
              Logger.info("[Forge.SandboxInit] Removing orphaned sandbox: #{name}")
              System.cmd("sbx", ["rm", "--force", name], stderr_to_stdout: true)
            end

            if length(orphans) > 0 do
              Logger.info(
                "[Forge.SandboxInit] Cleaned up #{length(orphans)} orphaned sandbox(es)"
              )
            end

          {:ok, _} ->
            Logger.debug("[Forge.SandboxInit] Unexpected sbx ls output format")

          {:error, _} ->
            Logger.debug("[Forge.SandboxInit] Could not parse sbx ls output")
        end

      {error, _code} ->
        Logger.warning(
          "[Forge.SandboxInit] Could not list sandboxes for cleanup: #{String.trim(error)}"
        )
    end
  end
end
