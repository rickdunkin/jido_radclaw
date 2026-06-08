defmodule JidoClaw.Orchestration.WorkflowEventTest do
  @moduledoc """
  Pins the append-only `WorkflowEvent` log and its projection-owned status:

    * `seq` is allocated monotonically per run (sequential + concurrent);
    * `for_run` is tenant-isolated;
    * payloads are redacted on the way in;
    * status-authority kinds flip `WorkflowRun.status` in the same txn, and
      the materialized column equals the `seq`-ordered fold;
    * the transition guard rolls back illegal appends (event + status);
    * the run's `result`/`error` columns keep raw values while the durable
      event payload is redacted (the Phase 0 boundary);
    * `append_all/3` is atomic — a mid-batch failure persists nothing.
  """
  use JidoClaw.TenantCase

  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  setup do
    tenant = seed_tenant("wfevent")
    {:ok, run} = WorkflowRun.create(%{name: "run"}, tenant: tenant, actor: actor_for(tenant))
    {:ok, tenant: tenant, run: run}
  end

  describe "seq allocation" do
    test "appends allocate ascending seq 1,2,3", %{run: run} do
      {:ok, e1} = WorkflowLog.append(run, :step_started, %{})
      {:ok, e2} = WorkflowLog.append(run, :step_completed, %{})
      {:ok, e3} = WorkflowLog.append(run, :step_started, %{})

      assert [e1.seq, e2.seq, e3.seq] == [1, 2, 3]
    end

    test "N concurrent appends to one run yield unique 1..N seq", %{run: run} do
      n = 10

      results =
        1..n
        |> Enum.map(fn _ -> Task.async(fn -> WorkflowLog.append(run, :step_started, %{}) end) end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      seqs = results |> Enum.map(fn {:ok, e} -> e.seq end) |> Enum.sort()
      assert seqs == Enum.to_list(1..n)
    end
  end

  describe "tenant isolation" do
    test "for_run does not leak one tenant's events to another", %{tenant: tenant_a, run: run_a} do
      {:ok, _} = WorkflowLog.append(run_a, :step_started, %{})
      tenant_b = seed_tenant("wfevent-b")

      assert {:ok, []} =
               WorkflowEvent.for_run(run_a.id, tenant: tenant_b, actor: actor_for(tenant_b))

      assert {:ok, [_]} =
               WorkflowEvent.for_run(run_a.id, tenant: tenant_a, actor: actor_for(tenant_a))
    end
  end

  describe "redaction" do
    test "sensitive keys in the event payload are stored [REDACTED]", %{
      tenant: tenant,
      run: run
    } do
      {:ok, _} =
        WorkflowLog.append(run, :step_started, %{
          "password" => "x",
          "api_key" => "sk-aaaaaaaaaaaaaaaaaaaaaa",
          "note" => "ok"
        })

      {:ok, [stored]} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

      assert stored.payload["password"] == "[REDACTED]"
      assert stored.payload["api_key"] == "[REDACTED]"
      assert stored.payload["note"] == "ok"
    end
  end

  describe "status projection (same transaction)" do
    test "run_started flips status to :running and stamps started_at", %{tenant: tenant, run: run} do
      {:ok, event} = WorkflowLog.append(run, :run_started, %{})
      {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))

      assert reloaded.status == :running
      assert reloaded.started_at == event.occurred_at
    end

    test "run_started -> run_completed projects to :completed and column == fold", %{
      tenant: tenant,
      run: run
    } do
      {:ok, _} = WorkflowLog.append(run, :run_started, %{})
      {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      {:ok, _} = WorkflowLog.append(running, :run_completed, %{result: %{"ok" => true}})

      {:ok, done} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))

      assert done.status == :completed
      assert Projection.project_status(events) == done.status
    end

    test "run_failed projects to :failed", %{tenant: tenant, run: run} do
      {:ok, _} = WorkflowLog.append(run, :run_started, %{})
      {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      {:ok, _} = WorkflowLog.append(running, :run_failed, %{error: "boom"})

      {:ok, failed} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      assert failed.status == :failed
      assert failed.error == "boom"
    end

    test "a non-authority kind leaves status unchanged", %{tenant: tenant, run: run} do
      {:ok, _} = WorkflowLog.append(run, :step_started, %{})
      {:ok, _} = WorkflowLog.append(run, :run_recovered, %{reason: "x"})

      {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      assert reloaded.status == :pending
    end
  end

  describe "transition guard" do
    test "run_completed on a :pending run is rejected; nothing persists", %{
      tenant: tenant,
      run: run
    } do
      assert {:error, _} = WorkflowLog.append(run, :run_completed, %{result: %{}})

      assert {:ok, []} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
      {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      assert reloaded.status == :pending
    end

    test "a terminal -> terminal append is rejected", %{tenant: tenant, run: run} do
      {:ok, _} = WorkflowLog.append(run, :run_started, %{})
      {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      {:ok, _} = WorkflowLog.append(running, :run_completed, %{})
      {:ok, completed} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))

      assert {:error, _} = WorkflowLog.append(completed, :run_failed, %{error: "late"})

      {:ok, still} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      assert still.status == :completed
    end
  end

  describe "raw/redacted boundary (Phase 0)" do
    test "event payload is redacted but the run.result column keeps raw values", %{
      tenant: tenant,
      run: run
    } do
      {:ok, _} = WorkflowLog.append(run, :run_started, %{})
      {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))

      {:ok, _} =
        WorkflowLog.append(running, :run_completed, %{
          result: %{"token" => "rawsecretvalue", "data" => "ok"}
        })

      {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
      completed = Enum.find(events, &(&1.kind == :run_completed))
      {:ok, done} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))

      # durable event payload: key-based redaction
      assert completed.payload["result"]["token"] == "[REDACTED]"
      assert completed.payload["result"]["data"] == "ok"

      # run column: raw, unredacted
      assert done.result["token"] == "rawsecretvalue"
      assert done.result["data"] == "ok"
    end
  end

  describe "append_all/3 atomicity" do
    test "a mid-batch failure rolls the whole batch back", %{tenant: tenant, run: run} do
      {:ok, _} = WorkflowLog.append(run, :run_started, %{})
      {:ok, running} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))

      # Second append (run_started) is illegal from :running -> the after_action
      # transition guard fails it naturally, so Ash.transact rolls the batch back.
      assert {:error, _} =
               WorkflowLog.append_all(
                 running,
                 [{:run_recovered, %{}}, {:run_started, %{}}],
                 tenant: tenant,
                 actor: actor_for(tenant)
               )

      {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor_for(tenant))
      refute Enum.any?(events, &(&1.kind == :run_recovered))

      {:ok, still} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor_for(tenant))
      assert still.status == :running
    end

    test "an empty event list is a no-op error", %{run: run} do
      assert {:error, :no_events} = WorkflowLog.append_all(run, [], tenant: run.tenant_id)
    end
  end
end
