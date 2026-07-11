defmodule JidoClaw.CLI.Commands.SessionsTest do
  @moduledoc """
  Pins the `/sessions` REPL surface: two-group listing (CLI-resumable
  newest-first — matching `--continue`'s selection set — vs resume-by-UUID
  kinds), the resume hint footer, and graceful degraded-state output.
  """
  use JidoClaw.TenantCase, async: true

  import ExUnit.CaptureIO

  alias JidoClaw.CLI.Commands.Sessions, as: SessionsCommand

  setup do
    tenant_id = seed_tenant("sessions-cli")
    {:ok, ws} = seed_workspace(tenant_id)
    {:ok, tenant_id: tenant_id, ws: ws}
  end

  test "lists CLI-resumable sessions newest-first with :api under resume-by-UUID only", ctx do
    {:ok, older_repl} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :repl)
    {:ok, newest_cli} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :cli_run)
    {:ok, api} = seed_session(ctx.tenant_id, ctx.ws.id, kind: :api)

    state = %{tenant_id: ctx.tenant_id, workspace_uuid: ctx.ws.id}

    output = capture_io(fn -> assert {:ok, ^state} = SessionsCommand.list(state) end)

    assert output =~ "CLI resumable"
    assert output =~ "Other sessions — resume by UUID only"
    assert output =~ older_repl.id
    assert output =~ newest_cli.id
    assert output =~ api.id
    assert output =~ "mix jidoclaw --resume <uuid>"

    # Newest-first within the CLI group: the cli_run row (seeded later) must
    # print BEFORE the older repl row — the top row is what --continue picks.
    {cli_pos, _} = :binary.match(output, newest_cli.id)
    {repl_pos, _} = :binary.match(output, older_repl.id)
    assert cli_pos < repl_pos

    # The :api row lands in the UUID-only group (after its header).
    {other_header_pos, _} = :binary.match(output, "Other sessions")
    {api_pos, _} = :binary.match(output, api.id)
    assert api_pos > other_header_pos
  end

  test "an empty workspace prints a friendly notice", ctx do
    state = %{tenant_id: ctx.tenant_id, workspace_uuid: ctx.ws.id}

    output = capture_io(fn -> assert {:ok, ^state} = SessionsCommand.list(state) end)

    assert output =~ "No open sessions"
  end

  test "degraded state (no persisted scope) does not crash", ctx do
    state = %{tenant_id: ctx.tenant_id, workspace_uuid: nil}

    output = capture_io(fn -> assert {:ok, ^state} = SessionsCommand.list(state) end)

    assert output =~ "persistence unavailable"
  end
end
