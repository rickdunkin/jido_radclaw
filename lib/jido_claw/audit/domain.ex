defmodule JidoClaw.Audit do
  @moduledoc """
  Ash domain for the append-only audit log.

  Hybrid sync/async dispatch: tx-bound producers (memory writes,
  solution shares, session start/end) call `AsyncWriter.sync/1` so
  the audit row commits in the same transaction as the producer
  (any rollback rolls both back). Hot-path producers (tool calls
  via SignalListener, auth events) call `AsyncWriter.cast/1` so
  audit-write latency doesn't gate the request.

  The `Event` resource is append-only: no `:update`, no `:destroy`.
  Cross-tenant FK validation is best-effort — when `target_kind`
  matches a tenanted parent in the dispatch map, the parent's
  `:by_id_global` action is consulted; otherwise validation is
  skipped with a `:tenant_validation_skipped_for_untenanted_parent`
  telemetry event.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Audit.Event)
  end
end
