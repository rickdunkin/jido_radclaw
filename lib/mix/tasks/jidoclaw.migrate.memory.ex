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
  alias JidoClaw.Workspaces.Resolver

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [dry_run: :boolean, project: :string])

    project_dir = Keyword.get(opts, :project) || File.cwd!()
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    Mix.shell().info("Migrating .jido/memory.json from #{project_dir}")

    if dry_run?, do: Mix.shell().info("(dry-run mode — nothing will be written)")

    {:ok, workspace} = Resolver.ensure_workspace("default", project_dir)
    Mix.shell().info("workspace_uuid: #{workspace.id} tenant_id: #{workspace.tenant_id}")

    count = migrate_memory(project_dir, workspace, dry_run?)

    Mix.shell().info("\nMigration complete:")
    Mix.shell().info("  facts imported: #{count}")

    :ok
  end

  defp migrate_memory(project_dir, workspace, dry_run?) do
    path = Path.join([project_dir, ".jido", "memory.json"])

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) ->
            entries =
              map
              |> Enum.map(fn {_id, entry} -> entry end)
              |> Enum.reject(&is_nil/1)

            Mix.shell().info("memory.json: #{length(entries)} entries")

            if dry_run? do
              length(entries)
            else
              Enum.count(entries, fn entry ->
                attrs = legacy_to_attrs(entry, workspace)

                case Fact.import_legacy(attrs) do
                  {:ok, _} ->
                    true

                  {:error, err} ->
                    Logger.warning(
                      "[migrate.memory] import failed for #{inspect(entry["key"])}: " <>
                        inspect(err)
                    )

                    false
                end
              end)
            end

          {:error, reason} ->
            Mix.shell().info("memory.json: invalid JSON (#{inspect(reason)})")
            0
        end

      {:error, :enoent} ->
        Mix.shell().info("memory.json: not present, skipping")
        0

      {:error, reason} ->
        Mix.shell().info("memory.json: read error (#{inspect(reason)})")
        0
    end
  end

  defp legacy_to_attrs(entry, workspace) do
    label = field(entry, "key")
    content_raw = field(entry, "content") || ""
    content = MemoryRedaction.redact_fact!(content_raw)
    type = field(entry, "type") || "fact"

    inserted_at = parse_timestamp(field(entry, "created_at") || field(entry, "updated_at"))
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

  defp field(entry, key) do
    Map.get(entry, key) || Map.get(entry, String.to_atom(key))
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
