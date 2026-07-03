defmodule JidoClaw.CLI.Commands.Sessions do
  @moduledoc """
  REPL surface for durable session listing (`/sessions`).

  Lists this workspace's OPEN sessions in two groups so the display matches
  `--continue`'s actual selection set:

    * **CLI resumable** (`:repl` / `:cli_run`), newest first — the top row
      IS what `mix jidoclaw --continue` picks;
    * **Other sessions** (every other kind) — resumable by UUID only, via
      `--resume <uuid>`.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.Commands
  alias JidoClaw.Conversations.Session

  @cli_kinds [:repl, :cli_run]

  @doc "List the workspace's open sessions with resume hints."
  @spec list(map()) :: {:ok, map()}
  def list(state) do
    IO.puts("")
    IO.puts("  \e[1mSessions\e[0m")

    case Commands.session_scope(state) do
      {:ok, tenant_id, workspace_uuid} ->
        print_sessions(tenant_id, workspace_uuid)

      :missing ->
        IO.puts("  \e[2mSession persistence unavailable (degraded boot) — nothing to list.\e[0m")
    end

    IO.puts("")
    {:ok, state}
  end

  defp print_sessions(tenant_id, workspace_uuid) do
    actor = Actor.system(tenant_id)

    case Session.active_for_workspace(workspace_uuid, tenant: tenant_id, actor: actor) do
      {:ok, []} ->
        IO.puts("  \e[2mNo open sessions in this workspace.\e[0m")

      {:ok, sessions} ->
        {cli, other} =
          sessions
          |> Enum.sort_by(& &1.last_active_at, {:desc, DateTime})
          |> Enum.split_with(&(&1.kind in @cli_kinds))

        print_group("CLI resumable (newest first — --continue picks the top row)", cli)
        print_group("Other sessions — resume by UUID only", other)

        IO.puts("")

        IO.puts("  \e[2mResume: mix jidoclaw --resume <uuid> · --continue for most recent\e[0m")

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m  Could not list sessions: #{inspect(reason)}")
    end
  end

  defp print_group(_title, []), do: :ok

  defp print_group(title, sessions) do
    IO.puts("")
    IO.puts("  \e[1m#{title}\e[0m")
    Enum.each(sessions, &print_session/1)
  end

  defp print_session(session) do
    IO.puts(
      "  \e[33m▸\e[0m \e[1m#{session.id}\e[0m  #{session.kind}  \e[2m#{last_active(session)}\e[0m"
    )
  end

  defp last_active(%{last_active_at: %DateTime{} = at}), do: DateTime.to_iso8601(at)
  defp last_active(_session), do: "unknown"
end
