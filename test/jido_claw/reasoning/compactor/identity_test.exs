defmodule JidoClaw.Reasoning.Compactor.IdentityTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.Identity

  describe "resolve/3" do
    test "REPL main (template is main) resolves to main" do
      assert Identity.resolve("main", "main", "sess-123") == "main"
    end

    test "chat main (agent_id equals session_id) resolves to main" do
      assert Identity.resolve("main", "sess-123", "sess-123") == "main"
      # Even with a nil template, agent_id == session_id collapses to main —
      # this is the reader path (AgentView/Inspection) which has no template.
      assert Identity.resolve(nil, "sess-123", "sess-123") == "main"
    end

    test "handoff worker keeps its handoff agent id" do
      worker = "handoff:uuid-1:reviewer"
      assert Identity.resolve("reviewer", worker, "sess-123") == worker
    end

    test "spawned sub-agent (template nil) keeps its tag — NOT mapped to main" do
      # Guards the identity-helper trap: a naive `template in [nil, \"main\"]`
      # rule would mis-map this child onto \"main\".
      assert Identity.resolve(nil, "child_tag_42", "sess-123") == "child_tag_42"
    end

    test "spawned sub-agent with a worker template keeps its tag — NOT mapped to main" do
      # Per-template approval policy now stamps a worker template name onto
      # spawned/step children (was nil). Identity must still key off the tag:
      # resolve("coder", tag, session) == resolve(nil, tag, session) == tag.
      assert Identity.resolve("coder", "child_tag_42", "sess-123") == "child_tag_42"
    end

    test "main/0 is the canonical main id" do
      assert Identity.main() == "main"
    end
  end
end
