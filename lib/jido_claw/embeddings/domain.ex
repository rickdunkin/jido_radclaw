defmodule JidoClaw.Embeddings.Domain do
  @moduledoc """
  Ash domain for the embedding subsystem.

  Resources:

    * `JidoClaw.Embeddings.DispatchWindow` — cluster-global Voyage
      rate-budget counters (per-API-key, not per-tenant). Composite
      PK `(model, window_started_at)`.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Embeddings.DispatchWindow)
  end
end
