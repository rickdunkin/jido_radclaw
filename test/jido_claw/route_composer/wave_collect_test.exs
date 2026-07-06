defmodule JidoClaw.RouteComposer.Steps.WaveCollectTest do
  @moduledoc """
  Camus C1-5 (next-ten #6) — the child-result serialization boundary: reviewer
  emissions cross it through `WaveCollect`'s json-safe terminal map and are
  rehydrated by `StageEmission.from_map/1`, so `finding_marks` MUST survive
  the round-trip (an unencoded field silently vanishes — the review High
  finding this test pins). `certification` never needed this: verify
  emissions are built by `Reactors.VerifyStage`, which bypasses WaveCollect.

  Non-async (`TenantCase`): persists artifact rows through the real
  `ComposerArtifact` store.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.StageEmission
  alias JidoClaw.RouteComposer.Steps.WaveCollect
  alias JidoClaw.Workflows.StepResult

  setup do
    tenant_id = seed_tenant("wave-collect")
    actor = actor_for(tenant_id)

    {:ok, parent} =
      WorkflowRun.create(%{name: "p", workflow_type: "composer"}, tenant: tenant_id, actor: actor)

    {:ok, child} =
      WorkflowRun.create(%{name: "w0", workflow_type: "reactor", parent_run_id: parent.id},
        tenant: tenant_id,
        actor: actor
      )

    %{context: %{workflow_run: child, tenant: tenant_id, actor: actor}}
  end

  defp reviewer_meta do
    %{
      name: "quality-reviewer",
      emit: :default,
      lens: "quality",
      output: ["findings"],
      publishes: ["clean:quality", "findings:quality", "scope-shift"]
    }
  end

  defp run_collect(typed_output, ctx) do
    result = %StepResult{name: "quality-reviewer", typed_output: typed_output}

    WaveCollect.run(%{quality: result}, ctx.context,
      stage_meta: [{:quality, reviewer_meta()}],
      wave_index: 0
    )
  end

  test "a findings verdict's finding_marks survive the to_map → from_map round-trip", ctx do
    typed = %{
      "overall" => "request_changes",
      "summary" => "found a defect",
      "action_needed" => "guard the deref",
      "findings" => [
        %{
          "title" => "missing nil check",
          "severity" => "error",
          "confidence" => "likely",
          "location" => "lib/auth.ex:42",
          "description" => "nil deref on the happy path"
        },
        # Un-keyable (no title) — excluded from keys/marks, still a finding.
        %{
          "severity" => "warning",
          "confidence" => "unsure",
          "location" => "lib/auth.ex:80",
          "description" => "possible double-fetch"
        }
      ]
    }

    assert {:ok, %{"wave_index" => 0, "emissions" => [encoded]}} = run_collect(typed, ctx)

    # The encoded map is the persisted child-result shape (string keys).
    assert %{"lens" => "quality", "keys" => [key], "marks" => [mark]} =
             encoded["finding_marks"]

    assert key =~ ~r/^[0-9a-f]{64}$/
    assert mark == %{"key" => key, "severity" => "error", "confidence" => "likely"}

    # And the rehydrated emission carries the canonical atom-keyed block.
    emission = StageEmission.from_map(encoded)

    assert emission.finding_marks == %{
             lens: "quality",
             keys: [key],
             marks: [%{key: key, severity: "error", confidence: "likely"}]
           }

    assert emission.signals == ["findings:quality"]
  end

  test "a clean verdict's explicit empty block survives the round-trip", ctx do
    typed = %{
      "overall" => "approve",
      "summary" => "sound",
      "action_needed" => "none",
      "findings" => []
    }

    assert {:ok, %{"emissions" => [encoded]}} = run_collect(typed, ctx)

    assert encoded["finding_marks"] == %{"lens" => "quality", "keys" => [], "marks" => []}

    assert StageEmission.from_map(encoded).finding_marks ==
             %{lens: "quality", keys: [], marks: []}
  end

  test "an infra'd reviewer emission carries NO finding_marks key", ctx do
    assert {:ok, %{"emissions" => [encoded]}} =
             run_collect(%{"overall" => "maybe", "findings" => []}, ctx)

    refute Map.has_key?(encoded, "finding_marks")

    assert %StageEmission{outcome: {:infra, _}, finding_marks: nil} =
             StageEmission.from_map(encoded)
  end
end
