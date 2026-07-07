defmodule JidoClaw.Forge.Runners.FileSync do
  @moduledoc """
  Host→sandbox single-file sync shared by the CLI runners
  (`ClaudeCode`, `Codex`): read the file on the HOST, pipe it through
  `Sandbox.exec` base64-encoded, and re-tighten the auth file's mode.

  Lives with the runners rather than `Forge.Sandbox` because the
  host-side `File.read`, the skip-on-unreadable policy, and the chmod
  posture are runner config-sync concerns — `Forge.Sandbox` is a pure
  transport facade.
  """

  alias JidoClaw.Forge.Sandbox

  require Logger

  @doc """
  Sync one host file into the sandbox. An unreadable host file is
  logged under `[label]` and skipped, never an error. `echo > dest`
  uses the process umask, so a `dest` named `auth_file` (mode 600 on
  the host) is re-chmodded to preserve that posture in the sandbox
  copy.
  """
  @spec sync_file(term(), Path.t(), String.t(), String.t(), String.t()) :: :ok
  def sync_file(client, source, dest, auth_file, label) do
    case File.read(source) do
      {:ok, content} ->
        write_content(client, dest, content)

        if Path.basename(dest) == auth_file,
          do: Sandbox.exec(client, "chmod 600 #{dest}", [])

        :ok

      {:error, reason} ->
        Logger.debug("[#{label}] Skipping #{source}: #{reason}")
        :ok
    end
  end

  @doc """
  Write in-memory content to a sandbox path through the same exec-based
  base64 transport `sync_file/5` uses. This is the write that actually
  LANDS on HostShell — `Sandbox.write_file/3` jails absolute paths there,
  so a runner-generated file (e.g. the executor's minimal `settings.json`)
  must go through exec, never `write_file` (PR-2 review finding P1b).
  """
  @spec write_content(term(), String.t(), binary()) :: :ok
  def write_content(client, dest, content) when is_binary(content) do
    encoded = Base.encode64(content)
    Sandbox.exec(client, "echo '#{encoded}' | base64 -d > #{dest}", [])
    :ok
  end
end
