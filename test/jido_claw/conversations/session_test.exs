defmodule JidoClaw.Conversations.SessionTest do
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.FrontDoor.Clarify.State
  alias JidoClaw.Triage.Verdict

  describe "start/1" do
    test "creates a session row with last_active_at populated automatically" do
      tenant_id = seed_tenant("session-start")
      {:ok, ws} = seed_workspace(tenant_id)

      now = DateTime.utc_now()

      assert {:ok, session} =
               Session.start(
                 %{
                   workspace_id: ws.id,
                   kind: :repl,
                   external_id: "sess-abc",
                   started_at: now
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert session.workspace_id == ws.id
      assert session.tenant_id == tenant_id
      assert session.kind == :repl
      assert session.external_id == "sess-abc"
      assert session.last_active_at != nil
      assert session.idle_timeout_seconds == 300
      assert session.next_sequence == 1
    end
  end

  describe "cross-tenant FK invariant (§0.7)" do
    test "rejects a Session whose tenant_id does not match the parent Workspace's tenant_id" do
      parent_tenant = seed_tenant("parent")
      other_tenant = seed_tenant("other")

      {:ok, ws} = seed_workspace(parent_tenant)

      assert {:error, error} =
               Session.start(
                 %{
                   workspace_id: ws.id,
                   kind: :repl,
                   external_id: "x",
                   started_at: DateTime.utc_now()
                 },
                 tenant: other_tenant,
                 actor: actor_for(other_tenant)
               )

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "cross_tenant_fk_mismatch"))
    end

    test "rejects when the parent Workspace does not exist" do
      tenant_id = seed_tenant("missing-ws")
      bogus_uuid = Ecto.UUID.generate()

      assert {:error, error} =
               Session.start(
                 %{
                   workspace_id: bogus_uuid,
                   kind: :repl,
                   external_id: "x",
                   started_at: DateTime.utc_now()
                 },
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      messages =
        error
        |> Map.get(:errors, [])
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 == "workspace_not_found"))
    end
  end

  describe "set_pending_clarify/2 (queue item 8)" do
    test "clarify state survives the REAL JSONB round trip; nil clears the key" do
      tenant_id = seed_tenant("clarify-persist")
      {:ok, ws} = seed_workspace(tenant_id)
      opts = [tenant: tenant_id, actor: actor_for(tenant_id)]

      {:ok, session} =
        Session.start(
          %{
            workspace_id: ws.id,
            kind: :repl,
            external_id: "clarify-1",
            started_at: DateTime.utc_now()
          },
          opts
        )

      verdict = %Verdict{path: :code, signals: [:ambiguous, :significant_build], est_size: :l}

      state =
        "make it faster"
        |> State.new(verdict, ~U[2026-07-07 12:00:00.000000Z])
        |> State.fold_score(
          %{
            ledger: [
              %{
                "question" => "faster at what?",
                "why_it_matters" => "targets the work",
                "risk_if_unanswered" => "wrong hot path",
                "recommended_default_assumption" => "p95 latency",
                "user_input_required" => true,
                "status" => "open",
                "user_answer" => nil
              }
            ],
            clarity: %{
              "goal" => 0.5,
              "constraints" => 0.4,
              "success_criteria" => 0.3,
              "context" => 0.6
            },
            llm_ambiguity: 0.55,
            updated_intent: nil
          },
          false,
          ~U[2026-07-07 12:00:05.000000Z]
        )
        |> State.record_round(~U[2026-07-07 12:00:05.000000Z])

      assert {:ok, _} = Session.set_pending_clarify(session, State.to_metadata(state), opts)

      # Reload the ROW (not the in-memory result): the reloaded-path rule —
      # JSONB retypes atoms/DateTimes, so the wire form must reload identically.
      {:ok, reloaded} = Session.by_id(session.id, opts)
      assert {:ok, ^state} = State.from_metadata(reloaded.metadata["pending_clarify"])

      # nil takes the SetMetadataKey delete branch and drops the key.
      assert {:ok, _} = Session.set_pending_clarify(reloaded, nil, opts)
      {:ok, cleared} = Session.by_id(session.id, opts)
      refute Map.has_key?(cleared.metadata, "pending_clarify")
    end
  end
end
