defmodule JidoClaw.Reasoning.CompactorTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.Message
  alias JidoClaw.Reasoning.Compactor
  alias JidoClaw.Reasoning.Compactor.{Config, RequestTransformer, Snapshot}

  defmodule FixedSummaryBackend do
    @behaviour JidoClaw.Reasoning.Compactor.Summarizer

    @impl JidoClaw.Reasoning.Compactor.Summarizer
    def summarize(_prompt, _opts), do: {:ok, "FIXED-SUMMARY"}
  end

  setup do
    original = Application.get_env(:jido_claw, :compaction_summarizer)
    Application.put_env(:jido_claw, :compaction_summarizer, FixedSummaryBackend)
    on_exit(fn -> Application.put_env(:jido_claw, :compaction_summarizer, original) end)
    :ok
  end

  defp append!(session, tenant_id, actor, opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.put(:session_id, session.id)
      |> Map.put_new(:role, :user)
      |> Map.put_new(:request_id, "r1")
      |> Map.put_new(:content, "msg")

    {:ok, _msg} = Message.append(attrs, tenant: tenant_id, actor: actor)
  end

  defp seed_turns(session, tenant_id, actor, count, opts) do
    msgs_per_turn = Keyword.get(opts, :msgs_per_turn, 2)

    for i <- 1..count do
      req_id = "req_t#{i}"

      for j <- 1..msgs_per_turn do
        role = if rem(j, 2) == 1, do: :user, else: :assistant

        append!(session, tenant_id, actor, %{
          request_id: req_id,
          role: role,
          content: "t#{i}-#{j}"
        })
      end
    end
  end

  describe "runtime_context_key/0" do
    test "returns the same key the RequestTransformer reads" do
      assert Compactor.runtime_context_key() == RequestTransformer.runtime_context_key()
    end
  end

  describe "maybe_compact/3 — :off mode" do
    test "returns the action unchanged" do
      action = {:ai_react_start, %{query: "hi", tool_context: %{}}}
      config = Config.off()

      assert {:ok, ^action} = Compactor.maybe_compact(nil, action, config)
    end
  end

  describe "maybe_compact/3 — missing tool_context" do
    test "skips when tenant_id or session_uuid is missing" do
      action = {:ai_react_start, %{query: "hi", tool_context: %{tenant_id: "t"}}}
      config = Config.default()

      assert {:ok, returned} = Compactor.maybe_compact(nil, action, config)
      assert returned == action
    end
  end

  describe "maybe_compact/3 — request_transformer collision" do
    test "returns :error when caller pre-set a non-Compactor transformer" do
      action = {
        :ai_react_start,
        %{
          query: "hi",
          tool_context: %{tenant_id: "t", session_uuid: "s"},
          request_transformer: SomeOtherModule
        }
      }

      assert {:error, :existing_request_transformer} =
               Compactor.maybe_compact(nil, action, Config.default())
    end
  end

  describe "maybe_compact/3 — below threshold" do
    test "installs transformer with no snapshot when slice is below threshold" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "below")
      actor = actor_for(tenant_id)

      # seed 4 messages total, threshold is 60
      append!(session, tenant_id, actor, %{request_id: "req1", role: :user, content: "hi"})

      append!(session, tenant_id, actor, %{request_id: "req1", role: :assistant, content: "hello"})

      action =
        {:ai_react_start,
         %{
           query: "next",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, Config.default())

      assert params.request_transformer == RequestTransformer
      assert Map.has_key?(params.tool_context, Compactor.runtime_context_key()) == false
      assert params.extra_refs.request_id != nil
    end
  end

  describe "maybe_compact/3 — first compaction" do
    test "loads slice, summarizes, persists snapshot, installs transformer" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "first")
      actor = actor_for(tenant_id)

      # 12 turns × 2 messages = 24 messages, above max_messages: 20 threshold
      seed_turns(session, tenant_id, actor, 12, msgs_per_turn: 2)

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
           query: "go",
           request_id: "live-req-1",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, config)

      assert params.request_transformer == RequestTransformer

      snapshot = Map.get(params.tool_context, Compactor.runtime_context_key())
      assert %Snapshot{status: :summarized, summary: "FIXED-SUMMARY"} = snapshot

      assert {:ok, %Snapshot{summary: "FIXED-SUMMARY"} = persisted} =
               Compactor.latest(session.id, tenant: tenant_id, actor: actor)

      # turn 1 protected, turns 11-12 retained, turns 2-10 in source
      assert length(persisted.summarized_request_ids) == 9
      assert "req_t1" not in persisted.summarized_request_ids
      assert "req_t11" not in persisted.summarized_request_ids
      assert "req_t12" not in persisted.summarized_request_ids
      assert "req_t2" in persisted.summarized_request_ids
    end
  end

  describe "compact/3 — manual force" do
    test "force-compacts a session regardless of threshold" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "force")
      actor = actor_for(tenant_id)
      seed_turns(session, tenant_id, actor, 5, msgs_per_turn: 2)

      config =
        Config.new!(
          mode: :manual,
          max_messages: 1_000,
          recompact_delta_threshold: 1_000,
          keep_last_turns: 1,
          protect_first_n_turns: 1
        )

      assert {:ok, %Snapshot{status: :summarized}} =
               Compactor.compact(session.id, tenant_id,
                 actor: actor,
                 agent_id: "main",
                 config: config
               )
    end

    test "returns an empty snapshot when there are no source messages" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "empty")
      actor = actor_for(tenant_id)

      assert {:ok, %Snapshot{}} =
               Compactor.compact(session.id, tenant_id, actor: actor, agent_id: "main")
    end
  end

  describe "latest/2" do
    test "is a tenant-scoped passthrough to Storage.latest" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "lat")
      actor = actor_for(tenant_id)
      assert {:ok, nil} = Compactor.latest(session.id, tenant: tenant_id, actor: actor)
    end
  end

  describe "maybe_compact/3 — :manual mode" do
    setup do
      test_pid = self()
      handler_id = "compactor-manual-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:jido_claw, :compaction, :event],
          fn _, measurements, metadata, _ ->
            send(test_pid, {:compaction_event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    defp manual_config(extra \\ []) do
      Config.new!(
        [
          mode: :manual,
          max_messages: 20,
          keep_last_turns: 2,
          protect_first_n_turns: 1,
          summarizer_timeout_ms: 1_000
        ] ++ extra
      )
    end

    test "skips summarization and installs the transformer with no prior snapshot" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "manual-happy")
      actor = actor_for(tenant_id)

      # auto would compact at this volume; :manual must not
      seed_turns(session, tenant_id, actor, 12, msgs_per_turn: 2)

      action =
        {:ai_react_start,
         %{
           query: "go",
           request_id: "live-manual",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, manual_config())

      assert params.request_transformer == RequestTransformer
      assert Map.get(params.tool_context, Compactor.runtime_context_key()) == nil
      assert params.extra_refs.request_id == "live-manual"

      # proof the summarizer was not invoked: no snapshot was persisted
      assert {:ok, nil} = Compactor.latest(session.id, tenant: tenant_id, actor: actor)

      assert_received {:compaction_event, _, %{event: :skipped, reason: :manual_mode}}
    end

    test "threads the prior snapshot into tool_context when one exists" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "manual-prior")
      actor = actor_for(tenant_id)
      seed_turns(session, tenant_id, actor, 5, msgs_per_turn: 2)

      force_cfg =
        Config.new!(
          mode: :manual,
          max_messages: 1_000,
          recompact_delta_threshold: 1_000,
          keep_last_turns: 1,
          protect_first_n_turns: 1
        )

      assert {:ok, %Snapshot{status: :summarized}} =
               Compactor.compact(session.id, tenant_id,
                 actor: actor,
                 agent_id: "main",
                 config: force_cfg
               )

      action =
        {:ai_react_start,
         %{
           query: "next",
           tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, manual_config())

      assert %Snapshot{status: :summarized} =
               Map.get(params.tool_context, Compactor.runtime_context_key())

      assert_received {:compaction_event, _, %{event: :skipped, reason: :manual_mode}}
    end

    test "missing tool_context returns the action unchanged and emits :missing_context" do
      action = {:ai_react_start, %{query: "hi", tool_context: %{tenant_id: "t"}}}

      assert {:ok, ^action} = Compactor.maybe_compact(nil, action, manual_config())
      assert_received {:compaction_event, _, %{event: :skipped, reason: :missing_context}}
    end

    test "pre-set non-Compactor request_transformer returns :error" do
      action = {
        :ai_react_start,
        %{
          query: "hi",
          tool_context: %{tenant_id: "t", session_uuid: "s"},
          request_transformer: SomeOtherModule
        }
      }

      assert {:error, :existing_request_transformer} =
               Compactor.maybe_compact(nil, action, manual_config())

      assert_received {:compaction_event, _,
                       %{event: :skipped, reason: :existing_request_transformer}}
    end

    test "storage failure emits :error stage: :load_snapshot, returns :ok with no snapshot" do
      %{tenant_id: tenant_id} = seed_full(tenant_label: "manual-err")
      actor = actor_for(tenant_id)
      missing_uuid = Ecto.UUID.generate()

      action =
        {:ai_react_start,
         %{
           query: "go",
           tool_context: %{tenant_id: tenant_id, session_uuid: missing_uuid, actor: actor}
         }}

      assert {:ok, {:ai_react_start, params}} =
               Compactor.maybe_compact(nil, action, manual_config())

      assert params.request_transformer == RequestTransformer
      assert Map.get(params.tool_context, Compactor.runtime_context_key()) == nil

      assert_received {:compaction_event, _, %{event: :error, stage: :load_snapshot}}
      refute_received {:compaction_event, _, %{event: :skipped, reason: :manual_mode}}
    end
  end

  describe "transcript fidelity" do
    defmodule PromptCaptureBackend do
      @behaviour JidoClaw.Reasoning.Compactor.Summarizer

      @impl JidoClaw.Reasoning.Compactor.Summarizer
      def summarize(prompt, _opts) do
        case Application.get_env(:jido_claw, :compaction_test_capture_pid) do
          pid when is_pid(pid) -> send(pid, {:compactor_prompt, prompt})
          _ -> :noop
        end

        {:ok, "FIXED-SUMMARY"}
      end
    end

    setup do
      original_backend = Application.get_env(:jido_claw, :compaction_summarizer)
      original_capture = Application.get_env(:jido_claw, :compaction_test_capture_pid)

      Application.put_env(:jido_claw, :compaction_summarizer, PromptCaptureBackend)
      Application.put_env(:jido_claw, :compaction_test_capture_pid, self())

      on_exit(fn ->
        restore_env(:compaction_summarizer, original_backend)
        restore_env(:compaction_test_capture_pid, original_capture)
      end)

      :ok
    end

    defp restore_env(key, nil), do: Application.delete_env(:jido_claw, key)
    defp restore_env(key, value), do: Application.put_env(:jido_claw, key, value)

    defp transcript_config do
      Config.new!(
        mode: :auto,
        max_messages: 4,
        recompact_delta_threshold: 2,
        keep_last_turns: 1,
        protect_first_n_turns: 1,
        summarizer_timeout_ms: 2_000
      )
    end

    defp seed_protected(session, tenant_id, actor) do
      append!(session, tenant_id, actor, %{
        request_id: "req_t1",
        role: :user,
        content: "hi-protected"
      })

      append!(session, tenant_id, actor, %{
        request_id: "req_t1",
        role: :assistant,
        content: "ok-protected"
      })
    end

    defp seed_retained(session, tenant_id, actor) do
      append!(session, tenant_id, actor, %{
        request_id: "req_t3",
        role: :user,
        content: "next-retained"
      })

      append!(session, tenant_id, actor, %{
        request_id: "req_t3",
        role: :assistant,
        content: "yes-retained"
      })
    end

    defp transcript_action(session, tenant_id, actor) do
      {:ai_react_start,
       %{
         query: "go",
         tool_context: %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
       }}
    end

    test "renders metadata.arguments and metadata.result with atom keys" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tf-atom")
      actor = actor_for(tenant_id)

      seed_protected(session, tenant_id, actor)

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_call,
        content: "read_file(path: \"/foo\")",
        tool_call_id: "tc-atom",
        metadata: %{tool_name: "read_file", arguments: %{path: "/foo"}}
      })

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_result,
        content: "read_file → ok",
        tool_call_id: "tc-atom",
        metadata: %{
          tool_name: "read_file",
          result: %{
            status: :ok,
            value: "hello world",
            error: nil,
            effects: nil,
            raw_inspect: nil
          }
        }
      })

      seed_retained(session, tenant_id, actor)

      assert {:ok, _} =
               Compactor.maybe_compact(
                 nil,
                 transcript_action(session, tenant_id, actor),
                 transcript_config()
               )

      assert_receive {:compactor_prompt, prompt}, 2_000
      assert String.contains?(prompt, "hello world")
      assert String.contains?(prompt, "/foo")
    end

    test "renders metadata.arguments and metadata.result with JSONB string keys" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tf-string")
      actor = actor_for(tenant_id)

      seed_protected(session, tenant_id, actor)

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_call,
        content: "read_file",
        tool_call_id: "tc-string",
        metadata: %{"tool_name" => "read_file", "arguments" => %{"path" => "/bar"}}
      })

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_result,
        content: "read_file → ok",
        tool_call_id: "tc-string",
        metadata: %{
          "tool_name" => "read_file",
          "result" => %{"status" => "ok", "value" => "string-key payload"}
        }
      })

      seed_retained(session, tenant_id, actor)

      assert {:ok, _} =
               Compactor.maybe_compact(
                 nil,
                 transcript_action(session, tenant_id, actor),
                 transcript_config()
               )

      assert_receive {:compactor_prompt, prompt}, 2_000
      assert String.contains?(prompt, "/bar")
      assert String.contains?(prompt, "string-key payload")
    end

    test "plain :user/:assistant rows render content as-is without payload suffix" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tf-plain")
      actor = actor_for(tenant_id)

      seed_protected(session, tenant_id, actor)

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :user,
        content: "the source content"
      })

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :assistant,
        content: "the source reply"
      })

      seed_retained(session, tenant_id, actor)

      assert {:ok, _} =
               Compactor.maybe_compact(
                 nil,
                 transcript_action(session, tenant_id, actor),
                 transcript_config()
               )

      assert_receive {:compactor_prompt, prompt}, 2_000
      assert String.contains?(prompt, "the source content")
      assert String.contains?(prompt, "the source reply")
      refute prompt =~ ~r/the source content\n  args:/
      refute prompt =~ ~r/the source reply\n  result:/
    end

    test "truncates an oversized :tool_result envelope and keeps the prompt valid UTF-8" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tf-truncate")
      actor = actor_for(tenant_id)

      seed_protected(session, tenant_id, actor)

      big_value = String.duplicate("X", 2_000)

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_result,
        content: "big → ok",
        tool_call_id: "tc-truncate",
        metadata: %{result: %{status: :ok, value: big_value}}
      })

      seed_retained(session, tenant_id, actor)

      assert {:ok, _} =
               Compactor.maybe_compact(
                 nil,
                 transcript_action(session, tenant_id, actor),
                 transcript_config()
               )

      assert_receive {:compactor_prompt, prompt}, 2_000
      assert String.contains?(prompt, "… (truncated, ")
      assert String.valid?(prompt)

      [_, after_marker] = String.split(prompt, "result: ", parts: 2)
      [payload_line | _] = String.split(after_marker, "\n", parts: 2)
      # payload budget is 800 bytes plus the truncation suffix (≈40 bytes)
      assert byte_size(payload_line) <= 800 + 64
    end

    test "truncation backs off to a valid UTF-8 prefix on a multi-byte boundary" do
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tf-utf8")
      actor = actor_for(tenant_id)

      seed_protected(session, tenant_id, actor)

      # A 1600-byte payload of 4-byte rockets — the 800-byte truncation
      # cut almost certainly lands inside a codepoint.
      emoji_payload = String.duplicate("🚀", 400)

      append!(session, tenant_id, actor, %{
        request_id: "req_t2",
        role: :tool_result,
        content: "utf8 → ok",
        tool_call_id: "tc-utf8",
        metadata: %{result: %{status: :ok, value: emoji_payload}}
      })

      seed_retained(session, tenant_id, actor)

      assert {:ok, _} =
               Compactor.maybe_compact(
                 nil,
                 transcript_action(session, tenant_id, actor),
                 transcript_config()
               )

      assert_receive {:compactor_prompt, prompt}, 2_000
      assert String.valid?(prompt)
      assert String.contains?(prompt, "… (truncated, ")
    end
  end
end
