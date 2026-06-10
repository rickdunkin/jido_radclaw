defmodule JidoClaw.Reasoning.Compactor.IntegrationTest do
  @moduledoc """
  Binding contract: the transformer ACTUALLY receives a compacted
  message list driven by the real `Storage.persist` and `Storage.latest`
  paths, not just confirmation that DB metadata was updated.

  The transformer is exercised directly with the post-maybe_compact
  runtime_context. The `:__jido_claw_compaction_test_capture__` hook in
  the transformer is used to intercept the resulting messages list.
  """

  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Message
  alias JidoClaw.Reasoning.Compactor
  alias JidoClaw.Reasoning.Compactor.{Config, RequestTransformer, Snapshot}

  defmodule FixedBackend do
    @behaviour JidoClaw.Reasoning.Compactor.Summarizer

    @impl JidoClaw.Reasoning.Compactor.Summarizer
    def summarize(_prompt, _opts), do: {:ok, "FIXTURE-SUMMARY"}
  end

  defmodule RaisingBackend do
    @behaviour JidoClaw.Reasoning.Compactor.Summarizer

    @impl JidoClaw.Reasoning.Compactor.Summarizer
    def summarize(_prompt, _opts), do: raise("simulated summarizer failure")
  end

  setup do
    original = Application.get_env(:jido_claw, :compaction_summarizer)
    Application.put_env(:jido_claw, :compaction_summarizer, FixedBackend)

    test_pid = self()
    handler_id = "compactor-integration-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido_claw, :compaction, :event],
        fn _, measurements, metadata, _ ->
          send(test_pid, {:compaction_event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      Application.put_env(:jido_claw, :compaction_summarizer, original)
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  defp seed_session(label) do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: label)
    {tenant_id, session, actor_for(tenant_id)}
  end

  defp seed_turns(session, tenant_id, actor, turn_count, msgs_per_turn) do
    for i <- 1..turn_count, j <- 1..msgs_per_turn do
      role = if rem(j, 2) == 1, do: :user, else: :assistant

      {:ok, _} =
        Message.append(
          %{
            session_id: session.id,
            request_id: "req_t#{i}",
            role: role,
            content: "turn-#{i}-msg-#{j}"
          },
          tenant: tenant_id,
          actor: actor
        )
    end
  end

  defp build_projected_messages(turn_count, msgs_per_turn) do
    for i <- 1..turn_count, j <- 1..msgs_per_turn do
      role = if rem(j, 2) == 1, do: :user, else: :assistant
      %{role: role, content: "turn-#{i}-msg-#{j}", refs: %{request_id: "req_t#{i}"}}
    end
  end

  defp drain_compaction_events do
    receive do
      {:compaction_event, _m, metadata} -> [metadata | drain_compaction_events()]
    after
      0 -> []
    end
  end

  describe "binding contract" do
    test "transformer receives a compacted messages list after maybe_compact persists a snapshot" do
      {tenant_id, session, actor} = seed_session("bind")
      # 12 turns, 4 messages each → 48 DB rows
      seed_turns(session, tenant_id, actor, 12, 4)

      config =
        Config.new!(
          mode: :auto,
          max_messages: 20,
          recompact_delta_threshold: 10,
          keep_last_turns: 2,
          protect_first_n_turns: 1,
          summarizer_timeout_ms: 1_000
        )

      action =
        {:ai_react_start,
         %{
           query: "next-turn",
           request_id: "live-1",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, config)

      # 1. Snapshot persisted
      assert {:ok, %Snapshot{} = persisted} =
               Compactor.latest(session.id, tenant: tenant_id, actor: actor)

      assert persisted.summary == "FIXTURE-SUMMARY"
      assert persisted.summarized_request_ids != []
      # turn 1 protected, turns 11,12 retained
      refute "req_t1" in persisted.summarized_request_ids
      refute "req_t11" in persisted.summarized_request_ids
      refute "req_t12" in persisted.summarized_request_ids
      assert "req_t2" in persisted.summarized_request_ids

      # 2. Transformer is now installed
      assert params.request_transformer == RequestTransformer

      # 3. Drive the transformer with a projected messages list
      projected = build_projected_messages(12, 4)

      # The maybe_compact mutated action put the snapshot in tool_context;
      # the strategy would merge tool_context into runtime_context. Simulate
      # that merge here for the binding assertion.
      runtime_context =
        Map.put(params.tool_context, RequestTransformer.test_capture_key(), self())

      assert {:ok, %{messages: result_messages}} =
               RequestTransformer.transform_request(
                 %{messages: projected, llm_opts: [], tools: %{}},
                 nil,
                 nil,
                 runtime_context
               )

      assert_receive {:compactor_transformer_messages, ^result_messages}

      # Summarized request_ids dropped from result
      result_ids =
        Enum.flat_map(result_messages, fn m ->
          case Map.get(m, :refs) do
            %{request_id: rid} -> [rid]
            _ -> []
          end
        end)

      assert "req_t1" in result_ids
      assert "req_t11" in result_ids
      assert "req_t12" in result_ids
      refute "req_t2" in result_ids
      refute "req_t5" in result_ids

      # Summary user-message injected
      assert Enum.any?(result_messages, fn m ->
               m.role == :user and String.contains?(m.content, "FIXTURE-SUMMARY")
             end)

      # 4. Telemetry: :start then :summarized in order
      events = drain_compaction_events()
      event_names = Enum.map(events, & &1.event)
      assert :start in event_names
      assert :summarized in event_names
    end

    test "below-threshold second call yields :skipped but still installs the previous snapshot" do
      {tenant_id, session, actor} = seed_session("skip")
      seed_turns(session, tenant_id, actor, 12, 4)

      config =
        Config.new!(
          mode: :auto,
          max_messages: 20,
          recompact_delta_threshold: 100,
          keep_last_turns: 2,
          protect_first_n_turns: 1,
          summarizer_timeout_ms: 1_000
        )

      action1 =
        {:ai_react_start,
         %{
           query: "first",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, _} = Compactor.maybe_compact(nil, action1, config)
      _ = drain_compaction_events()

      action2 =
        {:ai_react_start,
         %{
           query: "second",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params2}} = Compactor.maybe_compact(nil, action2, config)
      assert params2.request_transformer == RequestTransformer

      # snapshot still in tool_context
      snapshot = Map.get(params2.tool_context, Compactor.runtime_context_key())
      assert %Snapshot{summary: "FIXTURE-SUMMARY"} = snapshot

      events = drain_compaction_events()
      event_names = Enum.map(events, & &1.event)
      assert :skipped in event_names
    end

    test "failure injection — summarizer raise still yields a forward-progress action" do
      {tenant_id, session, actor} = seed_session("raise")
      seed_turns(session, tenant_id, actor, 12, 4)
      Application.put_env(:jido_claw, :compaction_summarizer, RaisingBackend)

      config =
        Config.new!(
          mode: :auto,
          max_messages: 20,
          recompact_delta_threshold: 10,
          keep_last_turns: 2,
          protect_first_n_turns: 1,
          summarizer_timeout_ms: 1_000
        )

      action =
        {:ai_react_start,
         %{
           query: "force",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} = Compactor.maybe_compact(nil, action, config)
      assert params.request_transformer == RequestTransformer

      events = drain_compaction_events()
      event_names = Enum.map(events, & &1.event)
      assert :error in event_names
    end

    test "tenant isolation — tenant B's compaction does not touch tenant A's snapshot" do
      {tenant_a, session_a, actor_a} = seed_session("a")
      {tenant_b, session_b, actor_b} = seed_session("b")
      seed_turns(session_a, tenant_a, actor_a, 12, 4)

      config =
        Config.new!(
          mode: :auto,
          max_messages: 20,
          recompact_delta_threshold: 10,
          keep_last_turns: 2,
          protect_first_n_turns: 1,
          summarizer_timeout_ms: 1_000
        )

      action_a =
        {:ai_react_start,
         %{
           query: "a",
           tool_context: %{tenant_id: tenant_a, session_uuid: session_a.id, actor: actor_a}
         }}

      assert {:ok, _} = Compactor.maybe_compact(nil, action_a, config)

      assert {:ok, %Snapshot{}} =
               Compactor.latest(session_a.id, tenant: tenant_a, actor: actor_a)

      assert {:ok, nil} = Compactor.latest(session_b.id, tenant: tenant_b, actor: actor_b)
    end

    test "existing request_transformer collision short-circuits with telemetry and no DB write" do
      {tenant_id, session, actor} = seed_session("collision")
      seed_turns(session, tenant_id, actor, 12, 4)

      action =
        {:ai_react_start,
         %{
           query: "collide",
           request_transformer: SomeOtherCallerTransformer,
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:error, :existing_request_transformer} =
               Compactor.maybe_compact(nil, action, Config.default())

      events = drain_compaction_events()
      event_names = Enum.map(events, & &1.event)
      assert :skipped in event_names

      # No snapshot persisted
      assert {:ok, nil} = Compactor.latest(session.id, tenant: tenant_id, actor: actor)
    end
  end
end
