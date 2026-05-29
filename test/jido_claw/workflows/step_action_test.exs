defmodule JidoClaw.Workflows.StepActionTest do
  @moduledoc """
  Unit tests for the `:user_id` propagation path through `StepAction`.
  The pre-existing scope-propagation suite covers tenant/session/workspace
  attribution; this suite extends the same model to `:user_id` because
  workflow-launched child agents must inherit the parent's user scope so
  audit trails carry user attribution through nested skills.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Conversations.RequestCorrelation
  alias JidoClaw.Conversations.RequestCorrelation.Cache
  alias JidoClaw.Test.{EchoAskStub, EchoStub}
  alias JidoClaw.Workflows.{SkillWorkflow, StepAction, StepResult}

  describe "resolve_scope/3 — :user_id" do
    test "carries :user_id from context.tool_context into the resolved scope" do
      ctx = %{
        tool_context: %{
          tenant_id: "t",
          session_uuid: "00000000-0000-0000-0000-000000000001",
          workspace_uuid: "00000000-0000-0000-0000-000000000002",
          user_id: "00000000-0000-0000-0000-000000000099",
          project_dir: "/tmp"
        }
      }

      scope = StepAction.resolve_scope(%{}, ctx, "tag-ctx")

      assert scope.user_id == "00000000-0000-0000-0000-000000000099"
    end

    test "params win over context.tool_context for :user_id" do
      params = %{user_id: "00000000-0000-0000-0000-0000000000aa"}

      ctx = %{
        tool_context: %{
          user_id: "00000000-0000-0000-0000-0000000000bb"
        }
      }

      scope = StepAction.resolve_scope(params, ctx, "tag-params")

      assert scope.user_id == "00000000-0000-0000-0000-0000000000aa"
    end

    test "top-level context (not under :tool_context) is also consulted" do
      scope = StepAction.resolve_scope(%{}, %{user_id: "raw-uid"}, "tag-raw")
      assert scope.user_id == "raw-uid"
    end

    test "missing user_id falls back to nil" do
      scope = StepAction.resolve_scope(%{}, %{}, "tag-none")
      assert scope.user_id == nil
    end
  end

  # Exercises register_child_correlation/1 indirectly: the
  # SkillWorkflow boots an `EchoStub`-backed child agent, StepAction.run/2
  # registers the child correlation against the resolved scope, and the
  # echo stub forwards the resulting tool_context (which now has the
  # correlated request_id) back to the test process. We then read the
  # `RequestCorrelation` row keyed by that request_id and verify it
  # carries the user_id from the parent's scope.
  describe "register_child_correlation/1 — user_id propagation through SkillWorkflow" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_user_test" => %{
          module: EchoStub,
          description: "test-only echo template",
          model: :fast,
          max_iterations: 1
        }
      })

      Application.put_env(:jido_claw, :echo_stub_target, self())

      on_exit(fn ->
        Application.delete_env(:jido_claw, :agent_templates_override)
        Application.delete_env(:jido_claw, :echo_stub_target)
      end)

      :ok
    end

    test "child correlation carries the parent's user_id (DB row + cache mirror)" do
      tenant_id = "tenant-stepa-#{System.unique_integer([:positive])}"
      project_dir = "/tmp/stepa-#{System.unique_integer([:positive])}"

      {:ok, workspace} =
        JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir)

      {:ok, session} =
        JidoClaw.Conversations.Resolver.ensure_session(
          tenant_id,
          workspace.id,
          :api,
          "ext-#{System.unique_integer([:positive])}"
        )

      user_id = "00000000-0000-0000-0000-0000ffff0001"

      parent_scope = %{
        tenant_id: tenant_id,
        session_id: "runtime-sess",
        session_uuid: session.id,
        workspace_id: "runtime-ws",
        workspace_uuid: workspace.id,
        user_id: user_id,
        project_dir: project_dir
      }

      skill = %JidoClaw.Skills{
        name: "user_id_smoke",
        steps: [
          %{
            "name" => "echo_step",
            "template" => "echo_user_test",
            "task" => "echo"
          }
        ],
        synthesis: "n/a"
      }

      assert {:ok, [_]} =
               SkillWorkflow.run(skill, "", project_dir, scope_context: parent_scope)

      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      # Primary contract: tool_context propagates :user_id end-to-end.
      assert tc.user_id == user_id

      # The dispatcher caches every correlation it registers (even on
      # Postgres write failure), so the request_id minted by
      # `register_child_correlation/1` lives in the in-memory cache
      # mirror. Find the entry by its user_id + session_id pair.
      cached_entries =
        :ets.tab2list(:jido_claw_request_correlations)
        |> Enum.filter(fn {_rid, scope} ->
          Map.get(scope, :user_id) == user_id and
            Map.get(scope, :session_id) == session.id
        end)

      assert cached_entries != [], """
      Expected the correlation cache to contain an entry with
      user_id=#{user_id} for session=#{session.id}; current entries:
        #{inspect(:ets.tab2list(:jido_claw_request_correlations), limit: 10)}
      """

      {request_id, _scope} = hd(cached_entries)

      # The Postgres-side row may also exist (the dispatcher writes through
      # to the durable table when the changeset accepts it). When it does,
      # it must carry the same user_id — anything else means the workflow
      # path dropped attribution between the cache and the durable write.
      case RequestCorrelation.lookup(request_id) do
        {:ok, row} -> assert row.user_id == user_id
        _ -> :ok
      end

      # Cleanup so other tests don't inherit our entry.
      _ = RequestCorrelation.complete(request_id)
      Cache.delete(request_id)
    end
  end

  # Exercises the B3 enforcement site in `run/2`: the template's
  # forward_context policy is applied (via ToolContext.apply_visibility)
  # to the resolved scope BEFORE building the child tool_context, so the
  # worker never sees the stripped keys.
  describe "run/2 — forward_context policy" do
    setup do
      pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)

      Application.put_env(:jido_claw, :agent_templates_override, %{
        "echo_restricted" => %{
          module: EchoStub,
          description: "test-only restricted echo template",
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

    test "nulls policy-controlled keys but keeps tenant_id/session_uuid intact" do
      tenant_id = "tenant-fc-#{System.unique_integer([:positive])}"
      project_dir = "/tmp/fc-#{System.unique_integer([:positive])}"

      {:ok, workspace} = JidoClaw.Workspaces.Resolver.ensure_workspace(tenant_id, project_dir)

      {:ok, session} =
        JidoClaw.Conversations.Resolver.ensure_session(
          tenant_id,
          workspace.id,
          :api,
          "ext-#{System.unique_integer([:positive])}"
        )

      scope = %{
        tenant_id: tenant_id,
        session_uuid: session.id,
        workspace_uuid: workspace.id,
        user_id: "00000000-0000-0000-0000-0000ffff0002",
        actor: %{kind: :system},
        project_dir: project_dir
      }

      assert {:ok, _} =
               StepAction.run(%{template: "echo_restricted", task: "go"}, %{tool_context: scope})

      assert_receive {:echo_stub, :tool_context, tc}, 5_000

      # Policy-controlled keys are nulled before the worker sees them.
      assert tc.user_id == nil
      assert tc.workspace_uuid == nil
      assert tc.actor == nil

      # Structural keys survive so correlation + trace linkage keep working.
      assert tc.tenant_id == tenant_id
      assert tc.session_uuid == session.id
    end
  end

  # Covers the `run_step_async` branch — `EchoStub` only implements
  # `ask_sync/3`, so without a stub that exports `ask/3` the
  # `function_exported?` check at `run_step/7` always falls through to
  # the sync path and the typed_output capture in `await_step/4` is
  # untested.
  describe "run_step_async/7 — typed_output capture" do
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
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.ValidatedFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.typed_output == %{
               verdict: :pass,
               confidence: :high,
               reasoning: "ok"
             }

      assert is_binary(step_result.result)
      assert step_result.result != ""
    end

    test "leaves typed_output nil when meta.output.status is :error" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.ErrorFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.typed_output == nil
      assert is_binary(step_result.result)
    end

    test "projects typed_output[:summary] to StepResult.result (prose, not inspect)" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.SummaryFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.result == "Implemented foo"
      assert step_result.typed_output.summary == "Implemented foo"
    end

    test "merges typed_output[:artifacts] into StepResult.artifacts (stringified)" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.ArtifactsFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.artifacts["url"] == "http://localhost:4000"
      assert step_result.artifacts["port"] == "4000"
    end

    test "free-form path still extracts artifacts from ARTIFACTS: regex" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.FreeFormFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.typed_output == nil
      assert step_result.artifacts["url"] == "http://localhost:4001"
      assert step_result.artifacts["port"] == "4001"
    end

    test "carries :repaired typed output through to StepResult.typed_output" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.RepairedFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert step_result.typed_output == %{
               status: :completed,
               summary: "Repaired into shape",
               files_changed: ["lib/foo.ex"],
               notes: "n/a"
             }

      assert step_result.result == "Repaired into shape"
    end

    test "round-trips a fully string-keyed inner request map" do
      Application.put_env(
        :jido_claw,
        :step_agent_server,
        JidoClaw.Workflows.StepActionTest.StringKeyedFakeAgentServer
      )

      assert {:ok, %StepResult{} = step_result} =
               StepAction.run(
                 %{template: "echo_async", task: "go", project_dir: "/tmp", name: "async_step"},
                 %{}
               )

      assert Map.get(step_result.typed_output, "summary") == "Started server"
      assert step_result.result == "Started server"
      assert step_result.artifacts["url"] == "http://localhost:4000"
      assert step_result.artifacts["port"] == "4000"
    end
  end

  defmodule ValidatedFakeAgentServer do
    @moduledoc false

    # Mimics Jido.AgentServer.await_completion for a request that
    # produced a Jido.AI structured output. Only the two shapes the
    # test exercises are implemented; anything else raises so unexpected
    # callers fail loudly rather than masking a regression.
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

  defmodule ErrorFakeAgentServer do
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

  defmodule SummaryFakeAgentServer do
    @moduledoc false

    # Mimics a Coder-style schema'd worker — typed result has :summary,
    # which should flow through to StepResult.result as prose.
    def await_completion(_pid, _opts) do
      {:ok,
       %{
         status: :completed,
         result: %{
           status: :completed,
           result: %{
             status: :completed,
             summary: "Implemented foo",
             files_changed: ["lib/foo.ex"],
             notes: "n/a"
           },
           meta: %{output: %{status: :validated, schema_kind: :map}}
         }
       }}
    end
  end

  defmodule ArtifactsFakeAgentServer do
    @moduledoc false

    # Typed output carries an :artifacts sub-map — should be merged
    # into StepResult.artifacts (stringified) so downstream consumers
    # see the same shape as the free-form regex path.
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

  defmodule FreeFormFakeAgentServer do
    @moduledoc false

    # Worker without a schema — meta absent, result is free-form text.
    # Regression cover for the path that pulls artifacts from a fenced
    # ARTIFACTS: block via regex.
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

  defmodule RepairedFakeAgentServer do
    @moduledoc false

    # Repaired round-trip: meta.output.status == :repaired should still
    # flow the typed map through (typed_request_output accepts both
    # :validated and :repaired).
    def await_completion(_pid, _opts) do
      {:ok,
       %{
         status: :completed,
         result: %{
           status: :completed,
           result: %{
             status: :completed,
             summary: "Repaired into shape",
             files_changed: ["lib/foo.ex"],
             notes: "n/a"
           },
           meta: %{output: %{status: :repaired, schema_kind: :map}}
         }
       }}
    end
  end

  defmodule StringKeyedFakeAgentServer do
    @moduledoc false

    # End-to-end string-keyed round-trip: the *inner* request map (meta +
    # result + artifacts) is fully string-keyed (the shape a JSON-decoded
    # request map produces). The outer envelope matches what
    # Jido.AgentServer.await_completion emits.
    def await_completion(_pid, _opts) do
      {:ok,
       %{
         status: :completed,
         result: %{
           "status" => "completed",
           "result" => %{
             "status" => "completed",
             "summary" => "Started server",
             "files_changed" => [],
             "notes" => "",
             "artifacts" => %{"url" => "http://localhost:4000", "port" => "4000"}
           },
           "meta" => %{"output" => %{"status" => "validated", "schema_kind" => "map"}}
         }
       }}
    end
  end
end
