defmodule JidoClaw.Orchestration.ReactorMiddlewareTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.ReactorMiddlewareTest.ErrStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:error, :boom}
end

defmodule JidoClaw.Orchestration.ReactorMiddlewareTest.MapStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:ok, %{answer: 42, note: "hi"}}
end

defmodule JidoClaw.Orchestration.ReactorMiddlewareTest.StructStep do
  @moduledoc false
  use Reactor.Step

  # Returns an Ash-record-like struct — NOT json-safe, so the middleware must
  # store %{} (result stays nil), never persist-then-blow-up on JSON encode.
  @impl true
  def run(_arguments, _context, _options), do: {:ok, %{workspace: ~D[2024-01-01]}}
end

defmodule JidoClaw.Orchestration.ReactorMiddlewareTest do
  @moduledoc """
  Unit-tests the event-producing middleware in isolation, driving a one-step
  `Reactor.Builder` reactor through it:

    * a successful run yields `run_started -> step_started -> step_completed ->
      run_completed`;
    * a `{:error, _}` step yields a terminal `run_failed` carrying the formatted
      error string;
    * a run whose context lacks a `%WorkflowRun{}` returns `{:error, _}` and
      appends nothing (the misconfigured-caller guard).

  Redaction is not re-asserted here — the middleware appends through
  `WorkflowLog.append` -> `Allocate`, whose redaction is already pinned by
  `WorkflowEventTest`; the Phase-1 payloads are fixed identifier/error shapes.
  """
  use JidoClaw.TenantCase

  alias JidoClaw.Orchestration.ReactorMiddleware
  alias JidoClaw.Orchestration.ReactorMiddlewareTest.ErrStep
  alias JidoClaw.Orchestration.ReactorMiddlewareTest.MapStep
  alias JidoClaw.Orchestration.ReactorMiddlewareTest.OkStep
  alias JidoClaw.Orchestration.ReactorMiddlewareTest.StructStep
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias Reactor.Builder

  setup do
    tenant = seed_tenant("reactor-mw")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  test "success path records run_started -> step -> run_completed", ctx do
    run = create_run("mw-ok", ctx)

    assert {:ok, :done} =
             Reactor.run(build(OkStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    assert kinds(run, ctx) == [:run_started, :step_started, :step_completed, :run_completed]
  end

  test "failed step yields a terminal run_failed with a formatted error", ctx do
    run = create_run("mw-err", ctx)

    assert {:error, _} =
             Reactor.run(build(ErrStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    events = events_for(run, ctx)
    kinds = Enum.map(events, & &1.kind)

    assert :run_started in kinds
    assert :step_failed in kinds
    assert [:run_failed | _] = Enum.reverse(kinds)

    failed = Enum.find(events, &(&1.kind == :run_failed))
    assert is_binary(failed.payload["error"])
  end

  test "a context missing the WorkflowRun returns an error and appends nothing", ctx do
    %{tenant: tenant, actor: actor} = ctx
    run = create_run("mw-bad", ctx)
    # Context lacks :workflow_run, so init/1 bails before any append.
    bad_context = %{tenant: tenant, actor: actor}

    assert {:error, _} =
             Reactor.run(build(OkStep), %{}, bad_context, async?: false, run_id: run.id)

    assert events_for(run, ctx) == []
  end

  test "run_started payload carries definition_hash when one was stamped on the run", ctx do
    %{tenant: tenant, actor: actor} = ctx

    {:ok, run} =
      WorkflowRun.create(%{name: "mw-hash", definition_hash: "deadbeef"},
        tenant: tenant,
        actor: actor
      )

    assert {:ok, :done} =
             Reactor.run(build(OkStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    started =
      run
      |> events_for(ctx)
      |> Enum.find(&(&1.kind == :run_started))

    assert started.payload["definition_hash"] == "deadbeef"
  end

  test "run_started payload omits definition_hash when none was stamped", ctx do
    run = create_run("mw-nohash", ctx)

    assert {:ok, :done} =
             Reactor.run(build(OkStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    started =
      run
      |> events_for(ctx)
      |> Enum.find(&(&1.kind == :run_started))

    refute Map.has_key?(started.payload, "definition_hash")
  end

  test "captures a json-safe return value into run.result (closes the regression)", ctx do
    run = create_run("mw-result", ctx)

    assert {:ok, %{answer: 42, note: "hi"}} =
             Reactor.run(build(MapStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    %{tenant: tenant, actor: actor} = ctx
    {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)
    # Persisted result round-trips through JSONB → string keys.
    assert reloaded.result == %{"answer" => 42, "note" => "hi"}
  end

  test "a non-json-safe return value leaves run.result nil (stores %{})", ctx do
    run = create_run("mw-struct", ctx)

    assert {:ok, %{workspace: _date}} =
             Reactor.run(build(StructStep), %{}, context(run, ctx), async?: false, run_id: run.id)

    %{tenant: tenant, actor: actor} = ctx
    {:ok, reloaded} = WorkflowRun.by_id(run.id, tenant: tenant, actor: actor)
    assert reloaded.result == nil
    # The run still completed cleanly — the guard prevents the crash, not the run.
    assert reloaded.status == :completed
  end

  describe "json_safe?/1 (persistence boundary)" do
    test "accepts the CollectStep-shaped build_result map" do
      build_result = %{
        skill: "full_review",
        steps_completed: 3,
        synthesis_prompt: "present",
        results: "## Step 1: …",
        message: "Skill 'full_review' completed 3 steps. …"
      }

      assert ReactorMiddleware.json_safe?(build_result)
    end

    test "accepts nested lists/maps of binaries, numbers, booleans, nil" do
      assert ReactorMiddleware.json_safe?(%{a: [1, "two", %{b: nil, c: true}], d: 3.5})
      assert ReactorMiddleware.json_safe?([])
      assert ReactorMiddleware.json_safe?(%{})
    end

    test "rejects a map containing a tuple" do
      refute ReactorMiddleware.json_safe?(%{a: {:x, 1}})
    end

    test "rejects a struct (and a map containing one)" do
      refute ReactorMiddleware.json_safe?(~D[2024-01-01])
      refute ReactorMiddleware.json_safe?(%{date: ~D[2024-01-01]})
    end

    test "rejects a pid" do
      refute ReactorMiddleware.json_safe?(%{p: self()})
    end
  end

  defp build(step_module) do
    Builder.new()
    |> Builder.add_step!(:only, step_module)
    |> Builder.return!(:only)
    |> Builder.add_middleware!(ReactorMiddleware)
  end

  defp create_run(name, %{tenant: tenant, actor: actor}) do
    {:ok, run} = WorkflowRun.create(%{name: name}, tenant: tenant, actor: actor)
    run
  end

  defp context(run, %{tenant: tenant, actor: actor}) do
    %{tenant: tenant, actor: actor, workflow_run: run, reactor: "TestReactor"}
  end

  defp events_for(run, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    events
  end

  defp kinds(run, ctx) do
    run
    |> events_for(ctx)
    |> Enum.map(& &1.kind)
  end
end
