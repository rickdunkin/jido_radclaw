defmodule Mix.Tasks.Jidoclaw.Migrate.Memory do
  @moduledoc """
  One-shot migration: copy v0.5.x `.jido/memory.json` rows into the
  v0.6.3 Postgres-backed Memory corpus.

  ## Usage

      mix jidoclaw.migrate.memory [--dry-run] [--project DIR]

  The default `DIR` is the current working directory. The task:

    1. Resolves a Workspace via
       `JidoClaw.Workspaces.Resolver.ensure_workspace/3` (`tenant_id:
       "default"`, `path: DIR`).
    2. Reads `DIR/.jido/memory.json` (if present) and inserts each
       entry via `Memory.Fact.import_legacy/1` with
       `source: :imported_legacy`. Idempotent — entries whose
       `import_hash = SHA-256(workspace_id || label || content ||
       inserted_at_ms)` already exists in Postgres are skipped.
    3. With `--dry-run`, prints the plan without writing.

  Embeddings honor `Workspace.embedding_policy` (default `:disabled`
  per Phase 0); migrated Facts stay `embedding_status: :disabled`
  until the user explicitly flips the policy.

  Block / Episode / Link tiers have no v0.5.x equivalent and are
  skipped silently — the legacy file knows nothing about them.
  """

  @shortdoc "Migrate v0.5.x .jido/memory.json into Postgres-backed Memory"

  use Mix.Task

  require Logger

  alias JidoClaw.Memory.Fact
  alias JidoClaw.Security.Redaction.Memory, as: MemoryRedaction
  alias JidoClaw.Workspaces.{Resolver, Workspace}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [dry_run: :boolean, project: :string])

    # `Resolver.ensure_workspace/3` stores `Path.expand(project_dir)`,
    # so the dry-run lookup must compare against the same absolute
    # path. Expanding once up front keeps both code paths consistent
    # for relative inputs like `--project .`.
    project_dir = Path.expand(Keyword.get(opts, :project) || File.cwd!())
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    Mix.shell().info("Migrating .jido/memory.json from #{project_dir}")

    if dry_run?, do: Mix.shell().info("(dry-run mode — nothing will be written)")

    case resolve_workspace(project_dir, dry_run?) do
      {:ok, workspace} ->
        Mix.shell().info("workspace_uuid: #{workspace.id} tenant_id: #{workspace.tenant_id}")
        run_migration(project_dir, workspace, dry_run?)

      :would_create ->
        Mix.shell().info(
          "workspace: not present — would be created at #{project_dir} (tenant_id: default)"
        )

        run_migration(project_dir, nil, dry_run?)
    end

    :ok
  end

  # Read-only lookup in dry-run; mutating ensure in normal mode. The
  # dry-run side never calls `Resolver.ensure_workspace/3`, which
  # upserts on every invocation. `project_dir` MUST already be
  # absolute — `run/1` expands it before either branch runs so the
  # dry-run lookup compares apples to apples with the
  # `Resolver`-stored row.
  defp resolve_workspace(project_dir, true = _dry_run?) do
    case Workspace.by_path(nil, project_dir, tenant: "default", authorize?: false) do
      {:ok, ws} when not is_nil(ws) -> {:ok, ws}
      _ -> :would_create
    end
  rescue
    _ -> :would_create
  end

  defp resolve_workspace(project_dir, false) do
    {:ok, _ws} = Resolver.ensure_workspace("default", project_dir)
  end

  defp run_migration(project_dir, workspace, dry_run?) do
    %{inserted: inserted, skipped: skipped, failed: failed} =
      migrate_memory(project_dir, workspace, dry_run?)

    Mix.shell().info("\nMigration complete:")

    label_prefix = if dry_run?, do: "would insert", else: "inserted"

    skipped_label =
      if dry_run?, do: "would skip (already present)", else: "skipped (already present)"

    Mix.shell().info("  facts #{label_prefix}: #{inserted}")
    Mix.shell().info("  facts #{skipped_label}: #{skipped}")

    if failed > 0 do
      failed_label = if dry_run?, do: "would fail", else: "failed"
      Mix.shell().info("  facts #{failed_label}: #{failed}")
    end
  end

  defp migrate_memory(project_dir, workspace, dry_run?) do
    path = Path.join([project_dir, ".jido", "memory.json"])

    case read_entries(path) do
      {:ok, entries} ->
        Mix.shell().info("memory.json: #{length(entries)} entries")
        migrate_entries(entries, workspace, dry_run?)

      :empty ->
        %{inserted: 0, skipped: 0, failed: 0}
    end
  end

  defp read_entries(path) do
    case File.read(path) do
      {:ok, body} ->
        decode_entries(body)

      {:error, :enoent} ->
        Mix.shell().info("memory.json: not present, skipping")
        :empty

      {:error, reason} ->
        Mix.shell().info("memory.json: read error (#{inspect(reason)})")
        :empty
    end
  end

  defp decode_entries(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        entries =
          map
          |> Enum.map(fn {_id, entry} -> entry end)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        Mix.shell().info("memory.json: invalid JSON (#{inspect(reason)})")
        :empty
    end
  end

  # Workspace would be created — every entry's import_hash is unique
  # within a fresh workspace_id, so all entries would be inserted on a
  # real run.
  defp migrate_entries(entries, nil, true) do
    %{inserted: length(entries), skipped: 0, failed: 0}
  end

  # Workspace already exists. Compute each entry's import_hash and
  # predict insert vs skip without writing.
  defp migrate_entries(entries, workspace, true) do
    Enum.reduce(entries, %{inserted: 0, skipped: 0, failed: 0}, fn entry, acc ->
      attrs = legacy_to_attrs(entry, workspace)

      if already_imported?(attrs[:import_hash]) do
        Map.update!(acc, :skipped, &(&1 + 1))
      else
        Map.update!(acc, :inserted, &(&1 + 1))
      end
    end)
  end

  defp migrate_entries(entries, workspace, false) do
    Enum.reduce(entries, %{inserted: 0, skipped: 0, failed: 0}, fn entry, acc ->
      attrs = legacy_to_attrs(entry, workspace)
      classify_import(entry, attrs, acc)
    end)
  end

  # Pre-check the partial unique `import_hash` identity so the
  # task output distinguishes actually-inserted rows from upsert
  # hits. `Fact.import_legacy` is `upsert?(true)` with
  # `upsert_fields: []`, so a re-run returns `{:ok, _}` for already-
  # present rows — counting every `:ok` as "imported" overstates
  # inserts on a second migration pass.
  defp classify_import(entry, attrs, acc) do
    if already_imported?(attrs[:import_hash]) do
      Map.update!(acc, :skipped, &(&1 + 1))
    else
      tenant_id = attrs[:tenant_id] || "default"
      attrs_minus_tenant = Map.delete(attrs, :tenant_id)

      case Fact.import_legacy(attrs_minus_tenant, tenant: tenant_id, authorize?: false) do
        {:ok, _} ->
          Map.update!(acc, :inserted, &(&1 + 1))

        {:error, err} ->
          Logger.warning(
            "[migrate.memory] import failed for #{inspect(entry["key"])}: " <>
              inspect(err)
          )

          Map.update!(acc, :failed, &(&1 + 1))
      end
    end
  end

  defp already_imported?(nil), do: false

  defp already_imported?(import_hash) when is_binary(import_hash) do
    match?(
      {:ok, %Postgrex.Result{rows: [_ | _]}},
      JidoClaw.Repo.query(
        "SELECT 1 FROM memory_facts WHERE import_hash = $1 LIMIT 1",
        [import_hash]
      )
    )
  rescue
    _ -> false
  end

  defp legacy_to_attrs(entry, workspace) do
    label = entry["key"]
    content_raw = entry["content"] || ""
    content = MemoryRedaction.redact_fact!(content_raw)
    type = entry["type"] || "fact"

    inserted_at = parse_timestamp(entry["created_at"] || entry["updated_at"])
    valid_at = inserted_at

    inserted_at_ms = DateTime.to_unix(inserted_at, :millisecond)

    import_hash =
      :crypto.hash(
        :sha256,
        "#{workspace.id}|#{label}|#{content}|#{inserted_at_ms}"
      )
      |> Base.encode16(case: :lower)

    %{
      tenant_id: workspace.tenant_id,
      scope_kind: :workspace,
      user_id: workspace.user_id,
      workspace_id: workspace.id,
      project_id: workspace.project_id,
      session_id: nil,
      label: label,
      content: content,
      tags: [type],
      trust_score: 0.5,
      import_hash: import_hash,
      inserted_at: inserted_at,
      valid_at: valid_at,
      embedding_status: :disabled
    }
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts, :millisecond)
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
