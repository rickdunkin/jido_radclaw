defmodule JidoClaw.Memory.Consolidator.PromptTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Memory.Consolidator.Prompt

  defp scope_state(clusters) do
    %{
      scope: %{
        scope_kind: :workspace,
        tenant_id: "tenant-1",
        user_id: nil,
        workspace_id: "ws-uuid",
        project_id: nil,
        session_id: nil
      },
      clusters: clusters
    }
  end

  test "renders scope header, both cluster ids, and the full tool surface" do
    clusters = [
      %{id: "facts:hash:abc", type: :facts, fact_ids: ["f1", "f2"]},
      %{id: "messages:sess-1", type: :messages, message_ids: ["m1", "m2", "m3"]}
    ]

    out = Prompt.build(scope_state(clusters))

    assert out =~ "workspace (tenant=tenant-1, fk=ws-uuid)"
    assert out =~ "facts:hash:abc"
    assert out =~ "messages:sess-1"
    assert out =~ "type=facts"
    assert out =~ "type=messages"
    assert out =~ "size=2"
    assert out =~ "size=3"

    for tool <- ~w(
          list_clusters
          get_cluster
          get_active_blocks
          find_similar_facts
          propose_add
          propose_update
          propose_delete
          propose_block_update
          propose_link
          defer_cluster
          commit_proposals
        ) do
      assert out =~ tool, "expected prompt to mention #{tool}"
    end

    for relation <- ~w(supports contradicts supersedes duplicates depends_on related) do
      assert out =~ relation, "expected prompt to mention link relation #{relation}"
    end
  end

  test "empty clusters still produces a valid prompt" do
    out = Prompt.build(scope_state([]))

    assert out =~ "workspace (tenant=tenant-1, fk=ws-uuid)"
    assert out =~ "(none)"
    assert out =~ "list_clusters"
    assert out =~ "commit_proposals"
  end
end
