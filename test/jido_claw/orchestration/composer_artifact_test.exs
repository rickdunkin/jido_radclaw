defmodule JidoClaw.Orchestration.ComposerArtifactTest do
  @moduledoc """
  AR-2 Phase 2b — the encrypted ref-store. Covers the `store_pending` encode
  choreography (incl. a nil artifact), `resolve_value` round-trip through
  encrypt/decrypt regardless of state, encrypt-at-rest, the no-novel-atom
  normalizer, both cross-tenant FK guards + the lineage assertion, the
  active-keyed partial-unique index backstop, and the non-null contract.

  AR-2 Phase 2d — seed rows: a nullable `child_run_id` + a `wave_index: -1`
  sentinel keep a genesis seed artifact invisible to every real-wave read yet
  resolvable by ref.

  Non-async (`TenantCase`): the index/encrypt-at-rest assertions read raw
  Postgres rows, so it must not race other tenants' writes.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.ComposerArtifact.Envelope
  alias JidoClaw.Orchestration.WorkflowRun

  defp ref, do: "art_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp seed_lineage(label) do
    tenant_id = seed_tenant(label)
    actor = actor_for(tenant_id)

    {:ok, parent} =
      WorkflowRun.create(%{name: "parent", workflow_type: "composer"},
        tenant: tenant_id,
        actor: actor
      )

    {:ok, child} =
      WorkflowRun.create(
        %{name: "wave-0", workflow_type: "reactor", parent_run_id: parent.id},
        tenant: tenant_id,
        actor: actor
      )

    %{tenant_id: tenant_id, actor: actor, parent: parent, child: child}
  end

  defp pending_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        ref: ref(),
        name: "diff",
        producer: "coder",
        term: "the artifact value",
        child_run_id: ctx.child.id,
        wave_index: 0,
        parent_run_id: ctx.parent.id
      },
      overrides
    )
  end

  defp store(ctx, overrides) do
    ComposerArtifact.store_pending(pending_attrs(ctx, overrides),
      tenant: ctx.tenant_id,
      actor: ctx.actor
    )
  end

  describe "store_pending + resolve_value" do
    test "inserts a :pending row and round-trips the value through encrypt/decrypt" do
      ctx = seed_lineage("artifact-roundtrip")
      attrs = pending_attrs(ctx)

      assert {:ok, row} = store(ctx, attrs)
      assert row.state == :pending
      assert row.ref == attrs.ref
      assert row.name == "diff"
      assert row.producer == "coder"

      assert {:ok, "the artifact value"} =
               ComposerArtifact.resolve_value(attrs.ref, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "a nil artifact value round-trips (DefaultMapper emits nil for a nil source)" do
      ctx = seed_lineage("artifact-nil")
      attrs = pending_attrs(ctx, %{term: nil})

      assert {:ok, _row} = store(ctx, attrs)

      assert {:ok, nil} =
               ComposerArtifact.resolve_value(attrs.ref, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "resolves irrespective of state (a tombstoned ref still resolves)" do
      ctx = seed_lineage("artifact-state")
      attrs = pending_attrs(ctx)

      assert {:ok, row} = store(ctx, attrs)

      # Drive the row through the legal lifecycle (pending → active → tombstoned)
      # — the single-transition guards (P3) reject tombstoning a :pending row.
      assert {:ok, active} =
               ComposerArtifact.set_active(row, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, _tombstoned} =
               ComposerArtifact.tombstone_active(active, %{},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert {:ok, "the artifact value"} =
               ComposerArtifact.resolve_value(attrs.ref, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "a novel-atom term is normalized (atoms stringified) before encoding" do
      ctx = seed_lineage("artifact-atoms")
      attrs = pending_attrs(ctx, %{term: %{"nested" => [:a, 1, true], some_key: :some_value}})

      assert {:ok, _row} = store(ctx, attrs)

      assert {:ok, resolved} =
               ComposerArtifact.resolve_value(attrs.ref, tenant: ctx.tenant_id, actor: ctx.actor)

      # Atom key -> string, atom value -> inspect; true/numbers survive.
      assert resolved == %{"some_key" => ":some_value", "nested" => [":a", 1, true]}
    end

    test "the decrypted blob is ciphertext at rest, never plaintext" do
      ctx = seed_lineage("artifact-atrest")
      secret = "SUPER-SECRET-DIFF-#{System.unique_integer([:positive])}"
      attrs = pending_attrs(ctx, %{term: secret})

      assert {:ok, _row} = store(ctx, attrs)

      %{rows: [[raw]]} =
        JidoClaw.Repo.query!(
          "SELECT encrypted_value FROM composer_artifacts WHERE ref = $1",
          [attrs.ref]
        )

      assert is_binary(raw)
      refute raw =~ secret
    end
  end

  describe "cross-tenant + lineage guards" do
    test "a foreign-tenant parent_run_id is rejected" do
      a = seed_lineage("artifact-xt-parent-a")
      b = seed_lineage("artifact-xt-parent-b")

      # Artifact created in tenant B but pointing at tenant A's parent.
      assert {:error, %Ash.Error.Invalid{} = err} =
               ComposerArtifact.store_pending(
                 pending_attrs(b, %{parent_run_id: a.parent.id}),
                 tenant: b.tenant_id,
                 actor: b.actor
               )

      assert error_message?(err, "cross_tenant_fk_mismatch")
    end

    test "a foreign-tenant child_run_id is rejected" do
      a = seed_lineage("artifact-xt-child-a")
      b = seed_lineage("artifact-xt-child-b")

      assert {:error, %Ash.Error.Invalid{} = err} =
               ComposerArtifact.store_pending(
                 pending_attrs(b, %{child_run_id: a.child.id}),
                 tenant: b.tenant_id,
                 actor: b.actor
               )

      assert error_message?(err, "cross_tenant_fk_mismatch")
    end

    test "a child wave whose parent_run_id != the supplied parent is rejected (lineage)" do
      ctx = seed_lineage("artifact-lineage")

      # A second composer parent in the same tenant, with its own child wave.
      {:ok, other_parent} =
        WorkflowRun.create(%{name: "other-parent", workflow_type: "composer"},
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      {:ok, other_child} =
        WorkflowRun.create(
          %{name: "other-wave", workflow_type: "reactor", parent_run_id: other_parent.id},
          tenant: ctx.tenant_id,
          actor: ctx.actor
        )

      # Supply ctx.parent but other_parent's child — lineage mismatch.
      assert {:error, %Ash.Error.Invalid{} = err} =
               ComposerArtifact.store_pending(
                 pending_attrs(ctx, %{child_run_id: other_child.id}),
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert error_message?(err, "child_wave_parent_mismatch")
    end
  end

  describe "non-null contract" do
    # `:child_run_id` is NOT in this list (Phase 2d made it nullable for seed rows
    # — see the seed-row test below).
    for missing <- [:ref, :name, :producer, :wave_index, :parent_run_id] do
      test "store_pending rejects a missing #{missing}" do
        ctx = seed_lineage("artifact-required-#{unquote(missing)}")
        attrs = Map.delete(pending_attrs(ctx), unquote(missing))

        assert {:error, _} =
                 ComposerArtifact.store_pending(attrs, tenant: ctx.tenant_id, actor: ctx.actor)
      end
    end

    test "store_pending rejects an absent :term argument" do
      ctx = seed_lineage("artifact-no-term")
      attrs = Map.delete(pending_attrs(ctx), :term)

      assert {:error, %Ash.Error.Invalid{} = err} =
               ComposerArtifact.store_pending(attrs, tenant: ctx.tenant_id, actor: ctx.actor)

      assert error_message?(err, "term_required")
    end
  end

  describe "seed rows (Phase 2d)" do
    test "a seed row (child_run_id: nil, wave_index: -1, producer: seed) inserts :pending, " <>
           "is invisible to real-wave reads, and resolves" do
      ctx = seed_lineage("artifact-seed")

      attrs =
        pending_attrs(ctx, %{
          name: "request",
          producer: "seed",
          term: "Build the auth feature",
          child_run_id: nil,
          wave_index: -1
        })

      assert {:ok, row} =
               ComposerArtifact.store_pending(attrs, tenant: ctx.tenant_id, actor: ctx.actor)

      assert row.state == :pending
      assert is_nil(row.child_run_id)
      assert row.wave_index == -1

      # The sentinel -1 keeps it out of every real-wave (`N ≥ 0`) read: never
      # `:active` (so `active_for_run` excludes it), and `pending_for_wave(p, 0)`
      # filters on `wave_index == 0` (so it never sees the seed).
      assert {:ok, []} =
               ComposerArtifact.active_for_run(ctx.parent.id,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert {:ok, []} =
               ComposerArtifact.pending_for_wave(ctx.parent.id, 0,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      # Still resolvable state-agnostically (the wave boundary reads it by ref).
      assert {:ok, "Build the auth feature"} =
               ComposerArtifact.resolve_value(attrs.ref, tenant: ctx.tenant_id, actor: ctx.actor)
    end
  end

  describe "active-keyed partial-unique index" do
    test "allows many :pending / :tombstoned but at most one :active per {run, name, producer}" do
      ctx = seed_lineage("artifact-index")
      key = %{name: "plan", producer: "planner"}

      assert {:ok, first} = store(ctx, Map.merge(key, %{ref: ref()}))
      assert {:ok, second} = store(ctx, Map.merge(key, %{ref: ref()}))
      # Many pending with the same key coexist.
      assert {:ok, _third} = store(ctx, Map.merge(key, %{ref: ref()}))

      # Promote the first to :active — fine.
      assert {:ok, _} =
               ComposerArtifact.set_active(first, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      # A second :active for the same key violates the partial-unique index.
      assert {:error, _} =
               ComposerArtifact.set_active(second, %{}, tenant: ctx.tenant_id, actor: ctx.actor)
    end

    test "the partial index carries the WHERE state = 'active' clause in Postgres" do
      %{rows: [[indexdef]]} =
        JidoClaw.Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'composer_artifacts_active_ref_index'"
        )

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "state = 'active'"
    end
  end

  describe "single-transition guards (P3)" do
    test "tombstone_active on a :pending row is rejected" do
      ctx = seed_lineage("artifact-guard-tombstone")
      assert {:ok, pending} = store(ctx, pending_attrs(ctx))
      assert pending.state == :pending

      assert {:error, _} =
               ComposerArtifact.tombstone_active(pending, %{},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )
    end

    test "set_active on a :tombstoned row is rejected" do
      ctx = seed_lineage("artifact-guard-activate")
      assert {:ok, pending} = store(ctx, pending_attrs(ctx))

      assert {:ok, active} =
               ComposerArtifact.set_active(pending, %{}, tenant: ctx.tenant_id, actor: ctx.actor)

      assert {:ok, tombstoned} =
               ComposerArtifact.tombstone_active(active, %{},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert {:error, _} =
               ComposerArtifact.set_active(tombstoned, %{},
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )
    end
  end

  describe "activate_for_wave (the guards compose with promote_one/3)" do
    test "promotes a wave's :pending rows to :active" do
      ctx = seed_lineage("artifact-activate-wave")

      assert {:ok, a} =
               store(ctx, %{ref: ref(), name: "plan", producer: "planner", wave_index: 0})

      assert {:ok, b} = store(ctx, %{ref: ref(), name: "diff", producer: "coder", wave_index: 0})

      assert {:ok, 2} =
               ComposerArtifact.activate_for_wave(ctx.parent.id, 0,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      for row <- [a, b] do
        assert {:ok, reloaded} =
                 ComposerArtifact.resolve_ref(row.ref, tenant: ctx.tenant_id, actor: ctx.actor)

        assert reloaded.state == :active
      end
    end

    test "a superseding :pending tombstones the prior :active for the same {name, producer}" do
      ctx = seed_lineage("artifact-activate-supersede")
      key = %{name: "plan", producer: "planner"}

      # Wave 0: one pending → activate.
      assert {:ok, first} = store(ctx, Map.merge(key, %{ref: ref(), wave_index: 0}))

      assert {:ok, 1} =
               ComposerArtifact.activate_for_wave(ctx.parent.id, 0,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      # Wave 1: a superseding pending for the same key → activate tombstones the
      # old active first (active→tombstoned), then promotes the new (pending→active),
      # so the partial-unique index is never violated mid-promotion.
      assert {:ok, second} = store(ctx, Map.merge(key, %{ref: ref(), wave_index: 1}))

      assert {:ok, 1} =
               ComposerArtifact.activate_for_wave(ctx.parent.id, 1,
                 tenant: ctx.tenant_id,
                 actor: ctx.actor
               )

      assert {:ok, old} =
               ComposerArtifact.resolve_ref(first.ref, tenant: ctx.tenant_id, actor: ctx.actor)

      assert old.state == :tombstoned

      assert {:ok, new} =
               ComposerArtifact.resolve_ref(second.ref, tenant: ctx.tenant_id, actor: ctx.actor)

      assert new.state == :active
    end
  end

  describe "Envelope" do
    test "encode/decode round-trips and rejects a corrupt/wrong-version blob" do
      assert Envelope.decode(Envelope.encode("x")) == {:ok, "x"}
      assert Envelope.decode(Envelope.encode(nil)) == {:ok, nil}
      assert Envelope.decode(<<0, 1, 2, 3>>) == {:error, :corrupt_artifact}
      assert Envelope.decode(:erlang.term_to_binary({99, "x"})) == {:error, :corrupt_artifact}
      assert Envelope.decode(:not_a_binary) == {:error, :not_a_binary}
    end
  end

  defp error_message?(%Ash.Error.Invalid{errors: errors}, fragment) do
    Enum.any?(errors, fn err ->
      msg = if is_exception(err), do: Exception.message(err), else: inspect(err)
      msg =~ fragment
    end)
  end
end
