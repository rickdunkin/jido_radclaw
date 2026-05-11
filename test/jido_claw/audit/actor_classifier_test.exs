defmodule JidoClaw.Audit.ActorClassifierTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Audit.ActorClassifier.classify/1`.

  Locks in the priority order documented on the module — in
  particular that `kind: :system` beats a non-nil `user_id` (the
  canonical system-actor shape from `Authorization.Actor.system/1`).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Audit.ActorClassifier
  alias JidoClaw.Authorization.Actor

  describe "classify/1" do
    test "nil → {:system, nil}" do
      assert ActorClassifier.classify(nil) == {:system, nil}
    end

    test "Actor.system(tid) → {:system, nil}" do
      assert ActorClassifier.classify(Actor.system("t1")) == {:system, nil}
    end

    test "Actor.build(%User{}) → {:user, user.id}" do
      user = %JidoClaw.Accounts.User{id: "abc-123"}
      actor = Actor.build(user)

      assert ActorClassifier.classify(actor) == {:user, "abc-123"}
    end

    test "%{agent_id, tenant_id} → {:agent, agent_id}" do
      assert ActorClassifier.classify(%{agent_id: "a", tenant_id: "t"}) == {:agent, "a"}
    end

    test "%{kind: :user, id: \"u\"} → {:user, \"u\"}" do
      assert ActorClassifier.classify(%{kind: :user, id: "u"}) == {:user, "u"}
    end

    test "%{\"kind\" => \"user\", \"id\" => \"u\"} → {:user, \"u\"} (string keys)" do
      assert ActorClassifier.classify(%{"kind" => "user", "id" => "u"}) == {:user, "u"}
    end

    test "%{kind: :agent, id: \"a\"} → {:agent, \"a\"}" do
      assert ActorClassifier.classify(%{kind: :agent, id: "a"}) == {:agent, "a"}
    end

    test "bare %{id: \"abc\"} → {:system, nil} (rule 4 not satisfied without kind)" do
      assert ActorClassifier.classify(%{id: "abc"}) == {:system, nil}
    end

    test "canonical system actor → {:system, nil} (explicit kind beats non-nil user_id key)" do
      # Authorization.Actor.system/1 returns this shape. Without the
      # kind override, the non-nil user_id key (it's nil, but the key
      # is present) would risk a misclassification — fix 2 makes the
      # nil-id rule explicit.
      assert ActorClassifier.classify(%{kind: :system, user_id: nil, tenant_id: "t1"}) ==
               {:system, nil}
    end

    test "kind: :system overrides non-nil user_id" do
      # Belt and suspenders: even if a system actor carries a non-nil
      # user_id (atypical), the explicit kind wins.
      assert ActorClassifier.classify(%{kind: :system, user_id: "u", tenant_id: "t"}) ==
               {:system, nil}
    end

    test "non-canonical actor without kind/agent_id/user_id falls through" do
      # A bare struct that happens to expose `:id` — not a user or
      # agent identifier in our actor contract.
      assert ActorClassifier.classify(%{some_other: "field"}) == {:system, nil}
    end

    test "empty user_id (\"\") does not classify as :user" do
      # Empty strings are treated as absent so we don't write a row
      # with actor_id = "".
      assert ActorClassifier.classify(%{user_id: "", tenant_id: "t"}) == {:system, nil}
    end
  end
end
