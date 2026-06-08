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
  alias JidoClaw.Orchestration.ReactorMiddlewareTest.OkStep
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

  defp kinds(run, ctx), do: run |> events_for(ctx) |> Enum.map(& &1.kind)
end
