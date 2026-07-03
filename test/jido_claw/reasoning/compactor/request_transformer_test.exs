defmodule JidoClaw.Reasoning.Compactor.RequestTransformerTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.{RequestTransformer, Snapshot}

  defp request(messages), do: %{messages: messages, llm_opts: [], tools: %{}}

  defp atom_msg(role, content, refs \\ nil) do
    base = %{role: role, content: content}

    case refs do
      nil -> base
      m -> Map.put(base, :refs, m)
    end
  end

  defp string_msg(role, content, refs \\ nil) do
    base = %{"role" => role, "content" => content}

    case refs do
      nil -> base
      m -> Map.put(base, "refs", m)
    end
  end

  describe "transform_request/4 — without snapshot in runtime_context" do
    test "returns no overrides" do
      msgs = [atom_msg(:user, "hi", %{request_id: "r1"})]
      result = RequestTransformer.transform_request(request(msgs), nil, nil, %{})
      assert result == {:ok, %{}}
    end

    test "still triggers test capture when no snapshot" do
      msgs = [atom_msg(:user, "hi", %{request_id: "r1"})]

      ctx = %{RequestTransformer.test_capture_key() => self()}
      _ = RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert_receive {:compactor_transformer_messages, captured_messages}
      assert captured_messages == msgs
    end
  end

  describe "transform_request/4 — with snapshot" do
    test "drops messages whose refs.request_id is in summarized set" do
      msgs = [
        atom_msg(:system, "sys"),
        atom_msg(:user, "old1", %{request_id: "r1"}),
        atom_msg(:assistant, "old1a", %{request_id: "r1"}),
        atom_msg(:user, "old2", %{request_id: "r2"}),
        atom_msg(:user, "new", %{request_id: "r3"})
      ]

      snap = %Snapshot{
        status: :summarized,
        strategy: :summary,
        summary: "earlier conversation",
        summarized_request_ids: ["r1", "r2"]
      }

      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert [system_msg, summary_msg, last_user_msg] = result
      assert system_msg == atom_msg(:system, "sys")
      assert summary_msg.role == :user
      assert String.contains?(summary_msg.content, "earlier conversation")
      assert String.contains?(summary_msg.content, "[Compacted summary")
      assert last_user_msg == atom_msg(:user, "new", %{request_id: "r3"})
    end

    test "keeps system messages with nil refs" do
      msgs = [
        atom_msg(:system, "sys-nil-refs"),
        atom_msg(:user, "old", %{request_id: "r1"})
      ]

      snap = %Snapshot{summary: "x", summarized_request_ids: ["r1"]}

      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert [first, _] = result
      assert first == atom_msg(:system, "sys-nil-refs")
    end

    test "keeps non-system messages with nil refs (legacy untagged)" do
      msgs = [
        atom_msg(:user, "untagged-user"),
        atom_msg(:user, "old", %{request_id: "r1"})
      ]

      snap = %Snapshot{summary: "x", summarized_request_ids: ["r1"]}

      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      # untagged user kept, old user dropped, summary injected at front
      assert [summary_msg, kept_msg] = result
      assert summary_msg.role == :user
      assert String.contains?(summary_msg.content, "[Compacted summary")
      assert kept_msg == atom_msg(:user, "untagged-user")
    end

    test "handles string-keyed messages and refs" do
      msgs = [
        string_msg("system", "sys"),
        string_msg("user", "old", %{"request_id" => "r1"}),
        string_msg("user", "new", %{"request_id" => "r2"})
      ]

      snap = %Snapshot{summary: "x", summarized_request_ids: ["r1"]}
      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert [first, second, third] = result
      assert first == string_msg("system", "sys")
      assert second.role == :user
      assert third == string_msg("user", "new", %{"request_id" => "r2"})
    end

    test "injects summary after leading system messages" do
      msgs = [
        atom_msg(:system, "sys1"),
        atom_msg(:system, "sys2"),
        atom_msg(:user, "old", %{request_id: "r1"}),
        atom_msg(:user, "new", %{request_id: "r2"})
      ]

      snap = %Snapshot{summary: "summary content", summarized_request_ids: ["r1"]}
      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert Enum.at(result, 0) == atom_msg(:system, "sys1")
      assert Enum.at(result, 1) == atom_msg(:system, "sys2")
      assert Enum.at(result, 2).role == :user
      assert String.contains?(Enum.at(result, 2).content, "summary content")
    end

    test "no summary content if snapshot.summary is nil" do
      msgs = [
        atom_msg(:user, "old", %{request_id: "r1"}),
        atom_msg(:user, "new", %{request_id: "r2"})
      ]

      snap = %Snapshot{summary: nil, summarized_request_ids: ["r1"]}
      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      # only the kept message; no injected summary
      assert [kept] = result
      assert kept == atom_msg(:user, "new", %{request_id: "r2"})
    end

    test "cumulative summarized_request_ids drop across calls" do
      msgs1 = [
        atom_msg(:user, "a", %{request_id: "r1"}),
        atom_msg(:user, "b", %{request_id: "r2"}),
        atom_msg(:user, "c", %{request_id: "r3"})
      ]

      snap = %Snapshot{summary: "x", summarized_request_ids: ["r1", "r2", "r3"]}
      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs1), nil, nil, ctx)

      # only the summary message remains
      assert [summary] = result
      assert summary.role == :user
      assert String.contains?(summary.content, "[Compacted summary")
    end

    test "test capture receives the post-filter messages list" do
      msgs = [
        atom_msg(:user, "old", %{request_id: "r1"}),
        atom_msg(:user, "new", %{request_id: "r2"})
      ]

      snap = %Snapshot{summary: "S", summarized_request_ids: ["r1"]}

      ctx = %{
        RequestTransformer.runtime_context_key() => snap,
        RequestTransformer.test_capture_key() => self()
      }

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert_receive {:compactor_transformer_messages, captured}
      assert captured == result
    end

    test "AR-9: a stage tier WITHOUT a snapshot returns model + reasoning_effort overrides" do
      msgs = [atom_msg(:user, "hi", %{request_id: "r1"})]
      ctx = %{RequestTransformer.stage_tier_key() => %{model: :capable, effort: :high}}

      assert RequestTransformer.transform_request(request(msgs), nil, nil, ctx) ==
               {:ok, %{model: :capable, llm_opts: [reasoning_effort: :high]}}
    end

    test "AR-9: a stage tier WITH a snapshot returns :messages AND the tier keys" do
      msgs = [
        atom_msg(:user, "old", %{request_id: "r1"}),
        atom_msg(:user, "new", %{request_id: "r2"})
      ]

      snap = %Snapshot{summary: "S", summarized_request_ids: ["r1"]}

      ctx = %{
        RequestTransformer.runtime_context_key() => snap,
        RequestTransformer.stage_tier_key() => %{model: :capable, effort: :high}
      }

      assert {:ok, %{messages: result, model: :capable, llm_opts: [reasoning_effort: :high]}} =
               RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert [summary_msg, kept_msg] = result
      assert String.contains?(summary_msg.content, "[Compacted summary")
      assert kept_msg == atom_msg(:user, "new", %{request_id: "r2"})
    end

    test "AR-9: a model-only tier returns only :model; an effort-only tier only :llm_opts" do
      msgs = [atom_msg(:user, "hi", %{request_id: "r1"})]

      model_ctx = %{RequestTransformer.stage_tier_key() => %{model: :capable}}

      assert RequestTransformer.transform_request(request(msgs), nil, nil, model_ctx) ==
               {:ok, %{model: :capable}}

      effort_ctx = %{RequestTransformer.stage_tier_key() => %{effort: :low}}

      assert RequestTransformer.transform_request(request(msgs), nil, nil, effort_ctx) ==
               {:ok, %{llm_opts: [reasoning_effort: :low]}}
    end

    test "AR-9: no tier key (or a malformed one) leaves both paths byte-identical to today" do
      msgs = [
        atom_msg(:user, "old", %{request_id: "r1"}),
        atom_msg(:user, "new", %{request_id: "r2"})
      ]

      # Regression guard: absent tier, nil-snapshot path.
      assert RequestTransformer.transform_request(request(msgs), nil, nil, %{}) == {:ok, %{}}

      # A malformed tier value (not a map) is ignored, never crashes the turn.
      bad_ctx = %{RequestTransformer.stage_tier_key() => [:not, :a, :map]}
      assert RequestTransformer.transform_request(request(msgs), nil, nil, bad_ctx) == {:ok, %{}}

      # Absent tier, snapshot path: exactly the historical single-key override.
      snap = %Snapshot{summary: "S", summarized_request_ids: ["r1"]}
      snap_ctx = %{RequestTransformer.runtime_context_key() => snap}

      assert {:ok, overrides} =
               RequestTransformer.transform_request(request(msgs), nil, nil, snap_ctx)

      assert Map.keys(overrides) == [:messages]
    end

    test "20 messages, 12 in summarized set, results in 8 + 1 summary = 9" do
      msgs =
        for i <- 1..20 do
          rid = if i <= 12, do: "r_old_#{i}", else: "r_new_#{i}"
          atom_msg(:user, "m#{i}", %{request_id: rid})
        end

      old_ids = for i <- 1..12, do: "r_old_#{i}"
      snap = %Snapshot{summary: "fixture", summarized_request_ids: old_ids}

      ctx = %{RequestTransformer.runtime_context_key() => snap}

      {:ok, %{messages: result}} =
        RequestTransformer.transform_request(request(msgs), nil, nil, ctx)

      assert Enum.count(result) == 9
      assert Enum.any?(result, fn m -> String.contains?(Map.get(m, :content, ""), "fixture") end)

      result_ids =
        Enum.flat_map(result, fn m ->
          case Map.get(m, :refs) do
            %{request_id: rid} -> [rid]
            _ -> []
          end
        end)

      assert Enum.all?(result_ids, &(not String.starts_with?(&1, "r_old_")))
    end
  end
end
