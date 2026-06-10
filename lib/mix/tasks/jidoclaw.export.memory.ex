defmodule Mix.Tasks.Jidoclaw.Export.Memory do
  @moduledoc """
  Export the Postgres-backed Memory corpus for backup or sanity audit.

  ## Usage

      mix jidoclaw.export.memory [--out FILE] [--project DIR] [--with-redaction-delta]

  Default `FILE` is `.jido/memory_export.json` under DIR. Two fixture
  shapes:

    * **sanitized** (default) — current Facts only, redacted via
      `JidoClaw.Security.Redaction.Memory.redact_fact!/1`. Suitable
      to commit alongside a tenant's docs.
    * **with-redaction-delta** — adds a `redactions_applied` counter
      per row showing how many secrets were scrubbed on export.

  Scope: only Facts owned by the workspace resolved from
  `--project DIR` are exported, filtered to current-truth rows
  (`invalid_at IS NULL AND expired_at IS NULL`). Cross-tenant /
  cross-workspace leakage is impossible by construction.

  ## Block / Episode / Link tiers

  Skipped with a manifest warning. There's no v0.5.x equivalent and
  the round-trip story for these tiers is simply "the consolidator
  rebuilds them from Conversations + Facts on the next tick." A
  future export task can add them once the consolidator runtime
  ships in v0.6.3b.
  """

  @shortdoc "Export the Memory corpus to a JSON fixture"

  use Mix.Task

  require Ash.Query

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Export.Canonical
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Security.Redaction.Memory, as: MemoryRedaction
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Workspaces.Resolver

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [out: :string, project: :string, with_redaction_delta: :boolean]
      )

    project_dir = Keyword.get(opts, :project) || File.cwd!()
    out = Keyword.get(opts, :out, Path.join([project_dir, ".jido", "memory_export.json"]))
    with_delta? = Keyword.get(opts, :with_redaction_delta, false)

    Mix.Task.run("app.start")

    {:ok, %{id: workspace_id, tenant_id: tenant_id}} =
      Resolver.ensure_workspace("default", project_dir)

    base_query = Fact.query_to_list(%{}, tenant: tenant_id, actor: Actor.system(tenant_id))

    query =
      Ash.Query.filter(
        base_query,
        workspace_id == ^workspace_id and
          is_nil(invalid_at) and is_nil(expired_at)
      )

    case Ash.read(query, tenant: tenant_id) do
      {:ok, raw_facts} ->
        facts = Enum.sort_by(raw_facts, & &1.id)
        write_export(facts, out, tenant_id, workspace_id, with_delta?)
        :ok

      {:error, reason} ->
        Mix.raise("export failed: #{inspect(reason)}")
    end
  end

  defp write_export(facts, out, tenant_id, workspace_id, with_delta?) do
    Mix.shell().info("Exporting #{length(facts)} Memory.Fact rows to #{out}")

    payload = %{
      manifest: %{
        version: "v0.6.3a",
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        included_resources: ["memory_facts"],
        excluded_with_warning: [
          "memory_blocks (no v0.5.x equivalent — rebuilt by consolidator)",
          "memory_episodes (provenance, not exportable yet)",
          "memory_block_revisions (history)",
          "memory_links (graph edges)"
        ],
        with_redaction_delta?: with_delta?
      },
      facts: Enum.map(facts, &fact_to_export(&1, with_delta?))
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Canonical.encode!(payload))

    Mix.shell().info("Done.")
  end

  defp fact_to_export(fact, with_delta?) do
    original = fact.content || ""
    redacted = MemoryRedaction.redact_fact!(original)

    base = %{
      id: fact.id,
      tenant_id: fact.tenant_id,
      scope_kind: fact.scope_kind,
      user_id: fact.user_id,
      workspace_id: fact.workspace_id,
      project_id: fact.project_id,
      session_id: fact.session_id,
      label: fact.label,
      content: redacted,
      tags: fact.tags,
      source: fact.source,
      trust_score: fact.trust_score,
      valid_at: fact.valid_at,
      inserted_at: fact.inserted_at,
      import_hash: fact.import_hash
    }

    if with_delta? do
      # Counting against `original` ensures the delta reflects scrubs
      # that actually occurred. Pattern-match asserts both redactor
      # entry points produce the same string — a cheap convergence
      # check (both wrap `Patterns.redact/1` / `redact_with_count/1`).
      {^redacted, count} = Patterns.redact_with_count(original)
      Map.put(base, :redactions_applied, count)
    else
      base
    end
  end
end
