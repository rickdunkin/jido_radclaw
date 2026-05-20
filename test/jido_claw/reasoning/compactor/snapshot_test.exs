defmodule JidoClaw.Reasoning.Compactor.SnapshotTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.Snapshot

  describe "to_jsonb/1 + from_jsonb/1" do
    test "round-trips a populated snapshot" do
      original = %Snapshot{
        id: "cpct_1",
        session_id: "session-uuid",
        tenant_id: "tenant-a",
        agent_id: "main",
        status: :summarized,
        strategy: :summary,
        summary: "Concise summary text",
        summary_preview: "Concise summary text",
        source_message_count: 12,
        retained_message_count: 6,
        protected_message_count: 4,
        protected_turn_count: 2,
        last_summarized_sequence: 42,
        summarized_request_ids: ["r1", "r2", "r3"],
        last_summarized_request_id: "r3",
        last_summarized_at_ms: 1_700_000_000_000,
        started_at_ms: 1_700_000_000_000,
        completed_at_ms: 1_700_000_001_000,
        error: nil,
        metadata: %{"trigger" => "auto"}
      }

      jsonb = Snapshot.to_jsonb(original)

      assert is_map(jsonb)
      assert jsonb["status"] == "summarized"
      assert jsonb["strategy"] == "summary"
      assert jsonb["summarized_request_ids"] == ["r1", "r2", "r3"]
      refute Map.has_key?(jsonb, :status)

      restored = Snapshot.from_jsonb(jsonb)

      assert %Snapshot{} = restored
      assert restored.id == "cpct_1"
      assert restored.status == :summarized
      assert restored.strategy == :summary
      assert restored.summarized_request_ids == ["r1", "r2", "r3"]
      assert restored.last_summarized_sequence == 42
      assert restored.metadata == %{"trigger" => "auto"}
    end

    test "to_jsonb writes string keys and string status only" do
      snap = %Snapshot{
        id: "cpct_x",
        session_id: "s",
        tenant_id: "t",
        agent_id: "a",
        status: :skipped,
        strategy: :summary,
        summary: nil,
        summary_preview: nil,
        summarized_request_ids: []
      }

      jsonb = Snapshot.to_jsonb(snap)

      assert Enum.all?(Map.keys(jsonb), &is_binary/1)
      assert jsonb["status"] == "skipped"
      assert is_binary(jsonb["strategy"])
    end

    test "from_jsonb accepts atom-key maps as well" do
      atom_map = %{
        id: "cpct_2",
        session_id: "s",
        tenant_id: "t",
        agent_id: "a",
        status: :summarized,
        strategy: :summary,
        summary: "hi",
        summarized_request_ids: ["r1"]
      }

      restored = Snapshot.from_jsonb(atom_map)
      assert restored.id == "cpct_2"
      assert restored.status == :summarized
      assert restored.summarized_request_ids == ["r1"]
    end

    test "from_jsonb returns nil for nil or empty map" do
      assert Snapshot.from_jsonb(nil) == nil
      assert Snapshot.from_jsonb(%{}) == nil
    end

    test "from_jsonb tolerates unknown status string" do
      jsonb = %{"status" => "wat"}
      restored = Snapshot.from_jsonb(jsonb)
      assert restored.status == :summarized
    end

    test "from_jsonb wraps non-list summarized_request_ids defensively" do
      jsonb = %{"summarized_request_ids" => "r1"}
      restored = Snapshot.from_jsonb(jsonb)
      assert restored.summarized_request_ids == ["r1"]
    end
  end

  describe "preview/2" do
    test "returns nil for nil input" do
      assert Snapshot.preview(nil, 100) == nil
    end

    test "compacts whitespace and truncates with an ellipsis" do
      text = "  one    two   three  four  five\n  six  "

      assert Snapshot.preview(text, 200) == "one two three four five six"
      assert Snapshot.preview(text, 5) == "one t…"
    end
  end
end
