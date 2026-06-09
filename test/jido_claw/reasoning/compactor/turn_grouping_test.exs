defmodule JidoClaw.Reasoning.Compactor.TurnGroupingTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.{Config, TurnGrouping}

  defp msg(req_id, seq, role \\ :user) do
    %{
      id: "m#{seq}",
      role: role,
      sequence: seq,
      request_id: req_id,
      content: "msg-#{seq}",
      inserted_at: DateTime.from_unix!(seq * 1_000_000, :microsecond)
    }
  end

  describe "group/1" do
    test "empty input returns empty list" do
      assert TurnGrouping.group([]) == []
    end

    test "groups messages by request_id" do
      msgs = [
        msg("r1", 1, :user),
        msg("r1", 2, :assistant),
        msg("r2", 3, :user)
      ]

      [t1, t2] = TurnGrouping.group(msgs)
      assert t1.request_id == "r1"
      assert [_, _] = t1.messages
      assert t2.request_id == "r2"
      assert [_] = t2.messages
    end

    test "sorts messages within a turn by sequence" do
      msgs = [msg("r1", 5, :assistant), msg("r1", 4, :user)]
      [turn] = TurnGrouping.group(msgs)
      assert Enum.map(turn.messages, & &1.sequence) == [4, 5]
    end

    test "sorts turns by earliest sequence" do
      msgs = [msg("r2", 5, :user), msg("r1", 1, :user), msg("r3", 3, :user)]
      result = TurnGrouping.group(msgs)
      assert Enum.map(result, & &1.request_id) == ["r1", "r3", "r2"]
    end

    test "groups nil-request_id messages into a single nil turn" do
      msgs = [
        msg(nil, 0, :system),
        msg(nil, 1, :system),
        msg("r1", 2, :user)
      ]

      result = TurnGrouping.group(msgs)
      nil_turns = Enum.filter(result, &is_nil(&1.request_id))
      assert [nil_turn] = nil_turns
      assert [_, _] = nil_turn.messages
    end
  end

  describe "split/3 — first compaction" do
    test "applies protect_first_n_turns" do
      turns =
        TurnGrouping.group([
          msg("r1", 1),
          msg("r2", 2),
          msg("r3", 3),
          msg("r4", 4),
          msg("r5", 5),
          msg("r6", 6),
          msg("r7", 7),
          msg("r8", 8)
        ])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 2,
          protect_first_n_turns: 2,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, true)
      assert Enum.map(protected, & &1.request_id) == ["r1", "r2"]
      assert Enum.map(source, & &1.request_id) == ["r3", "r4", "r5", "r6"]
      assert Enum.map(retained, & &1.request_id) == ["r7", "r8"]
    end

    test "rest <= keep_last_turns means no source" do
      turns = TurnGrouping.group([msg("r1", 1), msg("r2", 2), msg("r3", 3)])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 5,
          protect_first_n_turns: 1,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, true)
      assert Enum.map(protected, & &1.request_id) == ["r1"]
      assert source == []
      assert Enum.map(retained, & &1.request_id) == ["r2", "r3"]
    end

    test "protect > total real turns puts everything in protected" do
      turns = TurnGrouping.group([msg("r1", 1), msg("r2", 2)])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 1,
          protect_first_n_turns: 5,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, true)
      assert Enum.map(protected, & &1.request_id) == ["r1", "r2"]
      assert source == []
      assert retained == []
    end
  end

  describe "split/3 — re-compaction (is_first_compaction? == false)" do
    test "ignores protect_first_n_turns" do
      turns =
        TurnGrouping.group([
          msg("r1", 1),
          msg("r2", 2),
          msg("r3", 3),
          msg("r4", 4),
          msg("r5", 5)
        ])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 1,
          protect_first_n_turns: 3,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, false)
      assert Enum.map(protected, & &1.request_id) == []
      assert Enum.map(source, & &1.request_id) == ["r1", "r2", "r3", "r4"]
      assert Enum.map(retained, & &1.request_id) == ["r5"]
    end
  end

  describe "split/3 — nil-request_id turns" do
    test "nil turns ride along in protected; not counted toward protect_first_n_turns" do
      turns =
        TurnGrouping.group([
          msg(nil, 0, :system),
          msg("r1", 1),
          msg("r2", 2),
          msg("r3", 3),
          msg("r4", 4)
        ])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 1,
          protect_first_n_turns: 2,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, true)
      protected_ids = Enum.map(protected, & &1.request_id)
      assert nil in protected_ids
      assert "r1" in protected_ids
      assert "r2" in protected_ids
      assert [_, _, _] = protected_ids
      assert Enum.map(source, & &1.request_id) == ["r3"]
      assert Enum.map(retained, & &1.request_id) == ["r4"]
    end

    test "no real turns means nil turns still ride along" do
      turns = TurnGrouping.group([msg(nil, 0, :system)])

      config =
        Config.new!(
          mode: :auto,
          max_messages: 60,
          keep_last_turns: 1,
          protect_first_n_turns: 1,
          recompact_delta_threshold: 30
        )

      {protected, source, retained} = TurnGrouping.split(turns, config, true)
      assert Enum.map(protected, & &1.request_id) == [nil]
      assert source == []
      assert retained == []
    end
  end

  describe "Turn struct" do
    test "primary_role prefers user/assistant" do
      [turn] = TurnGrouping.group([msg("r1", 1, :tool_call), msg("r1", 2, :assistant)])
      assert turn.primary_role == :assistant
    end

    test "started_at and ended_at reflect first/last message timestamps" do
      [turn] = TurnGrouping.group([msg("r1", 5), msg("r1", 1), msg("r1", 3)])
      assert turn.messages |> Enum.map(& &1.sequence) == [1, 3, 5]
      assert turn.started_at_seq == 1
      assert turn.started_at == DateTime.from_unix!(1_000_000, :microsecond)
      assert turn.ended_at == DateTime.from_unix!(5_000_000, :microsecond)
    end
  end
end
