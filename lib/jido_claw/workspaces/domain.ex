defmodule JidoClaw.Workspaces do
  @moduledoc """
  Ash domain for workspace records.

  A `Workspace` is the durable, tenant-scoped row that represents a project
  directory anchor. It is created/updated lazily by
  `JidoClaw.Workspaces.Resolver.ensure_workspace/3` whenever a surface
  (REPL, web, channel adapter, cron job) starts handling a request, so
  later phases (Conversations, Memory, Solutions, Audit) can foreign-key
  to a real UUID instead of an opaque string.

  The pre-existing per-session runtime `workspace_id` (overloaded as a
  per-session VFS/Shell/Profile key) is unchanged here — Phase 0 only adds
  a parallel UUID column threaded through `tool_context.workspace_uuid`.
  """

  use Ash.Domain, otp_app: :jido_claw

  resources do
    resource(JidoClaw.Workspaces.Workspace)
  end
end
