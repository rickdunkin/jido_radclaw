defmodule JidoClaw.ChatComposerAckTest do
  @moduledoc """
  Pins `JidoClaw.chat/4`'s return-shape contract around the front door:

    * default (no `:composer_ack` opt) stays plain `{:ok, binary}` on EVERY
      route — cron auto-disable and the web/discord surfaces depend on it,
    * `composer_ack: :detailed` returns the structural shapes the one-shot
      CLI runner awaits on (route / status / run_id / message).

  Triage is the canned `TriageStub`; the composer launch goes through the
  `FrontDoorComposerStub` (`create :delegate` ⇒ a REAL parent run row is
  created; `ensure :noop` ⇒ no wave workers run).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Session.Supervisor, as: SessionSupervisor
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Test.HandoffDispatchCapture

  setup do
    tmp = Path.join(System.tmp_dir!(), "composer-ack-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    %{tenant_id: tenant_id, session: session} =
      seed_full(tenant_label: "composer-ack", workspace: [path: tmp], session: [kind: :cli_run])

    rsid = session.external_id
    actor = actor_for(tenant_id)

    {:ok, _pid} = SessionSupervisor.ensure_session(tenant_id, rsid, actor: actor)
    :ok = SessionWorker.set_session_uuid(tenant_id, rsid, session.id)

    saved =
      Map.new(
        ~w(triage_impl triage_canned_verdict ask_runtime dispatch_capture_target
           dispatch_capture_response front_door_composer
           front_door_create_mode front_door_ensure_mode clarify_generate)a,
        &{&1, Application.fetch_env(:jido_claw, &1)}
      )

    Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
    Application.put_env(:jido_claw, :ask_runtime, HandoffDispatchCapture)
    Application.put_env(:jido_claw, :dispatch_capture_target, self())
    Application.put_env(:jido_claw, :dispatch_capture_response, {:ok, "stub answer"})
    Application.put_env(:jido_claw, :front_door_composer, JidoClaw.Test.FrontDoorComposerStub)
    Application.put_env(:jido_claw, :front_door_create_mode, :delegate)
    Application.put_env(:jido_claw, :front_door_ensure_mode, :noop)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, :error} -> Application.delete_env(:jido_claw, key)
        {key, {:ok, value}} -> Application.put_env(:jido_claw, key, value)
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, tenant_id: tenant_id, rsid: rsid, actor: actor, tmp: tmp}
  end

  defp canned(path), do: Application.put_env(:jido_claw, :triage_canned_verdict, path)

  defp chat(ctx, message, extra_opts \\ []) do
    JidoClaw.chat(
      ctx.tenant_id,
      ctx.rsid,
      message,
      Keyword.merge(
        [kind: :cli_run, workspace_id: ctx.tmp, external_id: ctx.rsid, actor: ctx.actor],
        extra_opts
      )
    )
  end

  defp composer_runs(ctx) do
    {:ok, runs} = WorkflowRun.list(tenant: ctx.tenant_id, actor: ctx.actor)
    Enum.filter(runs, &(&1.workflow_type == "composer"))
  end

  describe "default (no :composer_ack opt) — regression pin" do
    test "inline route returns plain {:ok, binary}", ctx do
      canned(:talk)
      assert {:ok, "stub answer"} = chat(ctx, "how does X work?")
    end

    test "composer route returns plain {:ok, binary}", ctx do
      canned(:code)
      assert {:ok, message} = chat(ctx, "refactor the parser")
      assert is_binary(message)
    end
  end

  describe "composer_ack: :detailed" do
    test "inline route returns the :inline shape", ctx do
      canned(:talk)

      assert {:ok, %{route: :inline, message: "stub answer"}} =
               chat(ctx, "how does X work?", composer_ack: :detailed)
    end

    test "composer launch returns :launched with the created parent run id", ctx do
      canned(:code)

      assert {:ok, %{route: :composer, status: :launched, run_id: run_id, message: message}} =
               chat(ctx, "refactor the parser", composer_ack: :detailed)

      assert is_binary(message)
      assert Enum.any?(composer_runs(ctx), &(&1.id == run_id))
    end

    test "composer failed-to-start returns :failed_to_start with nil run_id", ctx do
      canned(:code)
      Application.put_env(:jido_claw, :front_door_create_mode, :error)

      assert {:ok, %{route: :composer, status: :failed_to_start, run_id: nil, message: message}} =
               chat(ctx, "refactor the parser", composer_ack: :detailed)

      assert is_binary(message)
    end
  end

  # ---------------------------------------------------------------------------
  # Clarify route (queue item 8) — the {:clarify, resp} shapes + opt threading
  # ---------------------------------------------------------------------------

  defp arm_ambiguous_clarify do
    Application.put_env(:jido_claw, :triage_canned_verdict, %JidoClaw.Triage.Verdict{
      path: :code,
      signals: [:ambiguous],
      intent: "make it faster"
    })

    object = %{
      "classification" => "answers",
      "clarity" => %{
        "goal" => 0.4,
        "constraints" => 0.4,
        "success_criteria" => 0.4,
        "context" => 0.5
      },
      "ambiguity" => 0.6,
      "updated_intent" => nil,
      "ledger" => [
        %{
          "question" => "faster at what?",
          "recommended_default_assumption" => "p95 latency",
          "user_input_required" => true,
          "status" => "open"
        }
      ]
    }

    Application.put_env(:jido_claw, :clarify_generate, fn _input, _schema, _opts ->
      {:ok, %ReqLLM.Response{id: "t", model: "t", context: nil, object: object}}
    end)
  end

  describe "clarify route (queue item 8)" do
    test "default returns plain {:ok, binary} carrying the question round", ctx do
      arm_ambiguous_clarify()

      assert {:ok, message} = chat(ctx, "make it faster")
      assert message =~ "faster at what?"
      assert message =~ "proceed with defaults"
      assert composer_runs(ctx) == []
    end

    test "detailed returns the :clarify pending shape with nil run_id", ctx do
      arm_ambiguous_clarify()

      assert {:ok, %{route: :clarify, status: :pending, run_id: nil, message: message}} =
               chat(ctx, "make it faster", composer_ack: :detailed)

      assert message =~ "faster at what?"
    end

    test "clarify: :one_shot forces the immediate degraded compose", ctx do
      arm_ambiguous_clarify()

      assert {:ok, %{route: :composer, status: :launched, run_id: run_id}} =
               chat(ctx, "make it faster", composer_ack: :detailed, clarify: :one_shot)

      assert Enum.any?(composer_runs(ctx), &(&1.id == run_id))
    end

    test "absent opt derives from :kind — :api never parks questions", ctx do
      arm_ambiguous_clarify()

      # A fresh session id: kind is part of the durable identity, and a live
      # runtime worker refuses to re-point its session_uuid.
      api_sid = "api-clarify-#{System.unique_integer([:positive])}"

      assert {:ok, %{route: :composer, status: :launched}} =
               JidoClaw.chat(ctx.tenant_id, api_sid, "make it faster",
                 kind: :api,
                 workspace_id: ctx.tmp,
                 external_id: api_sid,
                 actor: ctx.actor,
                 composer_ack: :detailed
               )
    end
  end
end
