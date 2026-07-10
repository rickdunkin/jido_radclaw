defmodule JidoClaw.Core.CanonicalHash do
  @moduledoc """
  The single deterministic-term hash core: SHA-256 over
  `:erlang.term_to_binary(term, [:deterministic])`, rendered lowercase hex.

  Every semantic fingerprint in the app routes through this one function —
  `JidoClaw.Orchestration.ToolApprovals.fingerprint/3` (the per-tool-call
  consent fingerprint), `JidoClaw.RouteComposer`'s wave `route_hash`/
  `catalog_hash` correlation metadata, and `JidoClaw.RouteComposer.FindingKey`
  (the camus C1-5 cross-wave finding identity), plus external-MCP proxy and
  transport identities — so the recipe can never fork per subsystem. Domain
  **canonicalization** (key stringification, pair sorting, normalization
  rules) deliberately stays with each domain; this module owns only the hash
  of an already-canonical term. Never hash a rendered string
  (`feedback_canonical_fingerprint_term`) and never `:erlang.phash2` (not
  stable across releases).

  Sibling with a different contract: `JidoClaw.Agent.LoopGuard`'s
  `args_digest/1` returns a **raw binary** digest for in-memory run-length
  comparison only — it is not a persisted fingerprint and stays local.
  """

  @doc """
  Lowercase-hex SHA-256 of the deterministic external term format of `term`.
  """
  @spec sha256_term(term()) :: String.t()
  def sha256_term(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
