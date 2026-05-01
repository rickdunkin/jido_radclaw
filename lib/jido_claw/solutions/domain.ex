defmodule JidoClaw.Solutions.Domain do
  @moduledoc """
  Ash domain for the Solutions corpus, retiring v0.5.x's
  ETS+JSONL `Solutions.Store` GenServer in favour of a tenant-scoped
  Postgres table with FTS, pgvector, and pg_trgm hybrid retrieval.

  Resources:

    * `JidoClaw.Solutions.Solution` — the corpus row.
    * `JidoClaw.Solutions.Reputation` — per-`(tenant_id, agent_id)`
      reputation entry with atomic counter writes.
    * `JidoClaw.Solutions.ReputationImport` — idempotency ledger for
      one-shot legacy `.jido/reputation.json` imports.

  Pure modules (preserved): `Fingerprint`, `Matcher`, `Trust`.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Solutions.Solution)
    resource(JidoClaw.Solutions.Reputation)
    resource(JidoClaw.Solutions.ReputationImport)
  end
end
