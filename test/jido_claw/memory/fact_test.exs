defmodule JidoClaw.Memory.FactTest.DuplicateRecorder do
  @moduledoc false
  # Stateful double for the :memory_fact_recorder seam in
  # JidoClaw.Memory.do_remember/4: fails the first `fail_count` record/2
  # calls with a real-shaped commit-time unique violation, then
  # delegates to Fact.record. record/2 takes (attrs, opts) exactly as
  # the Fact.record code interface.

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias JidoClaw.Memory.Fact

  @spec child_spec(non_neg_integer()) :: Supervisor.child_spec()
  def child_spec(fail_count) do
    %{
      id: __MODULE__,
      start:
        {Agent, :start_link, [fn -> %{remaining: fail_count, calls: 0} end, [name: __MODULE__]]}
    }
  end

  @spec calls() :: non_neg_integer()
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @spec record(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def record(attrs, opts) do
    action =
      Agent.get_and_update(__MODULE__, fn state ->
        action = if state.remaining > 0, do: :fail, else: :delegate
        {action, %{state | calls: state.calls + 1, remaining: max(state.remaining - 1, 0)}}
      end)

    case action do
      :fail -> {:error, duplicate_error()}
      :delegate -> Fact.record(attrs, opts)
    end
  end

  defp duplicate_error do
    Invalid.exception(
      errors: [
        InvalidAttribute.exception(
          field: :label,
          message: "has already been taken",
          private_vars: [
            constraint: "memory_facts_unique_active_label_per_scope_workspace_index",
            constraint_type: :unique,
            detail: nil
          ]
        )
      ]
    )
  end
end

defmodule JidoClaw.Memory.FactTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Memory.FactTest.DuplicateRecorder

  alias JidoClaw.Memory
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Workspaces.Resolver

  setup do
    tenant_id = seed_tenant("fact")

    {:ok, ws} =
      Resolver.ensure_workspace(
        tenant_id,
        "/tmp/fact_test_#{System.unique_integer([:positive])}",
        []
      )

    tool_context = %{
      tenant_id: tenant_id,
      user_id: nil,
      workspace_uuid: ws.id,
      session_uuid: nil
    }

    {:ok, tenant_id: tenant_id, tool_context: tool_context, workspace: ws}
  end

  describe ":record" do
    test "writes a Fact at the resolved scope", %{
      tenant_id: tenant_id,
      tool_context: tc,
      workspace: ws
    } do
      :ok =
        Memory.remember_from_user(
          %{key: "label_a", content: "value_a", type: "fact"},
          tc
        )

      [fact] = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert fact.tenant_id == tenant_id
      assert fact.scope_kind == :workspace
      assert fact.workspace_id == ws.id
      assert fact.label == "label_a"
      assert fact.content == "value_a"
      assert fact.tags == ["fact"]
      assert fact.source == :user_save
      assert fact.invalid_at == nil
      assert fact.expired_at == nil
    end

    test "second write at same label invalidates the prior", %{
      tenant_id: tenant_id,
      tool_context: tc
    } do
      :ok = Memory.remember_from_user(%{key: "L", content: "v1", type: "fact"}, tc)
      :ok = Memory.remember_from_user(%{key: "L", content: "v2", type: "fact"}, tc)

      facts = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      assert [_, _] = facts

      old = Enum.find(facts, &(&1.content == "v1"))
      new = Enum.find(facts, &(&1.content == "v2"))

      assert old.content == "v1"
      assert old.invalid_at != nil
      assert old.expired_at != nil

      assert new.content == "v2"
      assert new.invalid_at == nil
    end

    # The true commit-time race (two writers, both past the
    # InvalidatePriorActiveLabel pre-check) is unreproducible under the
    # SQL sandbox — transactions never commit, so the partial unique
    # index never fires. The retry path it triggers is covered by the
    # seam-based "duplicate-key retry" tests below.
    test "single active row per (scope, label)", %{
      tenant_id: tenant_id,
      tool_context: tc
    } do
      :ok = Memory.remember_from_user(%{key: "L", content: "v1", type: "fact"}, tc)

      [fact] = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert fact.invalid_at == nil
    end

    test "redacts secrets in content before persistence", %{
      tenant_id: tenant_id,
      tool_context: tc
    } do
      :ok =
        Memory.remember_from_user(
          %{key: "leaky", content: "my key is sk-ant-aaaabbbbccccddddeeeeffff", type: "fact"},
          tc
        )

      [fact] = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert fact.content =~ "[REDACTED:ANTHROPIC_KEY]"
      refute fact.content =~ "sk-ant-aaaabbbbccccddddeeeeffff"
    end
  end

  describe "duplicate-key retry (via :memory_fact_recorder seam)" do
    test "retries once on duplicate; retry invalidates the racing winner's row",
         %{tenant_id: tenant_id, tool_context: tc} do
      # The "winner" of the simulated race landed first (real recorder).
      :ok = Memory.remember_from_user(%{key: "race", content: "winner", type: "fact"}, tc)

      install_recorder!(1)

      # The "loser" hits the unique violation once, then the retry runs
      # through the real Fact.record — InvalidatePriorActiveLabel
      # invalidates the winner's fresh row: last-writer-wins.
      assert :ok =
               Memory.remember_from_user(
                 %{key: "race", content: "second value", type: "fact"},
                 tc
               )

      assert DuplicateRecorder.calls() == 2

      facts = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))

      assert [active] = Enum.filter(facts, &is_nil(&1.invalid_at))
      assert active.label == "race"
      assert active.content == "second value"

      winner = Enum.find(facts, &(&1.content == "winner"))
      assert winner.invalid_at != nil
    end

    test "skips idempotently on a second duplicate — no third attempt",
         %{tenant_id: tenant_id, tool_context: tc} do
      install_recorder!(2)

      assert :ok =
               Memory.remember_from_user(%{key: "race2", content: "lost", type: "fact"}, tc)

      assert DuplicateRecorder.calls() == 2
      assert [] = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
    end
  end

  defp install_recorder!(fail_count) do
    start_supervised!({DuplicateRecorder, fail_count})
    Application.put_env(:jido_claw, :memory_fact_recorder, DuplicateRecorder)
    on_exit(fn -> Application.delete_env(:jido_claw, :memory_fact_recorder) end)
  end

  describe "content_hash + search_vector generated columns" do
    test "content_hash is populated by Postgres digest()", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "h", content: "hash me", type: "fact"}, tc)

      %Postgrex.Result{rows: [[hash]]} =
        JidoClaw.Repo.query!("SELECT content_hash FROM memory_facts WHERE label = 'h'")

      expected = :crypto.hash(:sha256, "hash me")
      assert hash == expected
    end

    test "search_vector is populated for label, content, and tags", %{tool_context: tc} do
      :ok =
        Memory.remember_from_user(
          %{key: "fts_label", content: "elixir is functional", type: "preference"},
          tc
        )

      %Postgrex.Result{rows: [[matched]]} =
        JidoClaw.Repo.query!(
          "SELECT count(*)::int FROM memory_facts " <>
            "WHERE search_vector @@ websearch_to_tsquery('english', 'elixir')"
        )

      assert matched >= 1
    end
  end

  describe "substring-superset regression (plan §3.19)" do
    test "recall finds api_base_url, preferred_style, foo.bar.baz", %{tool_context: tc} do
      :ok =
        Memory.remember_from_user(
          %{key: "api_base_url", content: "https://api.example.com", type: "fact"},
          tc
        )

      :ok =
        Memory.remember_from_user(
          %{key: "preferred_style", content: "snake_case", type: "preference"},
          tc
        )

      :ok = Memory.remember_from_user(%{key: "foo.bar.baz", content: "nested", type: "fact"}, tc)

      r1 = Memory.recall("api", tool_context: tc, limit: 5)
      assert Enum.any?(r1, fn m -> m.key == "api_base_url" end)

      r2 = Memory.recall("preference", tool_context: tc, limit: 5)
      assert Enum.any?(r2, fn m -> m.key == "preferred_style" end)

      r3 = Memory.recall("foo.bar", tool_context: tc, limit: 5)
      assert Enum.any?(r3, fn m -> m.key == "foo.bar.baz" end)
    end
  end

  describe "forget" do
    test "user_save forget invalidates the user-saved row", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "del", content: "v", type: "fact"}, tc)

      :ok = Memory.forget("del", tool_context: tc, source: :user_save)

      after_forget = Memory.recall("del", tool_context: tc, limit: 5)
      refute Enum.any?(after_forget, fn m -> m.key == "del" end)
    end

    test "model-source forget does not touch user-saved rows", %{
      tenant_id: tenant_id,
      tool_context: tc
    } do
      :ok = Memory.remember_from_user(%{key: "shared", content: "user", type: "fact"}, tc)

      :ok = Memory.forget("shared", tool_context: tc, source: :model_remember)

      survivors = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert Enum.any?(survivors, fn f -> f.label == "shared" and is_nil(f.invalid_at) end)
    end
  end

  describe "cross-tenant FK validation" do
    test "rejects a workspace_id pointing at a different tenant", %{workspace: ws} do
      other_tenant = seed_tenant("other")

      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "x",
        content: "y",
        tags: [],
        source: :user_save,
        trust_score: 0.7
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Fact.record(attrs, tenant: other_tenant, actor: actor_for(other_tenant))

      assert inspect(err) =~ "cross_tenant_fk_mismatch"
    end
  end

  describe "mixed-key attrs precedence" do
    test "atom keys win over string keys", %{
      tenant_id: tenant_id,
      tool_context: tc
    } do
      attrs = %{
        "key" => "string_label",
        "content" => "string_content",
        :key => "atom_label",
        :content => "atom_content",
        :type => "fact"
      }

      :ok = Memory.remember_from_user(attrs, tc)

      [fact] = Fact.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert fact.label == "atom_label"
      assert fact.content == "atom_content"
    end
  end

  describe "import_legacy + ResolveInitialEmbeddingStatus" do
    test "system import under :disabled workspace lands at :disabled (not :pending)" do
      tenant_id = seed_tenant("fact-embed-policy")

      {:ok, ws} =
        seed_workspace(tenant_id,
          path: "/tmp/fact_embed_#{System.unique_integer([:positive])}",
          embedding_policy: :disabled
        )

      # Omit :embedding_status so the change's resolution path runs.
      # Setting it would short-circuit the change and pass the test
      # without exercising fix 3.
      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "embed-policy",
        content: "value",
        tags: ["fact"],
        trust_score: 0.5,
        import_hash:
          Base.encode16(
            :crypto.hash(:sha256, "embed-policy-#{System.unique_integer([:positive])}"),
            case: :lower
          )
      }

      # `authorize?: false` mirrors the migration task's call shape —
      # the change's system-actor fallback (fix 3) is what makes the
      # nested Workspace.by_id lookup succeed under the read policy.
      assert {:ok, fact} =
               Fact.import_legacy(attrs, tenant: tenant_id, authorize?: false)

      assert fact.embedding_status == :disabled
    end
  end
end
