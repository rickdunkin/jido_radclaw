defmodule JidoClaw.Orchestration.Replay.EventReader do
  @moduledoc """
  Single swappable indirection for the workflow-events read shared by the replay
  irreversible gate (`Replay.check_irreversible/4`), the preflight diagnostics
  (`Diagnostics.diagnose_irreversible/3`), and the MCP raw event-feed
  (`JidoClaw.WorkflowView.event_feed/3`) — single-sourced so the read sites never
  drift and a test can force a read failure without Mox.

  Defaults to `JidoClaw.Orchestration.WorkflowEvent.for_run/2` (the Ash code
  interface), swappable via `config :jido_claw, :replay_event_reader` — the same
  backend-swap pattern as `:mcp_client` / `:search_web_backend`. Captures the
  existing arity-2 call byte-for-byte: `for_run(run_id, tenant: tenant, actor:
  actor)`.

  ## Reader contract

  A swapped-in reader **MUST honor the standard Ash code-interface `query:`
  option** — at minimum `limit`, `filter`, and `sort` (which
  `event_feed/3` passes to paginate: `query: [filter: [seq: [greater_than:
  after_seq]], limit: n]`). The default `&WorkflowEvent.for_run/2` honors them
  via `Ash.Query.build/2`. A reader that ignores `query:` silently breaks
  `event_feed/3` pagination (unbounded fetch, no seq cursor) — a stub that only
  needs to force a failure should return `{:error, _}` rather than a bounded
  list, so the contract is never in question.
  """

  alias JidoClaw.Orchestration.WorkflowEvent

  @doc """
  Read a run's events in seq order via the configured reader.

  `opts` is a standard Ash code-interface keyword list — `tenant:` / `actor:`
  plus an optional `query:` (`limit` / `filter` / `sort`), which a swapped
  reader **must** honor (see the moduledoc contract). `event_feed/3` relies on
  `query:` for byte-bounded seq pagination.
  """
  @spec for_run(String.t(), keyword()) :: {:ok, [WorkflowEvent.t()]} | {:error, term()}
  def for_run(run_id, opts) do
    reader().(run_id, opts)
  end

  defp reader do
    Application.get_env(:jido_claw, :replay_event_reader, &WorkflowEvent.for_run/2)
  end
end
