defmodule JidoClaw.FrontDoorStickinessTest do
  @moduledoc """
  The §14 acceptance for AR-8 triage (Phase 3d): stickiness is per-turn
  re-classification — a parked `talk` flips to `code` on "do it". A `fun/1` stub
  returns `talk` for the planning turn and `:code` for the go-ahead, so turn 1
  never enters the composer and turn 2 starts a run. The decision is the *fresh*
  verdict; `metadata["last_triage_path"]` is observability only.

  Non-async (`TenantCase`): mutates `:triage_*` / `:front_door_*` app env.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.FrontDoor
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Triage.Verdict

  setup do
    %{tenant_id: tenant_id, workspace: workspace, session: session} =
      seed_full(tenant_label: "sticky")

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict front_door_composer
           front_door_create_mode front_door_ensure_mode)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :front_door_composer, JidoClaw.Test.FrontDoorComposerStub)
    Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
    Application.put_env(:jido_claw, :front_door_ensure_mode, :noop)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)
    end)

    ctx = %{
      tenant_id: tenant_id,
      session_id: rsid,
      session_uuid: session.id,
      workspace_id: rsid,
      workspace_uuid: workspace.id,
      project_dir: File.cwd!(),
      user_id: nil,
      actor: actor,
      agent_id: "main",
      agent_template: "main"
    }

    {:ok, ctx: ctx, tenant_id: tenant_id, actor: actor}
  end

  defp composer_runs(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "composer"))
  end

  test "a parked talk flips to code on 'do it' — turn 1 stays inline, turn 2 enters the composer",
       %{ctx: ctx} do
    # Per-turn re-classification: talk while planning, code on the go-ahead.
    Application.put_env(:jido_claw, :triage_canned_verdict, fn
      "do it" -> :code
      _other -> %Verdict{path: :talk}
    end)

    # Turn 1: a planning question stays inline and starts no composer.
    assert {:inline, %Verdict{path: :talk}} =
             FrontDoor.decide("should we add a foo/0 helper?", ctx)

    assert composer_runs(ctx) == []

    # Turn 2: "do it" re-reads as code and starts a composer run.
    assert {:composer, {:ok, %{path: :code, parent_run_id: id}}} = FrontDoor.decide("do it", ctx)
    assert is_binary(id)
    assert [_one] = composer_runs(ctx)
  end

  test "the latest path is persisted as a string under metadata['last_triage_path']", %{ctx: ctx} do
    Application.put_env(:jido_claw, :triage_canned_verdict, fn
      "do it" -> :code
      _other -> :talk
    end)

    assert {:inline, _} = FrontDoor.decide("planning out loud", ctx)
    assert path_for(ctx) == "talk"

    assert {:composer, {:ok, _}} = FrontDoor.decide("do it", ctx)
    assert path_for(ctx) == "code"
  end

  defp path_for(ctx) do
    {:ok, session} =
      ConversationsSession.by_id(ctx.session_uuid, tenant: ctx.tenant_id, actor: ctx.actor)

    session.metadata["last_triage_path"]
  end
end
