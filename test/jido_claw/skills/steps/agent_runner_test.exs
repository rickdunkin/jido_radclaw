defmodule JidoClaw.Skills.Steps.AgentRunnerTest do
  @moduledoc """
  Tests the spawn/run/capture core ported from the retired `StepAction`:

    * `resolve_scope/2` — now resolves from the **Reactor context**
      (`context[:tenant]` → tenant_id, `context[:actor]` → actor, plus the
      merged session/workspace/user/project_dir keys) with the legacy
      precedence/fallback semantics.
    * the async typed-output capture path (driven by `:step_agent_server`
      FakeAgentServers + the `ask/3`-exporting `EchoAskStub`).
    * `forward_context` policy enforcement and child-correlation `:user_id`
      propagation (these hit the DB, so they own a shared sandbox).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Test.{EchoAskStub, EchoStub}
  alias JidoClaw.Workflows.StepResult

  alias JidoClaw.Skills.Steps.AgentRunnerTest.{
    ArtifactsFakeAgentServer,
    ErrorFakeAgentServer,
    FailedFakeAgentServer,
    FreeFormFakeAgentServer,
    SummaryFakeAgentServer,
    ValidatedFakeAgentServer
  }

  describe "resolve_scope/2" do
    test "maps run-identity keys: context[:tenant] → tenant_id, context[:actor] → actor" do
      actor = %{kind: :system, tenant_id: "t"}
      scope = AgentRunner.resolve_scope(%{tenant: "t", actor: actor}, "tag1")

      assert scope.tenant_id == "t"
      assert scope.actor == actor
      assert scope.agent_id == "tag1"
      assert scope.subagent == true
    end

    test "falls back to context[:tenant_id] when :tenant is absent" do
      scope = AgentRunner.resolve_scope(%{tenant_id: "scoped"}, "tag2")
      assert scope.tenant_id == "scoped"
    end

    test "reads session/workspace/user from the merged scope keys" do
      ctx = %{
        tenant: "t",
        session_id: "sess",
        session_uuid: "00000000-0000-0000-0000-000000000111",
        workspace_id: "ws-runtime",
        workspace_uuid: "00000000-0000-0000-0000-000000000222",
        user_id: "00000000-0000-0000-0000-000000000099"
      }

      scope = AgentRunner.resolve_scope(ctx, "tag3")

      assert scope.session_id == "sess"
      assert scope.session_uuid == "00000000-0000-0000-0000-000000000111"
      assert scope.workspace_id == "ws-runtime"
      assert scope.workspace_uuid == "00000000-0000-0000-0000-000000000222"
      assert scope.user_id == "00000000-0000-0000-0000-000000000099"
    end

    test "workspace_id falls back to wf_<tag>, project_dir to cwd, UUIDs to nil" do
      scope = AgentRunner.resolve_scope(%{}, "tag4")

      assert scope.workspace_id == "wf_tag4"
      assert scope.project_dir == File.cwd!()
      assert scope.tenant_id == nil
      assert scope.session_uuid == nil
      assert scope.workspace_uuid == nil
      assert scope.user_id == nil
      assert scope.agent_id == "tag4"
    end

    test "agent_id is always the supplied tag, never inherited from context" do
      scope = AgentRunner.resolve_scope(%{agent_id: "ignored"}, "actual_tag")
      assert scope.agent_id == "actual_tag"
    end
  end

  describe "run/4 — async typed-output capture" do
    setup do
      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_async" => %{
          module: EchoAskStub,
          description: "test-only async echo template",
          model: :fast,
          max_iterations: 1
        }
      })

      previous = Application.get_env(:jido_claw, :step_agent_server)

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)

        case previous do
          nil -> Application.delete_env(:jido_claw, :step_agent_server)
          mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
        end
      end)

      :ok
    end

    test "populates typed_output when meta.output.status is :validated" do
      Application.put_env(:jido_claw, :step_agent_server, ValidatedFakeAgentServer)

      assert {:ok, %StepResult{} = result} =
               AgentRunner.run("echo_async", "go", "async_step", %{})

      assert result.name == "async_step"
      assert result.typed_output == %{verdict: :pass, confidence: :high, reasoning: "ok"}
      assert is_binary(result.result) and result.result != ""
    end

    test "leaves typed_output nil when meta.output.status is :error" do
      Application.put_env(:jido_claw, :step_agent_server, ErrorFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", nil, %{})
      assert result.typed_output == nil
      assert result.name == nil
    end

    test "projects typed_output[:summary] to StepResult.result as prose" do
      Application.put_env(:jido_claw, :step_agent_server, SummaryFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.result == "Implemented foo"
    end

    test "merges typed_output[:artifacts] into StepResult.artifacts (stringified)" do
      Application.put_env(:jido_claw, :step_agent_server, ArtifactsFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.artifacts["url"] == "http://localhost:4000"
      assert result.artifacts["port"] == "4000"
    end

    test "free-form path extracts artifacts from a fenced ARTIFACTS: block" do
      Application.put_env(:jido_claw, :step_agent_server, FreeFormFakeAgentServer)

      assert {:ok, %StepResult{} = result} = AgentRunner.run("echo_async", "go", "s", %{})
      assert result.typed_output == nil
      assert result.artifacts["url"] == "http://localhost:4001"
    end

    test "a failed request becomes a step {:error, _}" do
      Application.put_env(:jido_claw, :step_agent_server, FailedFakeAgentServer)

      assert {:error, msg} = AgentRunner.run("echo_async", "go", "s", %{})
      assert msg =~ "failed"
    end
  end

  describe "run/4 — setup failure" do
    test "an unknown template returns a clean {:error, _} (no crash)" do
      assert {:error, msg} = AgentRunner.run("does_not_exist_tmpl", "go", "s", %{})
      assert msg =~ "setup failed"
    end
  end

  describe "run/4 — forward_context policy + child correlation (DB)" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_public" => %{module: EchoStub, description: "d", model: :fast, max_iterations: 1},
        "echo_restricted" => %{
          module: EchoStub,
          description: "d",
          model: :fast,
          max_iterations: 1,
          forward_context: :none
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
      end)

      :ok
    end

    test "forward_context :none nulls policy keys but keeps tenant_id/session_uuid" do
      %{context: context} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_restricted", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      assert tc.user_id == nil
      assert tc.workspace_uuid == nil
      assert tc.actor == nil
      assert tc.tenant_id == context.tenant
      assert tc.session_uuid == context.session_uuid
    end

    test "child correlation carries the parent's user_id end-to-end" do
      %{context: context, session: session, user_id: user_id} = real_scope_context()

      assert {:ok, _} = AgentRunner.run("echo_public", "go", "s", context)
      assert_receive {:echo_stub, :tool_context, tc}, 5_000
      assert tc.user_id == user_id

      cached =
        :jido_claw_request_correlations
        |> :ets.tab2list()
        |> Enum.filter(fn {_rid, scope} ->
          Map.get(scope, :user_id) == user_id and Map.get(scope, :session_id) == session.id
        end)

      assert cached != []
      {request_id, _scope} = hd(cached)

      case RequestCorrelation.lookup(request_id) do
        {:ok, row} -> assert row.user_id == user_id
        _ -> :ok
      end

      _ = RequestCorrelation.complete(request_id)
      Cache.delete(request_id)
    end
  end

  # Builds a real tenant/workspace/session and a Reactor-style context carrying
  # the full scope (the shape ReactorRunner merges into the context).
  defp real_scope_context do
    tenant_id = "tenant-ar-#{System.unique_integer([:positive])}"
    project_dir = "/tmp/ar-#{System.unique_integer([:positive])}"
    user_id = "00000000-0000-0000-0000-0000ffff0001"

    {:ok, workspace} = JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir)

    {:ok, session} =
      JidoClaw.Conversations.Resolver.ensure_session(
        tenant_id,
        workspace.id,
        :api,
        "ext-#{System.unique_integer([:positive])}"
      )

    context = %{
      tenant: tenant_id,
      actor: %{kind: :system, tenant_id: tenant_id},
      session_id: "runtime-sess",
      session_uuid: session.id,
      workspace_id: "runtime-ws",
      workspace_uuid: workspace.id,
      user_id: user_id,
      project_dir: project_dir
    }

    %{context: context, session: session, user_id: user_id}
  end
end

# ---------------------------------------------------------------------------
# FakeAgentServers — stub `Jido.AgentServer.await_completion/2` for the async
# path (ported from the retired StepActionTest).
# ---------------------------------------------------------------------------

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ValidatedFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{verdict: :pass, confidence: :high, reasoning: "ok"},
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ErrorFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{verdict: :pass, confidence: :high, reasoning: "ok"},
         meta: %{output: %{status: :error, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.SummaryFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{status: :completed, summary: "Implemented foo", files_changed: [], notes: ""},
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.ArtifactsFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: %{
           status: :completed,
           summary: "Started server",
           files_changed: [],
           notes: "",
           artifacts: %{url: "http://localhost:4000", port: 4000}
         },
         meta: %{output: %{status: :validated, schema_kind: :map}}
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.FreeFormFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok,
     %{
       status: :completed,
       result: %{
         status: :completed,
         result: "Started the server.\n\nARTIFACTS:\nurl: http://localhost:4001\nport: 4001\n"
       }
     }}
  end
end

defmodule JidoClaw.Skills.Steps.AgentRunnerTest.FailedFakeAgentServer do
  @moduledoc false
  def await_completion(_pid, _opts) do
    {:ok, %{status: :failed, result: :boom}}
  end
end
