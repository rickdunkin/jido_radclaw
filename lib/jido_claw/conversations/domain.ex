defmodule JidoClaw.Conversations do
  @moduledoc """
  Ash domain for conversation session records.

  A `Session` is the durable, tenant-scoped row that represents a single
  REPL/Discord/Telegram/Web RPC/cron/api conversation. Sessions are
  created lazily by `JidoClaw.Conversations.Resolver.ensure_session/5` on
  every entry-point dispatch so later phases (Memory, Audit) can foreign-
  key to a real UUID instead of an opaque string.

  ## Out of scope for Phase 0

  Sessions store `tenant_id` directly on the row alongside the FK to
  `Workspace`. The `:start` action carries a `before_action` hook that
  refuses to create a Session whose `tenant_id` doesn't match the parent
  Workspace's `tenant_id` — that invariant is the seed of v0.6's broader
  tenant integrity work.

  No `:mcp` Session rows are emitted in Phase 0 — the `:mcp` enum value
  is reserved for forward compatibility with later MCP `tool_context`
  plumbing.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Conversations.Session)
    resource(JidoClaw.Conversations.Message)
    resource(JidoClaw.Conversations.RequestCorrelation)
  end
end
