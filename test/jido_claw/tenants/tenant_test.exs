defmodule JidoClaw.Tenants.TenantTest do
  @moduledoc """
  Coverage for the v0.6.4 `Tenants.Tenant` registry resource.

  Locks in:

    * `:register` is upsert-on-PK with `upsert_fields([:updated_at])`,
      so a duplicate-id call preserves `status`/`name`/`config` and only
      `updated_at` advances. A `:suspended` tenant is NOT silently
      reactivated by a routine resolver-layer call.
    * `ensure/1` is idempotent and collapses concurrent first-writes
      onto one row.
    * `:suspend`, `:resume`, `:archive` flip `status` (and stamp
      `archived_at` for `:archive`).
    * `:by_id` and `:list` return the expected shape.
    * No `:destroy` action is exposed — `Audit.Event` rows FK at
      tenants and a hard delete would orphan history.
  """
  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Tenants.Tenant

  describe ":register / upsert preservation" do
    test "first call inserts; second call with same id no-ops the user fields" do
      id = unique_tenant_id("upsert")

      {:ok, first} = Tenant.register(%{id: id, name: "First Name", status: :active})
      assert first.id == id
      assert first.name == "First Name"
      assert first.status == :active

      # Sleep a microsecond so the updated_at advance is observable in
      # the assertion below — test would otherwise race on the
      # microsecond timestamp.
      Process.sleep(2)

      {:ok, second} =
        Tenant.register(%{id: id, name: "Second Name", status: :active, config: %{x: 1}})

      assert second.id == id
      # Only :updated_at is in upsert_fields — the user-supplied name
      # and config are preserved on conflict.
      assert second.name == "First Name"
      assert second.config == %{}
      assert DateTime.compare(second.updated_at, first.updated_at) == :gt
    end

    test ":suspended tenant is NOT reactivated by a routine ensure-style register call" do
      id = unique_tenant_id("suspend-survives")

      {:ok, _} = Tenant.register(%{id: id, status: :active})
      {:ok, suspended} = Tenant.suspend(id, %{})
      assert suspended.status == :suspended

      # Resolver-style ensure under a fresh request — must not flip
      # status back to :active.
      {:ok, after_ensure} = Tenant.ensure(id)
      assert after_ensure.status == :suspended
    end
  end

  describe "ensure/1 idempotency" do
    test "concurrent ensure/1 calls collapse onto the same row" do
      id = unique_tenant_id("concurrent-ensure")

      results =
        1..20
        |> Task.async_stream(fn _ -> Tenant.ensure(id) end,
          max_concurrency: 20,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      ids =
        results
        |> Enum.map(fn {:ok, row} -> row.id end)
        |> Enum.uniq()

      assert ids == [id]

      # And only one row exists in the registry.
      {:ok, all} = Tenant.list()
      assert Enum.count(all, &(&1.id == id)) == 1
    end

    test "ensure/1 returns the existing row when one is already present" do
      id = unique_tenant_id("ensure-existing")
      {:ok, original} = Tenant.register(%{id: id, name: id, status: :active})

      Process.sleep(2)

      {:ok, after_ensure} = Tenant.ensure(id)
      assert after_ensure.id == original.id
      assert after_ensure.name == original.name
      assert after_ensure.status == :active
    end
  end

  describe "state transitions" do
    test ":suspend flips :active → :suspended" do
      id = seed_tenant("suspend")
      {:ok, suspended} = Tenant.suspend(id, %{})
      assert suspended.status == :suspended
    end

    test ":resume flips :suspended → :active" do
      id = seed_tenant("resume")
      {:ok, _} = Tenant.suspend(id, %{})
      {:ok, resumed} = Tenant.resume(id, %{})
      assert resumed.status == :active
    end

    test ":archive flips status to :terminating and stamps archived_at" do
      id = seed_tenant("archive")
      {:ok, archived} = Tenant.archive(id, %{})
      assert archived.status == :terminating
      assert %DateTime{} = archived.archived_at
    end
  end

  describe ":by_id / :list" do
    test ":by_id returns the matching row" do
      id = seed_tenant("by-id")
      {:ok, row} = Tenant.by_id(id)
      assert row.id == id
    end

    test ":list returns rows in inserted_at ascending order" do
      a = seed_tenant("list-a")
      Process.sleep(2)
      b = seed_tenant("list-b")
      Process.sleep(2)
      c = seed_tenant("list-c")

      {:ok, all} = Tenant.list()
      ids = Enum.map(all, & &1.id)

      # The full list may include other tenants from prior tests,
      # so filter to ours and assert relative ordering.
      ours = Enum.filter(ids, &(&1 in [a, b, c]))
      assert ours == [a, b, c]
    end
  end

  describe "no destroy" do
    test "Tenant resource does not expose a destroy code-interface function" do
      refute function_exported?(Tenant, :destroy, 1)
      refute function_exported?(Tenant, :destroy, 2)
    end
  end
end
