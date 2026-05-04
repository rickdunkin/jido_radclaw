defmodule Mix.Tasks.Jidoclaw.Migrate.Conversations do
  @moduledoc """
  One-shot migration: copy `.jido/sessions/<tenant>/*.jsonl` rows into
  the v0.6 Postgres-backed `Conversations.Message` table.

  ## Usage

      mix jidoclaw.migrate.conversations [--project DIR] [--dry-run]

  The default `DIR` is the current working directory. The task:

    1. Walks `.jido/sessions/<tenant>/*.jsonl` — `<tenant>` is the
       source of truth from the directory layout. NO defaulting to
       `"default"` — files in unexpected layouts are skipped with a
       warning.
    2. Parses each filename to derive `(kind, external_id)` per the
       v0.6 prefix table (e.g. `discord_<id>` → `(:discord, <id>)`,
       `session_<id>` → `(:repl, session_<id>)`). Unknown shapes get
       `(:imported_legacy, basename_without_ext)`.
    3. Resolves a Workspace via `Workspaces.Resolver.ensure_workspace`
       at the project_dir under the tenant.
    4. Resolves a Session via `Conversations.Resolver.ensure_session`.
    5. Streams the JSONL file in file order, decodes each
       `%{"role", "content", "timestamp"}` line, and calls
       `Conversations.Message.import/1` with an explicit sequence,
       inserted_at, and import_hash. The `unique_import_hash`
       partial identity makes re-runs idempotent.
    6. After all rows for a session: bumps the session's
       `next_sequence` to `max(sequence) + 1` so subsequent live
       appends pick up where the import left off.

  Files are NOT deleted after migration — manual cleanup is the
  operator's responsibility.

  ## Tenant verification

  Each tenant directory's identifier is checked against the
  `Tenant.Manager` ETS table. Unregistered tenants produce a warning
  but do NOT block import — Phase 4 will harden tenant lifecycle.
  """

  @shortdoc "Migrate v0.5.x .jido/sessions/*.jsonl rows into Postgres"

  use Mix.Task

  require Logger

  alias JidoClaw.Conversations.{Message, Resolver, Session}
  alias JidoClaw.Workspaces.Resolver, as: WorkspaceResolver

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [dry_run: :boolean, project: :string])

    project_dir = Keyword.get(opts, :project) || File.cwd!()
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    Mix.shell().info(
      "Migrating .jido/sessions from #{project_dir}#{if dry_run?, do: " (dry-run)", else: ""}"
    )

    sessions_root = Path.join([project_dir, ".jido", "sessions"])

    case File.ls(sessions_root) do
      {:ok, tenant_dirs} ->
        Enum.each(tenant_dirs, fn tenant_id ->
          tenant_path = Path.join(sessions_root, tenant_id)

          if File.dir?(tenant_path) do
            verify_tenant(tenant_id)
            migrate_tenant(tenant_id, tenant_path, project_dir, dry_run?)
          end
        end)

      {:error, :enoent} ->
        Mix.shell().info("No .jido/sessions directory found, skipping")

      {:error, reason} ->
        Mix.shell().error("read .jido/sessions: #{inspect(reason)}")
    end

    :ok
  end

  defp verify_tenant(tenant_id) do
    case JidoClaw.Tenant.Manager.get_tenant(tenant_id) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Mix.shell().info(
          "  WARN: tenant '#{tenant_id}' is not registered; importing anyway (Phase 4 will harden)"
        )
    end
  rescue
    _ ->
      Mix.shell().info(
        "  WARN: Tenant.Manager unreachable; importing tenant '#{tenant_id}' without verification"
      )
  end

  defp migrate_tenant(tenant_id, tenant_path, project_dir, dry_run?) do
    files =
      tenant_path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort()

    Mix.shell().info("Tenant '#{tenant_id}': #{length(files)} sessions")

    Enum.each(files, fn file ->
      migrate_session(tenant_id, Path.join(tenant_path, file), project_dir, dry_run?)
    end)
  end

  defp migrate_session(tenant_id, file_path, project_dir, dry_run?) do
    base = file_path |> Path.basename() |> Path.rootname()
    {kind, external_id} = parse_filename(base)

    Mix.shell().info("  #{base} (#{kind}, #{external_id})")

    if dry_run? do
      lines = file_path |> File.stream!() |> Enum.count()
      Mix.shell().info("    would import #{lines} lines")
      :ok
    else
      do_migrate_session(tenant_id, file_path, project_dir, kind, external_id)
    end
  end

  defp do_migrate_session(tenant_id, file_path, project_dir, kind, external_id) do
    with {:ok, workspace} <-
           WorkspaceResolver.ensure_workspace(tenant_id, project_dir),
         {:ok, session} <-
           Resolver.ensure_session(tenant_id, workspace.id, kind, external_id) do
      max_seq = stream_and_import(session, file_path)

      if max_seq > 0 do
        next = max_seq + 1
        Session.set_next_sequence!(session, next)
        Mix.shell().info("    imported up to sequence=#{max_seq}; next_sequence=#{next}")
      else
        Mix.shell().info("    no rows imported")
      end
    else
      {:error, reason} ->
        Mix.shell().error("    workspace/session resolution failed: #{inspect(reason)}")
    end
  end

  defp stream_and_import(session, file_path) do
    file_path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.reduce(0, fn {line, sequence}, max_seq ->
      case import_line(session, sequence, String.trim(line)) do
        :ok -> max(sequence, max_seq)
        :skip -> max_seq
      end
    end)
  end

  defp import_line(_session, _sequence, ""), do: :skip

  defp import_line(session, sequence, line) do
    case Jason.decode(line) do
      {:ok, %{"role" => role_str, "content" => content, "timestamp" => ts}} ->
        do_import(session, sequence, role_str, content, ts)

      {:ok, _other} ->
        Logger.warning("[migrate] skipping line with unexpected shape: #{line}")
        :skip

      {:error, reason} ->
        Logger.warning("[migrate] JSON decode failed: #{inspect(reason)}")
        :skip
    end
  end

  defp do_import(session, sequence, role_str, content, ts) do
    role = parse_role(role_str)
    inserted_at = DateTime.from_unix!(ts, :millisecond)
    import_hash = compute_hash(session.id, sequence, role, ts, content)

    attrs = %{
      session_id: session.id,
      tenant_id: session.tenant_id,
      role: role,
      sequence: sequence,
      content: content,
      metadata: %{},
      import_hash: import_hash,
      inserted_at: inserted_at
    }

    case Message.import(attrs) do
      {:ok, _} ->
        :ok

      {:error, %Ash.Error.Invalid{} = err} ->
        if duplicate_import_hash?(err) do
          # Idempotent skip — already imported in a previous run.
          :skip
        else
          Logger.warning("[migrate] import failed: #{inspect(err)}")
          :skip
        end

      {:error, reason} ->
        Logger.warning("[migrate] import failed: #{inspect(reason)}")
        :skip
    end
  end

  defp duplicate_import_hash?(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(&inspect/1)
    |> Enum.any?(&String.contains?(&1, "unique_import_hash"))
  end

  defp duplicate_import_hash?(_), do: false

  defp parse_role("user"), do: :user
  defp parse_role("assistant"), do: :assistant
  defp parse_role("system"), do: :system
  defp parse_role(other), do: raise("unknown legacy role: #{inspect(other)}")

  defp compute_hash(session_id, sequence, role, ts, content) do
    payload = "#{session_id}|#{sequence}|#{role}|#{ts}|#{content}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Filename parsing
  # ---------------------------------------------------------------------------
  #
  # The v0.5 writer used these filename prefixes:
  #
  #   discord_<channel_id>     → (:discord, <channel_id>)
  #   telegram_<chat_id>       → (:telegram, <chat_id>)
  #   web_<rpc_id>             → (:web_rpc, <rpc_id>)
  #   cron_<job_id>            → (:cron, <job_id>)
  #   api_<external_id>        → (:api, <external_id>)
  #   mcp_<external_id>        → (:mcp, <external_id>)
  #   session_<timestamp>      → (:repl, session_<timestamp>)  ← REPL self-id
  #   <anything-else>          → (:imported_legacy, <basename>)

  defp parse_filename(base) do
    cond do
      String.starts_with?(base, "discord_") ->
        {:discord, strip_prefix(base, "discord_")}

      String.starts_with?(base, "telegram_") ->
        {:telegram, strip_prefix(base, "telegram_")}

      String.starts_with?(base, "web_") ->
        {:web_rpc, strip_prefix(base, "web_")}

      String.starts_with?(base, "cron_") ->
        {:cron, strip_prefix(base, "cron_")}

      String.starts_with?(base, "api_") ->
        {:api, strip_prefix(base, "api_")}

      String.starts_with?(base, "mcp_") ->
        {:mcp, strip_prefix(base, "mcp_")}

      String.starts_with?(base, "session_") ->
        {:repl, base}

      true ->
        {:imported_legacy, base}
    end
  end

  defp strip_prefix(s, prefix), do: String.replace_prefix(s, prefix, "")
end
