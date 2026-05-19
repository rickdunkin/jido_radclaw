defmodule JidoClaw.Trace.Domain do
  @moduledoc """
  Ash domain for durable trace projection.

  `JidoClaw.Trace.Persistence` writes `trace_runs` (one row per
  `request_id` / `trace_id`) and `trace_events` (one row per
  `%JidoClaw.Trace.Event{}`) so traces survive collector restarts and
  feed cross-restart replay for AgentView, the certificate verifier,
  and the inspection tools.

  The in-memory ring (`JidoClaw.Trace.Collector`) is the hot read
  path; persistence is the durable replay path. `Trace.for_request/3`
  falls back to Postgres on a ring miss; `Trace.history/1` reads
  Postgres only.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Trace.Resources.TraceRun)
    resource(JidoClaw.Trace.Resources.TraceEvent)
  end
end
