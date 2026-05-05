defmodule JidoClaw.Memory.Domain do
  @moduledoc """
  Ash domain for the v0.6.3 Memory subsystem.

  Replaces v0.5.x's `JidoClaw.Memory` GenServer + jido_memory ETS store +
  `.jido/memory.json` JSON dump with a multi-scope, bitemporal, multi-tier
  Postgres model:

    * `JidoClaw.Memory.Block` — curated, scope-chained tier rendered into
      the system prompt's frozen snapshot.
    * `JidoClaw.Memory.BlockRevision` — append-only history for Blocks.
    * `JidoClaw.Memory.Fact` — searchable tier with FTS, pgvector,
      and pg_trgm hybrid retrieval.
    * `JidoClaw.Memory.Episode` — immutable provenance rows linking
      Facts to source Messages / Solutions.
    * `JidoClaw.Memory.FactEpisode` — M:N join between Facts and Episodes.
    * `JidoClaw.Memory.Link` — directed graph edges between Facts (same
      tenant + scope only).
    * `JidoClaw.Memory.ConsolidationRun` — audit row + composite watermarks
      for the scheduled consolidator.

  Pure modules: `JidoClaw.Memory.Scope` (resolution + advisory-lock keys),
  `JidoClaw.Memory.Retrieval` (public search API), and
  `JidoClaw.Memory.HybridSearchSql` (RRF SQL builder).
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Memory.Block)
    resource(JidoClaw.Memory.BlockRevision)
    resource(JidoClaw.Memory.Fact)
    resource(JidoClaw.Memory.Episode)
    resource(JidoClaw.Memory.FactEpisode)
    resource(JidoClaw.Memory.Link)
    resource(JidoClaw.Memory.ConsolidationRun)
  end
end
