defmodule JidoClaw.Forge.SandboxInit do
  @moduledoc """
  Boot-time task that validates the `sbx` CLI is available and cleans up
  any orphaned Forge sandboxes from previous runs.

  Started in the supervision tree only when the Docker sandbox
  is configured. Runs once and exits (restart: :temporary).
  """

  use Task, restart: :temporary
  require Logger

  alias JidoClaw.Security.Redaction.Env

  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  @spec run() :: term()
  def run do
    check_sbx_binary()
    cleanup_orphaned_sandboxes()
    # Filesystem-only — must run even when the sbx CLI is absent (the
    # sandbox cleanup above bails out in that case). Workspace dirs hold
    # `.forge_env` secret files, and `Sandbox.destroy` (the only other
    # cleanup) never runs when a Harness crashes.
    reap_orphaned_workspace_dirs(workspace_base())
  end

  defp check_sbx_binary do
    case System.find_executable("sbx") do
      nil ->
        Logger.error(
          "[Forge.SandboxInit] sbx CLI not found on PATH. " <>
            "Docker Sandbox will not work. " <>
            "Install Docker Desktop >= 4.40 and run 'sbx login'."
        )

      path ->
        Logger.info("[Forge.SandboxInit] sbx CLI found at #{path}")

        case System.cmd(path, ["version"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
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
  @spec cleanup_orphaned_sandboxes() :: term()
  def cleanup_orphaned_sandboxes do
    case System.find_executable("sbx") do
      nil ->
        Logger.debug("[Forge.SandboxInit] sbx CLI not found; skipping orphan cleanup")

      _path ->
        do_cleanup_orphaned_sandboxes()
    end
  end

  defp do_cleanup_orphaned_sandboxes do
    case System.cmd("sbx", ["ls", "--json"], stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
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

              System.cmd("sbx", ["rm", "--force", name],
                stderr_to_stdout: true,
                env: Env.scrubbed_cmd_env()
              )
            end

            if orphans != [] do
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

  @doc """
  Remove orphaned `forge-*` workspace dirs under `base` (they hold
  `.forge_env` secret files; a crashed Harness never reaches the
  `Sandbox.destroy` cleanup). Takes the base path so tests can exercise
  it against a tmp dir.

  The base itself is lstat-guarded first: `File.ls` would follow a
  symlinked base, and the default base lives under `/tmp`. Entries are
  reaped only when the basename says `forge-*` AND lstat says real
  directory — symlink entries are skipped entirely, never followed.
  """
  @spec reap_orphaned_workspace_dirs(String.t()) :: :ok
  def reap_orphaned_workspace_dirs(base) do
    case File.lstat(base) do
      {:ok, %File.Stat{type: :directory}} ->
        reaped =
          base
          |> list_workspace_entries()
          |> Enum.filter(&orphaned_workspace_dir?(base, &1))

        Enum.each(reaped, fn entry -> File.rm_rf(Path.join(base, entry)) end)

        if reaped != [] do
          Logger.info(
            "[Forge.SandboxInit] Reaped #{length(reaped)} orphaned workspace dir(s) under #{base}"
          )
        end

        :ok

      other ->
        Logger.debug(
          "[Forge.SandboxInit] Skipping workspace reap; #{base} is not a directory: #{inspect(other)}"
        )

        :ok
    end
  end

  defp list_workspace_entries(base) do
    case File.ls(base) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  defp orphaned_workspace_dir?(base, entry) do
    String.starts_with?(entry, "forge-") and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(base, entry)))
  end

  # Mirrors JidoClaw.Forge.Sandbox.Docker.workspace_base/0 — keep the
  # two reads identical so the reaper sweeps where create writes.
  defp workspace_base do
    :jido_claw
    |> Application.get_env(:forge_docker_sandbox, [])
    |> Keyword.get(:workspace_base, "/tmp/jidoclaw_forge")
  end
end
