defmodule JidoClaw.Orchestration.DeadlineTest do
  @moduledoc """
  Pins the pure deadline read-model (T2-1) to the Squidie-faithful contract:
  parse validity matrix (within positive, optional non-negative due_soon <
  within / escalate_after, zeros allowed), inclusive-bound threshold math in
  urgency order, unreachable statuses for undeclared thresholds, the
  completed-at freeze, and the always-present non-negative `overdue_by_ms`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Deadline

  @start ~U[2026-06-10 12:00:00.000000Z]

  defp at(seconds_after_start), do: DateTime.add(@start, seconds_after_start, :second)

  describe "parse/1 validity matrix" do
    test "within alone: positive integer required" do
      assert {:ok, %{within: 60}} = Deadline.parse(%{within: 60})
      assert {:ok, %{within: 60}} = Deadline.parse(%{"within" => 60})

      for bad <- [0, -1, 1.5, "60", nil] do
        assert Deadline.parse(%{within: bad}) == :none
      end

      # within is required.
      assert Deadline.parse(%{due_soon: 10}) == :none
      assert Deadline.parse(%{}) == :none
    end

    test "due_soon: optional non-negative integer strictly < within" do
      assert {:ok, %{within: 60, due_soon: 10}} = Deadline.parse(%{within: 60, due_soon: 10})
      # 0 allowed (due-soon coincides with due).
      assert {:ok, %{within: 60, due_soon: 0}} = Deadline.parse(%{within: 60, due_soon: 0})
      # due_soon == within rejected.
      assert Deadline.parse(%{within: 60, due_soon: 60}) == :none
      assert Deadline.parse(%{within: 60, due_soon: 61}) == :none
      assert Deadline.parse(%{within: 60, due_soon: -1}) == :none
      assert Deadline.parse(%{within: 60, due_soon: "10"}) == :none
    end

    test "escalate_after: optional non-negative integer (0 = escalate at due)" do
      assert {:ok, %{within: 60, escalate_after: 30}} =
               Deadline.parse(%{within: 60, escalate_after: 30})

      assert {:ok, %{within: 60, escalate_after: 0}} =
               Deadline.parse(%{within: 60, escalate_after: 0})

      assert Deadline.parse(%{within: 60, escalate_after: -1}) == :none
      assert Deadline.parse(%{within: 60, escalate_after: "x"}) == :none
    end

    test "normalized policy omits absent optional keys" do
      assert {:ok, policy} = Deadline.parse(%{"within" => 60})
      assert policy == %{within: 60}
    end

    test "nil / non-map / struct are :none (total at read time)" do
      assert Deadline.parse(nil) == :none
      assert Deadline.parse("60") == :none
      assert Deadline.parse(within: 60) == :none
      assert Deadline.parse(~U[2026-01-01 00:00:00Z]) == :none
    end

    test "string-keyed jsonb round-trip parses identically to atom keys" do
      raw = %{"within" => 60, "due_soon" => 10, "escalate_after" => 30}
      assert {:ok, %{within: 60, due_soon: 10, escalate_after: 30}} = Deadline.parse(raw)
    end
  end

  describe "evaluate/4 threshold math (inclusive bounds, urgency order)" do
    defp full_policy do
      {:ok, policy} = Deadline.parse(%{within: 60, due_soon: 10, escalate_after: 30})
      policy
    end

    test "thresholds are derived from started_at + policy" do
      evidence = Deadline.evaluate(full_policy(), @start, at(0), nil)

      assert evidence.due_at == at(60)
      assert evidence.due_soon_at == at(50)
      assert evidence.escalate_at == at(90)
    end

    test "just-before vs at each threshold (inclusive bounds)" do
      policy = full_policy()

      assert Deadline.evaluate(policy, @start, at(49), nil).status == :on_time
      assert Deadline.evaluate(policy, @start, at(50), nil).status == :due_soon
      assert Deadline.evaluate(policy, @start, at(59), nil).status == :due_soon
      assert Deadline.evaluate(policy, @start, at(60), nil).status == :overdue
      assert Deadline.evaluate(policy, @start, at(89), nil).status == :overdue
      assert Deadline.evaluate(policy, @start, at(90), nil).status == :escalated
      assert Deadline.evaluate(policy, @start, at(9_000), nil).status == :escalated
    end

    test "missing due_soon makes :due_soon unreachable (never defaulted)" do
      {:ok, policy} = Deadline.parse(%{within: 60})

      evidence = Deadline.evaluate(policy, @start, at(59), nil)
      assert evidence.status == :on_time
      assert is_nil(evidence.due_soon_at)
    end

    test "missing escalate_after makes :escalated unreachable" do
      {:ok, policy} = Deadline.parse(%{within: 60})

      evidence = Deadline.evaluate(policy, @start, at(9_000), nil)
      assert evidence.status == :overdue
      assert is_nil(evidence.escalate_at)
    end

    test "escalate_after: 0 escalates exactly at due" do
      {:ok, policy} = Deadline.parse(%{within: 60, escalate_after: 0})

      assert Deadline.evaluate(policy, @start, at(59), nil).status == :on_time
      assert Deadline.evaluate(policy, @start, at(60), nil).status == :escalated
    end

    test "due_soon: 0 means due-soon coincides with due (overdue wins at due)" do
      {:ok, policy} = Deadline.parse(%{within: 60, due_soon: 0})

      assert Deadline.evaluate(policy, @start, at(59), nil).status == :on_time
      assert Deadline.evaluate(policy, @start, at(60), nil).status == :overdue
    end

    test "completed_at freezes evidence regardless of now" do
      policy = full_policy()

      # Completed on time; evaluated long after — still on_time, zero late.
      frozen = Deadline.evaluate(policy, @start, at(9_000), at(30))
      assert frozen.status == :on_time
      assert frozen.overdue_by_ms == 0

      # Completed late; the lateness is fixed at completion.
      late = Deadline.evaluate(policy, @start, at(9_000), at(75))
      assert late.status == :overdue
      assert late.overdue_by_ms == 15_000
    end

    test "nil started_at yields nil (nothing to measure yet)" do
      assert Deadline.evaluate(full_policy(), nil, at(0), nil) == nil
    end

    test "overdue_by_ms is always present and non-negative" do
      policy = full_policy()

      assert Deadline.evaluate(policy, @start, at(0), nil).overdue_by_ms == 0
      assert Deadline.evaluate(policy, @start, at(55), nil).overdue_by_ms == 0
      assert Deadline.evaluate(policy, @start, at(61), nil).overdue_by_ms == 1_000
      assert Deadline.evaluate(policy, @start, at(95), nil).overdue_by_ms == 35_000
    end
  end

  describe "from_config/4" do
    test "unwraps parse: valid raw config evaluates" do
      evidence = Deadline.from_config(%{"within" => 60}, @start, at(61), nil)
      assert evidence.status == :overdue
    end

    test "nil / invalid raw config yields nil" do
      assert Deadline.from_config(nil, @start, at(0), nil) == nil
      assert Deadline.from_config(%{"within" => -5}, @start, at(0), nil) == nil
      assert Deadline.from_config("bogus", @start, at(0), nil) == nil
    end

    test "nil started_at yields nil even with a valid policy" do
      assert Deadline.from_config(%{"within" => 60}, nil, at(0), nil) == nil
    end
  end
end
