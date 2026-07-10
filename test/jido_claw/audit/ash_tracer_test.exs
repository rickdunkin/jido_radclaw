defmodule JidoClaw.Audit.AshTracerTest do
  @moduledoc """
  Coverage for `JidoClaw.Audit.AshTracer`.

  Locks in:

    * A cross-tenant `Block.write` denial emits a `:policy_denied`
      audit row in the **actor's** tenant carrying the resource module
      and action name in the payload.
    * Non-denial errors (e.g., validation/Ash.Error.Invalid) do NOT
      emit a `:policy_denied` audit row.
    * A successful action emits no `:policy_denied` row.
    * `trace_type?/1` only returns `true` for `:action` spans — nested
      spans flow through but never clear our action metadata.
    * A `Authorization.Actor.system/1` system actor classifies as
      `actor_kind: :system`, not `:user`, even though the canonical
      shape carries a `:user_id` key.
  """
  use JidoClaw.TenantCase, async: false

  require Ash.Tracer

  alias JidoClaw.Audit.AshTracer
  alias JidoClaw.Audit.Event
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Memory.Block

  describe "cross-tenant denial" do
    test "emits a :policy_denied audit row in the actor's tenant" do
      tenant_a = seed_tenant("tracer-tenant-a")
      tenant_b = seed_tenant("tracer-tenant-b")

      {:ok, ws_b} = seed_workspace(tenant_b)

      # Actor is in tenant_a; attempt to write a Block under tenant_b's
      # workspace. ActorTenantMatches fails → Ash.Error.Forbidden.
      result =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "denied-block",
            value: "v",
            source: :user
          },
          tenant: tenant_b,
          actor: actor_for(tenant_a)
        )

      assert {:error, %Ash.Error.Forbidden{}} = result

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))

          Enum.any?(rows, &(&1.event_kind == :policy_denied))
        end)

      {:ok, rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))

      denial =
        Enum.find(rows, fn r ->
          r.event_kind == :policy_denied and r.target_kind == :memory_block
        end)

      assert denial, "expected a :policy_denied audit row for the rejected Block.write"

      payload = denial.payload
      pick = fn key -> Map.get(payload, Atom.to_string(key)) || Map.get(payload, key) end

      assert pick.(:resource) == inspect(Block)
      assert pick.(:action) == "write"
      assert pick.(:reason) != nil

      assert denial.actor_kind == :user
      assert denial.actor_id == tenant_a
    end

    test "does not write a :policy_denied row in the data-owner's tenant" do
      tenant_a = seed_tenant("tracer-no-leak-actor")
      tenant_b = seed_tenant("tracer-no-leak-owner")

      {:ok, ws_b} = seed_workspace(tenant_b)

      _ =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "denied-block-b",
            value: "v",
            source: :user
          },
          tenant: tenant_b,
          actor: actor_for(tenant_a)
        )

      # Even after waiting, tenant_b should have NO policy_denied rows.
      Process.sleep(150)

      {:ok, rows_b} = Event.read(tenant: tenant_b, actor: actor_for(tenant_b))

      refute Enum.any?(rows_b, &(&1.event_kind == :policy_denied)),
             "denied attempt should not appear in the data-owner tenant's audit log"
    end
  end

  describe "non-denial errors" do
    test "Ash.Error.Invalid (validation) does NOT emit a :policy_denied row" do
      tenant_id = seed_tenant("tracer-invalid")
      {:ok, _ws} = seed_workspace(tenant_id)

      # Missing required attrs forces an Ash.Error.Invalid.
      result =
        Block.write(
          %{
            # scope_kind, label, value, source all required → invalid
            workspace_id: Ecto.UUID.generate()
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      assert {:error, %Ash.Error.Invalid{}} = result

      Process.sleep(150)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      refute Enum.any?(rows, &(&1.event_kind == :policy_denied)),
             "validation errors should not be classified as policy denials"
    end
  end

  describe "successful action" do
    test "does NOT emit a :policy_denied row" do
      tenant_id = seed_tenant("tracer-success")
      {:ok, ws} = seed_workspace(tenant_id)

      {:ok, _block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "ok-block",
            value: "v",
            source: :user
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )

      Process.sleep(150)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      refute Enum.any?(rows, &(&1.event_kind == :policy_denied))
    end
  end

  describe "trace_type?/1" do
    test "only :action spans match — nested span types are filtered" do
      assert AshTracer.trace_type?(:action)
      refute AshTracer.trace_type?(:changeset)
      refute AshTracer.trace_type?(:query)
      refute AshTracer.trace_type?(:validation)
      refute AshTracer.trace_type?(:change)
    end

    test "metadata survives a nested span and set_handled_error still emits" do
      # Reproduces the bug Fix 1 addresses: before the trace_type?
      # restriction, Ash's dispatcher would call our stop_span/0 on
      # the inner :changeset span (after start_span ran) and clear
      # our action metadata — so the subsequent set_handled_error
      # call would have no metadata to attach to. The fix gates
      # start/stop on trace_type?/1.
      tenant_id = seed_tenant("tracer-nested-span")
      {:ok, _ws} = seed_workspace(tenant_id)

      Ash.Tracer.span :action, "outer", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: Block,
          action: :write,
          actor: actor_for(tenant_id),
          tenant: tenant_id,
          authorize?: true
        })

        Ash.Tracer.span :changeset, "nested", [AshTracer] do
          :ok
        end

        # Must fire while still inside the outer :action span — the
        # macro's `after` clause runs stop_span/0 on the way out and
        # the metadata is gone by design after that.
        AshTracer.set_handled_error(%Ash.Error.Forbidden{errors: []}, [])
      end

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

          Enum.any?(rows, fn r ->
            r.event_kind == :policy_denied and r.target_kind == :memory_block
          end)
        end)
    end
  end

  describe "set_metadata/2" do
    test "calculation metadata does not clobber the active action metadata" do
      # Ash dispatches `set_metadata(tracer, :action, meta)` from
      # inside a `:calculation` span (deps/ash/.../calculations.ex)
      # with metadata that has `:calculation` but no `:action`. Before
      # the `%{action: _}` guard, that call would replace the real
      # action metadata and the subsequent `set_handled_error` would
      # emit an audit row whose payload had no action attribution.
      tenant_id = seed_tenant("tracer-calc-clobber")
      {:ok, _ws} = seed_workspace(tenant_id)

      Ash.Tracer.span :action, "outer", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: Block,
          action: :read,
          actor: actor_for(tenant_id),
          tenant: tenant_id,
          authorize?: true
        })

        # Shape mirrors what calculations.ex builds: :calculation
        # present, :action absent. Must NOT clobber the outer span's
        # action metadata.
        AshTracer.set_metadata(:action, %{
          resource: Block,
          calculation: "some_calc",
          actor: actor_for(tenant_id),
          tenant: tenant_id,
          authorize?: true
        })

        AshTracer.set_handled_error(%Ash.Error.Forbidden{errors: []}, [])
      end

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

          Enum.any?(rows, fn r ->
            r.event_kind == :policy_denied and r.target_kind == :memory_block
          end)
        end)

      {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

      denial =
        Enum.find(rows, fn r ->
          r.event_kind == :policy_denied and r.target_kind == :memory_block
        end)

      assert denial

      pick = fn key ->
        Map.get(denial.payload, Atom.to_string(key)) || Map.get(denial.payload, key)
      end

      # Action attribution preserved — the calc metadata was filtered.
      assert pick.(:action) == "read"
    end

    test "a nested action span restores its parent's metadata" do
      tenant_id = seed_tenant("tracer-nested-action")
      {:ok, _ws} = seed_workspace(tenant_id)

      Ash.Tracer.span :action, "outer", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: Block,
          action: :write,
          actor: actor_for(tenant_id),
          tenant: tenant_id,
          authorize?: true
        })

        Ash.Tracer.span :action, "inner", [AshTracer] do
          AshTracer.set_metadata(:action, %{
            resource: JidoClaw.Tenants.Tenant,
            action: :by_id,
            actor: nil,
            tenant: nil,
            authorize?: false
          })
        end

        AshTracer.set_handled_error(%Ash.Error.Forbidden{errors: []}, [])
      end

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_id, actor: actor_for(tenant_id))

          Enum.any?(rows, fn row ->
            row.event_kind == :policy_denied and
              row.target_kind == :memory_block and
              Map.get(row.payload, "action", Map.get(row.payload, :action)) == "write"
          end)
        end)
    end
  end

  describe "propagation fence (no double-emit)" do
    # These drive REAL denied actions (each opening its own real action span
    # through the globally configured tracer) inside a real enclosing action
    # span — the file's established idiom. Ash re-dispatches the same handled
    # denial at every enclosing boundary as it unwinds, re-wrapped with fresh
    # bread_crumbs/stacktraces, which is why the fence keys on span
    # generations rather than term equality (an identical-struct replay
    # would false-green).

    test "a denial propagating through an enclosing action span emits exactly ONE row" do
      tenant_a = seed_tenant("tracer-fence-a")
      tenant_b = seed_tenant("tracer-fence-b")
      {:ok, ws_b} = seed_workspace(tenant_b)

      Ash.Tracer.span :action, "parent", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: JidoClaw.Workspaces.Workspace,
          action: :parent_flow,
          actor: actor_for(tenant_a),
          tenant: tenant_a,
          authorize?: true
        })

        assert {:error, %Ash.Error.Forbidden{} = error} =
                 Block.write(
                   %{
                     scope_kind: :workspace,
                     workspace_id: ws_b.id,
                     label: "fence-child",
                     value: "v",
                     source: :user
                   },
                   tenant: tenant_b,
                   actor: actor_for(tenant_a)
                 )

        # Ash re-dispatches the handled denial at the enclosing action
        # boundary as it unwinds — the double-emit this fence suppresses.
        AshTracer.set_handled_error(error, [])
      end

      :ok = eventually(fn -> denial_count(tenant_a) == 1 end)

      # Settle: a buggy second write would land asynchronously right behind
      # the first — re-assert after the writer has had time to drain.
      Process.sleep(150)
      assert denial_count(tenant_a) == 1
    end

    test "a second caught sibling denial still emits — exactly TWO rows" do
      tenant_a = seed_tenant("tracer-fence-siblings-a")
      tenant_b = seed_tenant("tracer-fence-siblings-b")
      {:ok, ws_b} = seed_workspace(tenant_b)

      denied_write = fn label ->
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: label,
            value: "v",
            source: :user
          },
          tenant: tenant_b,
          actor: actor_for(tenant_a)
        )
      end

      Ash.Tracer.span :action, "parent", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: JidoClaw.Workspaces.Workspace,
          action: :parent_flow,
          actor: actor_for(tenant_a),
          tenant: tenant_a,
          authorize?: true
        })

        # Parent catches the first denial and tries again with a sibling —
        # a genuinely NEW denial at a newer generation, which must emit.
        assert {:error, %Ash.Error.Forbidden{}} = denied_write.("fence-sibling-1")
        assert {:error, %Ash.Error.Forbidden{} = second} = denied_write.("fence-sibling-2")

        # Only the second propagates out of the parent.
        AshTracer.set_handled_error(second, [])
      end

      :ok = eventually(fn -> denial_count(tenant_a) == 2 end)
      Process.sleep(150)
      assert denial_count(tenant_a) == 2
    end

    test "a successful cleanup action does not un-suppress the original denial" do
      tenant_a = seed_tenant("tracer-fence-cleanup-a")
      tenant_b = seed_tenant("tracer-fence-cleanup-b")
      {:ok, ws_a} = seed_workspace(tenant_a)
      {:ok, ws_b} = seed_workspace(tenant_b)

      Ash.Tracer.span :action, "parent", [AshTracer] do
        AshTracer.set_metadata(:action, %{
          resource: JidoClaw.Workspaces.Workspace,
          action: :parent_flow,
          actor: actor_for(tenant_a),
          tenant: tenant_a,
          authorize?: true
        })

        assert {:error, %Ash.Error.Forbidden{} = error} =
                 Block.write(
                   %{
                     scope_kind: :workspace,
                     workspace_id: ws_b.id,
                     label: "fence-cleanup-denied",
                     value: "v",
                     source: :user
                   },
                   tenant: tenant_b,
                   actor: actor_for(tenant_a)
                 )

        # A successful cleanup/rollback Ash action runs a NEWER generation —
        # it must not reset the fence (the rejected reset-on-action-start
        # design would re-emit the original denial below).
        assert {:ok, _} =
                 Block.write(
                   %{
                     scope_kind: :workspace,
                     workspace_id: ws_a.id,
                     label: "fence-cleanup-ok",
                     value: "v",
                     source: :user
                   },
                   tenant: tenant_a,
                   actor: actor_for(tenant_a)
                 )

        # Parent finally observes the ORIGINAL denial.
        AshTracer.set_handled_error(error, [])
      end

      :ok = eventually(fn -> denial_count(tenant_a) == 1 end)
      Process.sleep(150)
      assert denial_count(tenant_a) == 1
    end
  end

  describe "system actor classification" do
    test "Actor.system(tenant) cross-tenant denial records actor_kind: :system" do
      # Without Fix 2, the canonical system actor —
      # %{kind: :system, user_id: nil, tenant_id: …} — would be
      # misclassified as actor_kind: :user because the user_id key is
      # present (its value is nil, but the old check used has_key?/2).
      tenant_a = seed_tenant("tracer-sys-actor-a")
      tenant_b = seed_tenant("tracer-sys-actor-b")

      {:ok, ws_b} = seed_workspace(tenant_b)

      _ =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_b.id,
            label: "sys-denied",
            value: "v",
            source: :user
          },
          tenant: tenant_b,
          actor: Actor.system(tenant_a)
        )

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))

          Enum.any?(rows, fn r ->
            r.event_kind == :policy_denied and r.actor_kind == :system
          end)
        end)

      {:ok, rows} = Event.read(tenant: tenant_a, actor: actor_for(tenant_a))

      denial =
        Enum.find(rows, fn r ->
          r.event_kind == :policy_denied and r.target_kind == :memory_block
        end)

      assert denial
      assert denial.actor_kind == :system
      assert denial.actor_id == nil
    end
  end

  describe "bare %User{} actor" do
    test "cross-tenant denial lands in the user-derived tenant, not the action target" do
      # A `%JidoClaw.Accounts.User{}` passed directly as `:actor`
      # (rather than via `Authorization.Actor.build/1`) has no
      # `:tenant_id` field. Without the new `tenant_from_actor/1`
      # User clause, the row was filed under the target tenant
      # (a cross-tenant data leak in the audit log).
      actor_tenant = seed_tenant("tracer-user-actor")
      target_tenant = seed_tenant("tracer-user-target")

      {:ok, ws_target} = seed_workspace(target_tenant)

      user = %JidoClaw.Accounts.User{id: actor_tenant}

      _ =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws_target.id,
            label: "user-denied",
            value: "v",
            source: :user
          },
          tenant: target_tenant,
          actor: user
        )

      :ok =
        eventually(fn ->
          {:ok, rows} = Event.read(tenant: actor_tenant, actor: actor_for(actor_tenant))

          Enum.any?(rows, &(&1.event_kind == :policy_denied))
        end)

      # The denial belongs to the actor's tenant…
      {:ok, actor_rows} = Event.read(tenant: actor_tenant, actor: actor_for(actor_tenant))

      denial =
        Enum.find(actor_rows, fn r ->
          r.event_kind == :policy_denied and r.target_kind == :memory_block
        end)

      assert denial
      assert denial.actor_kind == :user
      assert denial.actor_id == actor_tenant

      # …and must NOT appear in the target tenant's audit log.
      Process.sleep(50)
      {:ok, target_rows} = Event.read(tenant: target_tenant, actor: actor_for(target_tenant))

      refute Enum.any?(target_rows, &(&1.event_kind == :policy_denied)),
             "bare %User{} actor denial should not file under the target tenant's audit log"
    end
  end

  defp denial_count(tenant) do
    {:ok, rows} = Event.read(tenant: tenant, actor: actor_for(tenant))
    Enum.count(rows, &(&1.event_kind == :policy_denied))
  end

  defp eventually(fun, deadline_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
