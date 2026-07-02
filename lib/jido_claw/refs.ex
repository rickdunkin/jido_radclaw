defmodule JidoClaw.Refs do
  @moduledoc """
  Central mint for opaque, tenant/session-fetchable content refs — the `out_…`
  shaped-output refs (`JidoClaw.Tools.OutputShaper.Store`) and the `art_…`
  composer-artifact refs (`JidoClaw.RouteComposer`, `JidoClaw.Orchestration.ComposerArtifact`).

  These are unguessable handles, NOT dedupe keys: a `fetch_output`/artifact ref
  is a bearer token to durable content, so a same-tenant guesser must not be able
  to walk another session's refs. The entropy floor is therefore single-sourced
  here — #{12} random bytes (96 bits) → 24 lowercase hex chars, bumped from the
  original 6 (O-L2) — so every mint site is uniform and can't silently regress.
  """

  # 12 bytes ⇒ 96 bits of entropy ⇒ 24 lowercase hex chars.
  @random_bytes 12

  @doc """
  Mint a fresh ref: `prefix` (e.g. `"out_"`, `"art_"`) followed by
  #{@random_bytes} cryptographically-random bytes rendered as lowercase hex.
  """
  @spec mint(String.t()) :: String.t()
  def mint(prefix) when is_binary(prefix) do
    prefix <> Base.encode16(:crypto.strong_rand_bytes(@random_bytes), case: :lower)
  end
end
