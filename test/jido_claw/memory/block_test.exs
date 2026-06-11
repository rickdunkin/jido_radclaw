defmodule JidoClaw.Memory.BlockTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Memory.{Block, BlockRevision}
  alias JidoClaw.Workspaces.Resolver

  setup do
    tenant_id = seed_tenant("block")

    {:ok, ws} =
      Resolver.ensure_workspace(
        tenant_id,
        "/tmp/block_test_#{System.unique_integer([:positive])}",
        []
      )

    {:ok, tenant_id: tenant_id, workspace: ws}
  end

  describe ":write" do
    test "creates a block at the workspace scope", %{tenant_id: tenant_id, workspace: ws} do
      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "style_guide",
        value: "snake_case for everything in elixir",
        source: :user
      }

      assert {:ok, block} = Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert block.label == "style_guide"
      assert block.invalid_at == nil
      assert block.char_limit == 2000
      assert block.pinned == true
    end

    test "rejects values exceeding char_limit", %{tenant_id: tenant_id, workspace: ws} do
      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "long",
        value: String.duplicate("x", 3000),
        char_limit: 2000,
        source: :user
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert inspect(err) =~ "value_exceeds_char_limit"
    end

    test "rejects when scope FK is missing for the kind", %{tenant_id: tenant_id} do
      attrs = %{
        scope_kind: :workspace,
        # workspace_id missing
        label: "x",
        value: "v",
        source: :user
      }

      assert {:error, %Ash.Error.Invalid{} = err} =
               Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert inspect(err) =~ "scope_fk_required"
    end
  end

  describe ":write redaction" do
    test "redacts secrets in value and description before persistence", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "creds",
        value: "anthropic key is sk-ant-aaaabbbbccccddddeeeeffff",
        description: "contains sk-ant-aaaabbbbccccddddeeeeffff too",
        source: :user
      }

      assert {:ok, block} = Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

      assert block.value =~ "[REDACTED:ANTHROPIC_KEY]"
      refute block.value =~ "sk-ant-aaaabbbbccccddddeeeeffff"
      assert block.description =~ "[REDACTED:ANTHROPIC_KEY]"
      refute block.description =~ "sk-ant-aaaabbbbccccddddeeeeffff"
    end

    test "redaction runs before CapValueLength — cap validates the redacted value", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      # Raw secret: 31 bytes. Redacted form `[REDACTED:API_KEY]`:
      # 18 bytes. With char_limit 25 the write succeeds only if the
      # cap sees the redacted value — it would reject the raw one.
      raw = "sk-abcdefghijklmnopqrstuvwxyz01"
      assert byte_size(raw) == 31

      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "cap_order",
        value: raw,
        char_limit: 25,
        source: :user
      }

      assert {:ok, block} = Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert block.value == "[REDACTED:API_KEY]"
    end

    test "is idempotent — already-redacted content stores unchanged", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      attrs = %{
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "already_redacted",
        value: "key was [REDACTED:ANTHROPIC_KEY] all along",
        source: :user
      }

      assert {:ok, block} = Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert block.value == "key was [REDACTED:ANTHROPIC_KEY] all along"
    end

    test "revise/3 routes through :write and redacts the new value", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "revise_redact",
            value: "clean v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:ok, revised} =
               Block.revise(block, %{value: "now with sk-ant-aaaabbbbccccddddeeeeffff"},
                 actor: actor_for(tenant_id)
               )

      assert revised.value =~ "[REDACTED:ANTHROPIC_KEY]"
      refute revised.value =~ "sk-ant-aaaabbbbccccddddeeeeffff"
    end

    test "accepts the CLI cross-scope override attrs (source: :user, written_by: \"cli\")", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      # Mirrors Commands.apply_block_edit/3's override-write shape —
      # pins source: :user against Block's @sources constraint
      # (:user_save is Fact vocabulary and used to fail here).
      attrs = %{
        scope_kind: :workspace,
        user_id: nil,
        workspace_id: ws.id,
        project_id: nil,
        session_id: nil,
        label: "cli_override",
        description: nil,
        value: "edited via cli",
        char_limit: 2000,
        pinned: true,
        position: 0,
        source: :user,
        written_by: "cli"
      }

      assert {:ok, block} = Block.write(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
      assert block.source == :user
      assert block.written_by == "cli"
    end
  end

  describe ":revise" do
    test "updates value and writes a BlockRevision", %{tenant_id: tenant_id, workspace: ws} do
      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "rev_label",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:ok, updated} =
               Block.revise(block, %{value: "v2", reason: "user_edit"},
                 actor: actor_for(tenant_id)
               )

      assert updated.value == "v2"

      revisions = BlockRevision.list!(tenant: tenant_id, actor: actor_for(tenant_id))
      assert Enum.any?(revisions, fn r -> r.value == "v1" end)
    end

    test "invalidate-and-replace: prior row is invalidated, new row carries new id", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      {:ok, prior} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "iar_label",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:ok, replacement} =
               Block.revise(prior, %{value: "v2", reason: "user_edit"},
                 actor: actor_for(tenant_id)
               )

      # Replacement is a new row, not an in-place update.
      refute replacement.id == prior.id
      assert replacement.value == "v2"
      assert replacement.invalid_at == nil

      # Prior row is now invalidated + expired.
      {:ok, reloaded_prior} = Block.by_id_global(prior.id)
      assert reloaded_prior.invalid_at != nil
      assert reloaded_prior.expired_at != nil

      # history_for_label returns at least both rows, ordered by inserted_at ascending.
      assert {:ok, history} =
               Block.history_for_label(:workspace, ws.id, "iar_label",
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert [_, _ | _] = history

      sorted_inserted_ats = Enum.map(history, & &1.inserted_at)
      assert sorted_inserted_ats == Enum.sort(sorted_inserted_ats, {:asc, DateTime})
    end
  end

  describe ":invalidate" do
    test "marks the row invalid + expired", %{tenant_id: tenant_id, workspace: ws} do
      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "inv_label",
            value: "to_invalidate",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:ok, invalidated} =
               Block.invalidate(block, %{reason: "no_longer_relevant"},
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert invalidated.invalid_at != nil
      assert invalidated.expired_at != nil
    end
  end

  describe "history_for_label" do
    test "returns the chain of revisions ordered by inserted_at", %{
      tenant_id: tenant_id,
      workspace: ws
    } do
      {:ok, block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "history_label",
            value: "v1",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      {:ok, _} = Block.revise(block, %{value: "v2"}, actor: actor_for(tenant_id))

      assert {:ok, blocks} =
               Block.history_for_label(:workspace, ws.id, "history_label",
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert is_list(blocks)
    end
  end
end
