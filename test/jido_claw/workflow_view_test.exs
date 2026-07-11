defmodule JidoClaw.WorkflowViewTest do
  # async: false — the event-read-failure test swaps the reader via
  # ReplayFixtures.put_failing_event_reader!, an Application.put_env of the
  # global :replay_event_reader seam (no per-call injection point), tainting
  # any concurrent reader for the test window.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Test.ReplayFixtures
  alias JidoClaw.Tools.WorkflowEvents
  alias JidoClaw.Tools.WorkflowStatus
  alias JidoClaw.WorkflowView

  setup do
    tenant_a = seed_tenant("workflow-view-a")
    tenant_b = seed_tenant("workflow-view-b")
    {:ok, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  test "list/1 and workflow_status hide runs from other tenants", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b
  } do
    {:ok, run_a} =
      WorkflowRun.create(%{name: "visible", workflow_type: "audit"},
        tenant: tenant_a,
        actor: actor_for(tenant_a)
      )

    {:ok, run_b} =
      WorkflowRun.create(%{name: "hidden", workflow_type: "audit"},
        tenant: tenant_b,
        actor: actor_for(tenant_b)
      )

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant_a})
    assert Enum.map(view.active_runs, & &1.run_id) == [run_a.id]

    assert {:error, :not_found} = WorkflowView.snapshot(run_b.id, %{tenant_id: tenant_a})

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant_a}})
    assert status["active_count"] == 1
    assert Enum.map(status["active_runs"], & &1["run_id"]) == [run_a.id]
  end

  test "tenant scope is required" do
    assert {:error, :tenant_required} = WorkflowView.list(%{})
    assert {:error, %{code: :tenant_required}} = WorkflowStatus.run(%{}, %{tool_context: %{}})
  end

  test "ownership fields ride workflow_status's string-keyed run maps (v1.2)", %{
    tenant_a: tenant
  } do
    {:ok, run} =
      WorkflowRun.create(%{name: "owned", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    assert {:ok, :claimed} = WorkflowLease.stamp(run.id, Ash.UUID.generate(), nil)

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant}})
    assert [row] = status["active_runs"]
    assert row["claimed_by"] == WorkflowLease.node_identity()
    # JsonSafe encodes the raw/frozen claim column to an ISO-8601 string.
    assert {:ok, _dt, _offset} = DateTime.from_iso8601(row["claim_expires_at"])
  end

  test "secrets seeded into result/error never reach MCP output (T2-2 security pin)",
       %{tenant_a: tenant} do
    secret = "sk-" <> String.duplicate("z", 24)

    {:ok, run} =
      WorkflowRun.create(%{name: "leaky", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # WorkflowRun.error/result store RAW values (only event payloads are
    # redacted at append) — corruption-sim them in directly.
    {:ok, _} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{
          status: :failed,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second),
          completed_at: DateTime.utc_now(),
          error: "boom #{secret}",
          result: %{"summary" => "leaked #{secret}", "token" => secret}
        },
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant}})

    encoded = Jason.encode!(status)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED"

    leaky = Enum.find(status["recent_completions"], &(&1["run_id"] == run.id))
    assert leaky["error"] =~ "[REDACTED:API_KEY]"
    # Operator scope: only the filtered summary keys, never the raw result.
    refute Map.has_key?(leaky, "result")
  end

  test "an abandoned run shows as terminal dashboard activity (recent_completions)",
       %{tenant_a: tenant} do
    {:ok, run} =
      WorkflowRun.create(%{name: "given-up", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # Corruption-sim precedent: stamp the terminal via the private projection
    # action. Both Cancel-button paths must surface as terminal activity —
    # without :abandoned in the terminal set the run leaves active_runs and
    # never enters recent_completions, vanishing from the dashboard entirely.
    {:ok, _} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{status: :abandoned, completed_at: DateTime.utc_now()},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant})

    abandoned = Enum.find(view.recent_completions, &(&1.run_id == run.id))
    assert abandoned.status == :abandoned
    refute Enum.any?(view.active_runs, &(&1.run_id == run.id))
  end

  test "an overdue run reports deadline evidence; runs without a policy report nil (T2-1)",
       %{tenant_a: tenant} do
    {:ok, run} =
      WorkflowRun.create(
        %{name: "late-run", workflow_type: "reactor", config: %{deadline: %{within: 60}}},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    {:ok, plain} =
      WorkflowRun.create(%{name: "no-policy", workflow_type: "reactor"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # Started 5 minutes ago, still running — a 60s policy is overdue.
    # Corruption-sim precedent: stamp via the private projection action.
    {:ok, _} =
      run
      |> Ash.Changeset.for_update(
        :set_status,
        %{status: :running, started_at: DateTime.add(DateTime.utc_now(), -300, :second)},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant})

    late = Enum.find(view.active_runs, &(&1.run_id == run.id))
    assert late.deadline.status == :overdue
    assert late.deadline.overdue_by_ms > 0
    assert %DateTime{} = late.deadline.due_at

    # No policy / not-yet-started -> nil, additive key only.
    no_policy = Enum.find(view.active_runs, &(&1.run_id == plain.id))
    assert Map.has_key?(no_policy, :deadline)
    assert is_nil(no_policy.deadline)

    # The MCP tool inherits additively and JSON-safely.
    assert {:ok, status} = WorkflowStatus.run(%{}, %{tool_context: %{tenant_id: tenant}})
    mcp_late = Enum.find(status["active_runs"], &(&1["run_id"] == run.id))
    assert mcp_late["deadline"]["status"] == "overdue"
    assert is_binary(mcp_late["deadline"]["due_at"])
  end

  # AR-2 Phase 5 (§10.2): the PRE-projection snapshot shape — atom top-level
  # keys, an atom `composer.reason`. (The `JsonSafe.encode/1` atom→string flip
  # lives in the `InspectWorkflow` tool, asserted in its own test.)
  describe "snapshot/2 composer-awareness" do
    test "a composer run with composer events carries :composer (available + route/ran/held)",
         %{tenant_a: tenant} do
      run = composer_run!(tenant, "composer-with-events")
      append!(run, :route_composed, composed_payload(), tenant)
      append!(run, :wave_started, %{wave_index: 0, stages: ["planner"]}, tenant)
      append!(run, :wave_completed, %{wave_index: 0, stages: ["planner"]}, tenant)

      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})

      # Top-level keys stay atoms (the operator base view is untouched).
      assert snapshot.run_id == run.id
      assert snapshot.workflow_type == "composer"

      composer = snapshot.composer
      assert composer.available == true
      assert composer.route == ["planner", "implementer"]
      assert composer.ran == ["planner"]
      assert composer.held == %{"implementer" => "needs-tests"}

      # No parked gate child → the reliable signal is present and false.
      assert composer.awaiting_approval_available == true
      assert composer.awaiting_approval == false
      assert composer.awaiting_child_run_ids == []
    end

    test "an :awaiting_approval child reports awaiting_approval: true + the child id",
         %{tenant_a: tenant} do
      parent = composer_run!(tenant, "parent")
      append!(parent, :route_composed, %{route: ["plan-gate"], waves: [["plan-gate"]]}, tenant)
      append!(parent, :wave_started, %{wave_index: 0, stages: ["plan-gate"]}, tenant)

      {:ok, child} =
        WorkflowRun.create(
          %{name: "gate-wave", workflow_type: "reactor", parent_run_id: parent.id},
          tenant: tenant,
          actor: actor_for(tenant)
        )

      # Drive the child to :awaiting_approval via the real projection path.
      append!(child, :run_started, %{}, tenant)
      append!(child, :approval_requested, %{}, tenant)

      assert {:ok, snapshot} = WorkflowView.snapshot(parent.id, %{tenant_id: tenant})

      composer = snapshot.composer
      assert composer.available == true
      assert composer.awaiting_approval == true
      assert composer.awaiting_child_run_ids == [child.id]
      # The parent stays :running across the child gate pause (§6).
      assert snapshot.status == :running
    end

    test "a composer run with no composer events reports not_yet_composed (atom reason)",
         %{tenant_a: tenant} do
      run = composer_run!(tenant, "fresh-composer")

      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})
      assert snapshot.composer == %{available: false, reason: :not_yet_composed}
    end

    # Camus C1-3: `:stage_infra` is in the O-M1 kind filter, so the observe view
    # sees the wave-error lane's closing marker — a lane-B run reads
    # wave_in_flight: false, not in-flight forever.
    test "a lane-B stage_infra (closed_wave_index) closes the wave in the snapshot",
         %{tenant_a: tenant} do
      run = composer_run!(tenant, "lane-b-infra")
      append!(run, :route_composed, composed_payload(), tenant)
      append!(run, :wave_started, %{wave_index: 0, stages: ["planner"]}, tenant)

      append!(
        run,
        :stage_infra,
        %{stages: ["planner"], closed_wave_index: 0},
        tenant
      )

      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})

      composer = snapshot.composer
      assert composer.available == true
      assert composer.wave_in_flight == false
      # An infra'd stage was never folded — ran stays empty.
      assert composer.ran == []
    end

    test "a non-composer run carries no :composer key", %{tenant_a: tenant} do
      {:ok, run} =
        WorkflowRun.create(%{name: "plain", workflow_type: "reactor"},
          tenant: tenant,
          actor: actor_for(tenant)
        )

      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})
      refute Map.has_key?(snapshot, :composer)
    end

    # Camus C1-4: the stall park is CHILD-LESS — nothing is :awaiting_approval;
    # the parent-bound pending review_stall case is the only durable signal,
    # and the gate block must reflect it (awaiting_approval flips true too).
    test "a parent-bound pending review_stall case flips review_stall_pending + awaiting_approval",
         %{tenant_a: tenant} do
      parent = composer_run!(tenant, "stall-parked")
      append!(parent, :route_composed, composed_payload(), tenant)
      append!(parent, :wave_started, %{wave_index: 0, stages: ["planner"]}, tenant)
      append!(parent, :wave_completed, %{wave_index: 0, stages: ["planner"]}, tenant)

      {:ok, gate} =
        WorkflowLog.case_open_runbound(
          parent,
          %{
            workflow_run_id: parent.id,
            step_name: "review-stall",
            fingerprint: "stall-fp-1",
            details: %{"finding_keys" => ["k1"], "resume_hint" => "waive or reject"}
          },
          tenant: tenant,
          actor: actor_for(tenant)
        )

      assert {:ok, snapshot} = WorkflowView.snapshot(parent.id, %{tenant_id: tenant})

      composer = snapshot.composer
      assert composer.review_stall_pending == true
      assert composer.review_stall_case_id == gate.id
      assert composer.resume_hint == "waive or reject"
      # No child is parked, yet the run IS blocked on an operator decision.
      assert composer.awaiting_approval == true
      assert composer.awaiting_child_run_ids == []
      # The parent stays :running across the stall park.
      assert snapshot.status == :running
    end

    test "no pending review_stall case reads review_stall_pending: false",
         %{tenant_a: tenant} do
      run = composer_run!(tenant, "no-stall")
      append!(run, :route_composed, composed_payload(), tenant)
      append!(run, :wave_started, %{wave_index: 0, stages: ["planner"]}, tenant)
      append!(run, :wave_completed, %{wave_index: 0, stages: ["planner"]}, tenant)

      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})
      assert snapshot.composer.review_stall_pending == false
      refute Map.has_key?(snapshot.composer, :resume_hint)
    end
  end

  describe "camus C1-4 disposition surfaces" do
    test "a done_with_findings completion carries disposition + count; the rollup sums findings_deferred",
         %{tenant_a: tenant} do
      run = composer_run!(tenant, "deferred")

      append!(
        run,
        :route_done_with_findings,
        %{
          result: %{
            "disposition" => "done_with_findings",
            "finding_keys" => ["k1", "k2"],
            "findings_deferred_count" => 2
          }
        },
        tenant
      )

      assert {:ok, view} = WorkflowView.list(%{tenant_id: tenant})
      completed = Enum.find(view.recent_completions, &(&1.run_id == run.id))

      assert completed.status == :completed
      assert completed.disposition == "done_with_findings"
      assert completed.findings_deferred_count == 2
      assert view.findings_deferred == 2

      # A plain run map keeps the keys, nil-valued (never plain-missing).
      assert {:ok, snapshot} = WorkflowView.snapshot(run.id, %{tenant_id: tenant})
      assert snapshot.disposition == "done_with_findings"
      assert snapshot.findings_deferred_count == 2
    end
  end

  describe "event_feed/3" do
    test "accepts opts as a keyword list AND an atom-keyed map (both contract shapes)",
         %{tenant_a: tenant} do
      run = feed_run!(tenant, 3)

      assert {:ok, from_kw} = WorkflowView.event_feed(run.id, %{tenant_id: tenant}, limit: 2)
      assert {:ok, from_map} = WorkflowView.event_feed(run.id, %{tenant_id: tenant}, %{limit: 2})

      assert from_kw.count == 2
      assert from_map.count == 2
      assert Enum.map(from_kw.events, & &1["seq"]) == [1, 2]
      assert Enum.map(from_map.events, & &1["seq"]) == [1, 2]
      assert from_kw.next_seq == 2
      assert from_map.next_seq == 2
    end

    test "a page is byte-bounded, not merely count-bounded", %{tenant_a: tenant} do
      run = feed_run!(tenant, 0)
      big = String.duplicate("x", 20_000)
      for i <- 1..5, do: append!(run, :artifacts_produced, %{"blob" => big, "i" => i}, tenant)

      # Requested 5, but the 24 KB page budget stops it short — byte-, not count-trim.
      assert {:ok, feed} = WorkflowView.event_feed(run.id, %{tenant_id: tenant}, limit: 5)
      assert feed.count < 5
      assert feed.next_seq != nil
      assert byte_size(Jason.encode!(feed.events)) <= 24 * 1024
    end

    test "a single oversized event is fit to a bounded marker, never dropped",
         %{tenant_a: tenant} do
      run = feed_run!(tenant, 0)
      huge = String.duplicate("y", 100_000)
      append!(run, :artifacts_produced, %{"blob" => huge}, tenant)

      assert {:ok, feed} = WorkflowView.event_feed(run.id, %{tenant_id: tenant}, limit: 5)
      assert feed.count == 1
      [event] = feed.events
      assert event["truncated"] == true
      assert is_map(event["payload"])
      assert event["payload"]["truncated"] == true
      assert byte_size(Jason.encode!(event)) <= 24 * 1024
    end

    test "an event-read failure surfaces :event_feed_unavailable, never an empty feed",
         %{tenant_a: tenant} do
      run = feed_run!(tenant, 2)
      # Force the read (through the same EventReader seam the impl uses) to fail.
      ReplayFixtures.put_failing_event_reader!()

      # Direct API: the raw tuple.
      assert {:error, :event_feed_unavailable} =
               WorkflowView.event_feed(run.id, %{tenant_id: tenant}, [])

      # Through the tool: the normalized wire error.
      assert {:error, %{code: :event_feed_unavailable}} =
               WorkflowEvents.run(%{run_id: run.id}, %{tool_context: %{tenant_id: tenant}})
    end

    test "unknown run id and a cross-tenant run are both not_found",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      run = feed_run!(tenant_a, 1)

      assert {:error, :not_found} =
               WorkflowView.event_feed(Ash.UUID.generate(), %{tenant_id: tenant_a}, [])

      assert {:error, :not_found} = WorkflowView.event_feed(run.id, %{tenant_id: tenant_b}, [])
    end

    test "tenant scope is required", %{tenant_a: tenant} do
      run = feed_run!(tenant, 1)
      assert {:error, :tenant_required} = WorkflowView.event_feed(run.id, %{}, [])
    end
  end

  # -- composer test helpers --

  # A run carrying `count` non-status-authority events (seq 1..count); it stays
  # :pending, so seq counting is clean. `count: 0` seeds an empty run for the
  # byte-budget / oversized-event tests to append their own large payloads.
  defp feed_run!(tenant, count) do
    {:ok, run} =
      WorkflowRun.create(%{name: "feed", workflow_type: "composer"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    for i <- 1..count//1, do: append!(run, :signals_published, %{"n" => i}, tenant)
    run
  end

  defp composer_run!(tenant, name) do
    {:ok, run} =
      WorkflowRun.create(%{name: name, workflow_type: "composer"},
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # Genesis: run_started flips the parent to :running (the real composer path).
    append!(run, :run_started, %{}, tenant)
    run
  end

  defp composed_payload do
    %{
      route: ["planner", "implementer"],
      waves: [["planner"], ["implementer"]],
      held: %{"implementer" => "needs-tests"},
      dropped: %{},
      triggered_by: %{},
      size: 2,
      live: ["code", "plan-ready"],
      available: ["plan"],
      premises: %{}
    }
  end

  defp append!(run, kind, payload, tenant) do
    {:ok, _} = WorkflowLog.append(run, kind, payload, tenant: tenant, actor: actor_for(tenant))
  end
end
