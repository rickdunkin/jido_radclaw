defmodule JidoClaw.Orchestration.ReactorRunnerTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest.NoMiddlewareReactor do
  @moduledoc false
  use Reactor

  step(:only, JidoClaw.Orchestration.ReactorRunnerTest.OkStep)
  return(:only)
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest do
  @moduledoc """
  Proves the two `ReactorRunner.run/3` review-finding fixes as a reusable seam:

    * Finding 1 — the runner auto-wires `ReactorMiddleware` into a reactor that
      declares none, so a successful run records the full timeline and never
      strands `:pending`. The struct augmentation is per-call (no shared DSL
      state leak across runs) and dedup-safe against a reactor that already
      declares the middleware (no double emission).
    * Finding 2 — the pre-run path honors the never-raises contract: a
      non-reactor module returns `{:error, {:not_a_reactor, mod}, nil}` and
      malformed (non-keyword) opts are normalized to `{:error, _, nil}` by the
      body-level rescue rather than raising to the caller.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.ReactorRunnerTest.NoMiddlewareReactor
  alias JidoClaw.Orchestration.Reactors.ProjectRegistration
  alias JidoClaw.Orchestration.WorkflowEvent

  setup do
    tenant = seed_tenant("reactor-runner")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "middleware auto-wiring (Finding 1)" do
    test "injects ReactorMiddleware for a reactor that declares none", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert run.status == :completed

      # The full timeline proves the runner injected the middleware for a
      # reactor that never declared it.
      assert kinds(run, ctx) ==
               [:run_started, :step_started, :step_completed, :run_completed]
    end

    test "augmentation is per-call: two runs each emit exactly one terminal pair", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run_a} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert {:ok, :done, run_b} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      refute run_a.id == run_b.id

      # Per-call struct augmentation never accumulates middleware across runs.
      for run <- [run_a, run_b] do
        kinds = kinds(run, ctx)
        assert Enum.count(kinds, &(&1 == :run_started)) == 1
        assert Enum.count(kinds, &(&1 == :run_completed)) == 1
      end
    end

    test "dedup: a reactor already declaring the middleware emits no doubles", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, _workspace, run} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(),
                 tenant: tenant,
                 actor: actor
               )

      assert run.status == :completed

      kinds = kinds(run, ctx)
      assert Enum.count(kinds, &(&1 == :run_started)) == 1
      assert Enum.count(kinds, &(&1 == :run_completed)) == 1
    end
  end

  describe "never-raises pre-run path (Finding 2)" do
    test "a non-reactor module returns the pre-run envelope with no run", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:error, {:not_a_reactor, Enum}, nil} =
               ReactorRunner.run(Enum, %{}, tenant: tenant, actor: actor)
    end

    test "malformed (non-keyword) opts are normalized, not raised", ctx do
      %{tenant: tenant, actor: actor} = ctx

      # A map, not a keyword list: Keyword.get/fetch would raise, but the
      # body-level rescue normalizes it to the pre-run envelope. The match
      # itself proves no exception escaped.
      assert {:error, _reason, nil} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(), %{
                 tenant: tenant,
                 actor: actor
               })
    end
  end

  defp valid_inputs do
    uniq = System.unique_integer([:positive])

    %{
      github_full_name: "o/r-#{uniq}",
      project_name: "proj-#{uniq}",
      workspace_name: "ws-#{uniq}",
      workspace_path: "/tmp/ws-#{uniq}"
    }
  end

  defp kinds(run, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    Enum.map(events, & &1.kind)
  end
end
