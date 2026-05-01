defmodule Mix.Tasks.Jidoclaw.Migrate.Solutions do
  @moduledoc """
  One-shot migration: copy v0.5.x `.jido/solutions.json` and
  `.jido/reputation.json` rows into the v0.6.1 Postgres-backed
  Solutions corpus.

  ## Usage

      mix jidoclaw.migrate.solutions [--dry-run] [--project DIR]

  The default `DIR` is the current working directory. The task:

    1. Resolves a Workspace via `JidoClaw.Workspaces.Resolver.ensure_workspace/3`
       (`tenant_id: "default"`, `path: DIR`).
    2. Reads `DIR/.jido/solutions.json` (if present) and inserts each
       entry via `Solution.import_legacy/1`. Idempotent — entries
       whose `id` already exists in Postgres are skipped.
    3. Reads `DIR/.jido/reputation.json` (if present) and:
       a. SHA-256s the file.
       b. Looks up `(tenant_id, sha)` in the
          `reputation_imports` table — present means already imported,
          skip.
       c. Otherwise, for each agent: sums counters with any existing
          row, recomputes `score` via `Reputation.compute_score/1`,
          and writes via `Reputation.upsert/1`.
       d. Records the file's sha in `reputation_imports`.
    4. With `--dry-run`, prints the plan without writing.
  """

  @shortdoc "Migrate v0.5.x solutions/reputation JSON to Postgres"

  use Mix.Task

  require Logger

  alias JidoClaw.Solutions.{Reputation, ReputationImport, Solution}
  alias JidoClaw.Workspaces.Resolver

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [dry_run: :boolean, project: :string])

    project_dir = Keyword.get(opts, :project) || File.cwd!()
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    Mix.shell().info(
      "Migrating .jido/solutions.json and .jido/reputation.json from #{project_dir}"
    )

    if dry_run?, do: Mix.shell().info("(dry-run mode — nothing will be written)")

    {:ok, workspace} = Resolver.ensure_workspace("default", project_dir)
    Mix.shell().info("workspace_uuid: #{workspace.id} tenant_id: #{workspace.tenant_id}")

    sol_count = migrate_solutions(project_dir, workspace, dry_run?)
    rep_count = migrate_reputation(project_dir, workspace, dry_run?)

    Mix.shell().info("\nMigration complete:")
    Mix.shell().info("  solutions imported: #{sol_count}")
    Mix.shell().info("  reputation rows merged: #{rep_count}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Solutions
  # ---------------------------------------------------------------------------

  defp migrate_solutions(project_dir, workspace, dry_run?) do
    path = Path.join([project_dir, ".jido", "solutions.json"])

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) ->
            entries =
              map
              |> Enum.map(fn {_id, entry} -> entry end)
              |> Enum.reject(&is_nil/1)

            Mix.shell().info("solutions.json: #{length(entries)} entries")

            if dry_run? do
              length(entries)
            else
              Enum.count(entries, fn entry ->
                attrs = legacy_to_attrs(entry, workspace)

                # Idempotency: skip when a row with this id already exists.
                if attrs[:id] && row_exists?(:solutions, attrs[:id]) do
                  false
                else
                  case Solution.import_legacy(attrs) do
                    {:ok, _} ->
                      true

                    {:error, reason} ->
                      Logger.warning("[migrate] solution skipped: #{inspect(reason)}")
                      false
                  end
                end
              end)
            end

          _ ->
            Mix.shell().error("solutions.json: could not parse JSON")
            0
        end

      {:error, :enoent} ->
        Mix.shell().info("solutions.json: not found, skipping")
        0

      {:error, reason} ->
        Mix.shell().error("solutions.json: read failed: #{inspect(reason)}")
        0
    end
  end

  defp legacy_to_attrs(entry, workspace) do
    %{
      id: Map.get(entry, "id"),
      problem_signature: Map.get(entry, "problem_signature"),
      solution_content: Map.get(entry, "solution_content"),
      language: Map.get(entry, "language"),
      framework: Map.get(entry, "framework"),
      runtime: Map.get(entry, "runtime"),
      agent_id: Map.get(entry, "agent_id"),
      tags: Map.get(entry, "tags", []),
      verification: Map.get(entry, "verification", %{}),
      trust_score: Map.get(entry, "trust_score", 0.0) * 1.0,
      sharing: coerce_sharing(Map.get(entry, "sharing", "local")),
      tenant_id: workspace.tenant_id,
      workspace_id: workspace.id,
      session_id: nil,
      created_by_user_id: nil,
      inserted_at: parse_dt(Map.get(entry, "inserted_at")),
      updated_at: parse_dt(Map.get(entry, "updated_at"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp coerce_sharing(:local), do: :local
  defp coerce_sharing(:shared), do: :shared
  defp coerce_sharing(:public), do: :public
  defp coerce_sharing("local"), do: :local
  defp coerce_sharing("shared"), do: :shared
  defp coerce_sharing("public"), do: :public
  defp coerce_sharing(_), do: :local

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp row_exists?(:solutions, id) do
    case JidoClaw.Repo.query(
           "SELECT 1 FROM solutions WHERE id = $1 LIMIT 1",
           [Ecto.UUID.dump!(id)]
         ) do
      {:ok, %Postgrex.Result{rows: [_ | _]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Reputation
  # ---------------------------------------------------------------------------

  defp migrate_reputation(project_dir, workspace, dry_run?) do
    path = Path.join([project_dir, ".jido", "reputation.json"])

    case File.read(path) do
      {:ok, body} ->
        sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        case ReputationImport.find_by_hash(workspace.tenant_id, sha) do
          {:ok, %ReputationImport{} = existing} ->
            Mix.shell().info(
              "reputation.json: already imported at #{DateTime.to_iso8601(existing.imported_at)}; skipping"
            )

            0

          _ ->
            do_migrate_reputation(body, workspace, sha, path, dry_run?)
        end

      {:error, :enoent} ->
        Mix.shell().info("reputation.json: not found, skipping")
        0

      {:error, reason} ->
        Mix.shell().error("reputation.json: read failed: #{inspect(reason)}")
        0
    end
  end

  defp do_migrate_reputation(body, workspace, sha, path, dry_run?) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        rows = Enum.map(map, fn {_k, raw} -> coerce_legacy_reputation(raw) end)

        Mix.shell().info(
          "reputation.json: #{length(rows)} entries (sha256=#{String.slice(sha, 0, 12)}…)"
        )

        if dry_run? do
          length(rows)
        else
          merged = Enum.count(rows, &merge_reputation_row(&1, workspace))

          {:ok, _} =
            ReputationImport.record_import(%{
              tenant_id: workspace.tenant_id,
              source_sha256: sha,
              source_path: path,
              imported_at: DateTime.utc_now(),
              rows_imported: merged,
              metadata: %{}
            })

          merged
        end

      _ ->
        Mix.shell().error("reputation.json: could not parse JSON")
        0
    end
  end

  defp coerce_legacy_reputation(raw) do
    %{
      agent_id: to_string(Map.get(raw, "agent_id") || Map.get(raw, :agent_id) || ""),
      score: 0.5,
      solutions_verified:
        Map.get(raw, "solutions_verified") || Map.get(raw, :solutions_verified) || 0,
      solutions_failed: Map.get(raw, "solutions_failed") || Map.get(raw, :solutions_failed) || 0,
      solutions_shared: Map.get(raw, "solutions_shared") || Map.get(raw, :solutions_shared) || 0,
      last_active: parse_dt(Map.get(raw, "last_active") || Map.get(raw, :last_active))
    }
  end

  defp merge_reputation_row(%{agent_id: ""}, _workspace), do: false

  defp merge_reputation_row(row, workspace) do
    existing =
      case Reputation.get(workspace.tenant_id, row.agent_id) do
        {:ok, %Reputation{} = r} -> r
        _ -> nil
      end

    summed = sum_with_existing(row, existing)
    score = Reputation.compute_score(summed)

    case Reputation.upsert(%{
           tenant_id: workspace.tenant_id,
           agent_id: row.agent_id,
           score: score,
           solutions_verified: summed.solutions_verified,
           solutions_failed: summed.solutions_failed,
           solutions_shared: summed.solutions_shared,
           last_active: summed.last_active
         }) do
      {:ok, _} ->
        :telemetry.execute(
          [:jido_claw, :solutions, :reputation, :imported],
          %{merged_score: score},
          %{
            tenant_id: workspace.tenant_id,
            agent_id: row.agent_id,
            sources: if(existing, do: 2, else: 1)
          }
        )

        true

      _ ->
        false
    end
  end

  defp sum_with_existing(row, nil), do: row

  defp sum_with_existing(row, %Reputation{} = existing) do
    %{
      agent_id: row.agent_id,
      solutions_verified: row.solutions_verified + existing.solutions_verified,
      solutions_failed: row.solutions_failed + existing.solutions_failed,
      solutions_shared: row.solutions_shared + existing.solutions_shared,
      last_active: latest_dt(row.last_active, existing.last_active)
    }
  end

  defp latest_dt(nil, b), do: b
  defp latest_dt(a, nil), do: a

  defp latest_dt(%DateTime{} = a, %DateTime{} = b),
    do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp latest_dt(a, _b), do: a
end
