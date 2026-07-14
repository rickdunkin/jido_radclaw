defmodule JidoClaw.MCPServer.Resources.BootstrapTest do
  @moduledoc """
  PD2-1: the slim `jido://bootstrap` orientation resource, driven through the
  real `JidoClaw.MCPServer` handler path (the workflow_stage_test harness).

  Honesty pins: version/tool facts are ALWAYS present; the tenant block reads
  `available: false` with a reason when no MCP default scope resolves (never
  a fabricated empty snapshot); run lists cap at 5 with an overflow SIGNAL
  from a cap+1 read (≥1 means more exist — never a total).
  """
  use JidoClaw.TenantCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Resources, as: ResourcesHandler
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.MCPServer
  alias JidoClaw.MCPServer.ErrorCodes
  alias JidoClaw.MCPServer.Resources.Bootstrap
  alias JidoClaw.MCPServer.SurfaceVersion
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    prior = Application.get_env(:jido_claw, :jido_claw_mcp_default_scope)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)
        value -> Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, value)
      end
    end)

    tenant = seed_tenant("mcp-bootstrap")
    {:ok, tenant: tenant}
  end

  defp frame do
    {:ok, frame} = MCPServer.init(%{}, %Frame{})
    frame
  end

  defp payload! do
    result =
      ResourcesHandler.handle_read(
        %{"params" => %{"uri" => "jido://bootstrap"}},
        frame(),
        MCPServer
      )

    assert {:reply, %{"contents" => [content]}, _frame} = result
    assert content["uri"] == "jido://bootstrap"
    assert content["mimeType"] == "application/json"
    Jason.decode!(content["text"])
  end

  # The Initializer-shaped scope (session_uuid must be a non-blank binary so
  # `MCPScope.with_default/1` takes the direct path, never a re-resolve).
  defp inject_scope(tenant) do
    Application.put_env(:jido_claw, :jido_claw_mcp_default_scope, %{
      tenant_id: tenant,
      workspace_uuid: "ws-uuid",
      workspace_id: "ws-uuid",
      session_uuid: "sess-uuid",
      session_id: "mcp_bootstrap_test",
      project_dir: "/tmp/bootstrap-proj",
      actor: actor_for(tenant)
    })
  end

  defp active_run!(tenant, name) do
    {:ok, run} =
      WorkflowRun.create(%{name: name, workflow_type: "composer"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    run
  end

  defp completed_run!(tenant, name, result) do
    run = active_run!(tenant, name)
    append!(run, :run_started, %{}, tenant)
    append!(run, :route_done_with_findings, %{result: result}, tenant)
    run
  end

  defp append!(run, kind, payload, tenant) do
    {:ok, _} = WorkflowLog.append(run, kind, payload, tenant: tenant, actor: actor_for(tenant))
  end

  describe "identity + routing" do
    test "resource identity: uri/name/mime pinned" do
      assert Bootstrap.uri() == "jido://bootstrap"
      assert Bootstrap.name() == "bootstrap"
      assert Bootstrap.mime_type() == "application/json"
    end

    test "direct read/2 on any other URI is not_found" do
      assert Bootstrap.read("jido://bootstrap/other", nil) == {:error, :not_found}
    end
  end

  describe "scope-unavailable honesty" do
    test "no default scope ⇒ tenant.available false with reason; version facts still present" do
      Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)

      payload = payload!()

      assert payload["app_version"] == to_string(Application.spec(:jido_claw, :vsn))
      assert payload["surface_version"] == SurfaceVersion.current()
      assert payload["tool_names"] == MCPServer.served_tool_names()
      assert payload["tool_count"] == length(MCPServer.served_tool_names())

      # Exact equality: no fabricated snapshot keys ride the unresolved block.
      assert payload["tenant"] == %{
               "available" => false,
               "reason" => "mcp_scope_unavailable"
             }
    end
  end

  describe "error_contract (PD1-2 wiring pin)" do
    test "families match the WIRE representation of the live registry + the three rules" do
      Application.delete_env(:jido_claw, :jido_claw_mcp_default_scope)

      contract = payload!()["error_contract"]

      # The payload is JsonSafe'd + JSON round-tripped — string keys and
      # code strings; comparing against the atom-keyed families/0 directly
      # can never match.
      assert contract["families"] ==
               JsonSafe.encode(ErrorCodes.families())

      assert contract["stability"] == ErrorCodes.stability_sentence()

      assert contract["envelope_location"] =~ "content[1]"
      assert contract["envelope_location"] =~ "second content item"
      assert contract["envelope_location"] =~ "never read it as the final item"

      assert contract["scope"] =~ "Tool-result errors only"
      assert contract["unregistered_code_fallback"] =~ "details.unregistered_code"

      # The served retry definition (P1c): all THREE wire states — a remote
      # client must never mistake policy eligibility for an executed retry,
      # and absence is a real state too.
      assert contract["retry_semantics"] == ErrorCodes.retry_semantics()
      assert contract["retry_semantics"] =~ "eligibility"
      assert contract["retry_semantics"] =~ "never records"
      assert contract["retry_semantics"] =~ "ABSENT"
      assert contract["retry_semantics"] =~ "do not infer"
    end
  end

  describe "tenant snapshot" do
    test "resolved scope ⇒ identity + honest pending count + run lists with disposition",
         %{tenant: tenant} do
      inject_scope(tenant)

      active_run = active_run!(tenant, "active-1")
      # WS6 v1.2: lease the active run so the bootstrap rows prove the
      # ownership fields ride the run_view projection.
      assert {:ok, :claimed} = WorkflowLease.stamp(active_run.id, Ash.UUID.generate(), nil)

      _completed =
        completed_run!(tenant, "done-1", %{
          "disposition" => "done_with_findings",
          "findings_deferred_count" => 2
        })

      block = payload!()["tenant"]

      assert block["available"] == true
      assert block["tenant_id"] == tenant
      assert block["workspace_id"] == "ws-uuid"
      assert block["session_id"] == "mcp_bootstrap_test"
      assert block["project_dir"] == "/tmp/bootstrap-proj"

      # A real read on an empty inbox is an honest zero (contrast a read
      # FAULT, which flips pending_gates_available instead of reporting 0).
      assert block["pending_gates_count"] == 0

      assert [active] = block["active_runs"]
      assert active["name"] == "active-1"
      # WS6 v1.2 ownership fields (string-keyed, ISO-8601 via JsonSafe).
      assert active["claimed_by"] == WorkflowLease.node_identity()
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(active["claim_expires_at"])
      assert block["active_runs_overflow_count"] == 0

      # Rows are run_view projections, so completions carry the C1-4
      # disposition automatically.
      assert [completed] = block["recent_completions"]
      assert completed["name"] == "done-1"
      assert completed["status"] == "completed"
      assert completed["disposition"] == "done_with_findings"
      assert completed["findings_deferred_count"] == 2
      assert block["recent_completions_overflow_count"] == 0
    end

    test "run lists cap at 5; overflow_count signals more exist (≥1, never a total)",
         %{tenant: tenant} do
      inject_scope(tenant)

      for i <- 1..8, do: active_run!(tenant, "active-#{i}")

      block = payload!()["tenant"]

      assert [_, _, _, _, _] = block["active_runs"]
      # The cap+1 read fetched 6 of the 8: overflow reads 1 — a signal that
      # more exist, deliberately not the true remainder (3).
      assert block["active_runs_overflow_count"] == 1
    end
  end
end
