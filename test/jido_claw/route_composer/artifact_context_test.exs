defmodule JidoClaw.RouteComposer.ArtifactContextTest do
  @moduledoc """
  AR-2 Phase 2b — `ArtifactContext.build/4` now resolves + decrypts each
  `ComposerArtifact` ref from the provenance store, and returns
  `{:ok, text} | {:error, reason}`: a missing ref, a wrong-tenant ref, or a
  decrypt/corrupt failure is a controlled wave failure (P1-2), never a crash
  or a silently-omitted artifact.

  Non-async (`TenantCase`): persists + (for the corrupt case) raw-mutates rows.
  """
  use JidoClaw.TenantCase, async: false

  import Ecto.Query

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.ArtifactContext
  alias JidoClaw.RouteComposer.TestFixtures

  setup do
    tenant_id = seed_tenant("artifact-context")
    actor = actor_for(tenant_id)

    {:ok, parent} =
      WorkflowRun.create(%{name: "p", workflow_type: "composer"}, tenant: tenant_id, actor: actor)

    {:ok, child} =
      WorkflowRun.create(%{name: "w0", workflow_type: "reactor", parent_run_id: parent.id},
        tenant: tenant_id,
        actor: actor
      )

    %{tenant_id: tenant_id, actor: actor, parent: parent, child: child}
  end

  # Store an artifact value and return its TAGGED ref `{:ref, art_<hex>}` (P2 —
  # the shape `Fold` writes into the provenance store), for assembling the store.
  defp store_ref(ctx, name, producer, value) do
    {:ok, row} =
      ComposerArtifact.store_pending(
        %{
          ref: JidoClaw.Refs.mint("art_"),
          name: name,
          producer: producer,
          term: value,
          child_run_id: ctx.child.id,
          parent_run_id: ctx.parent.id,
          wave_index: 0
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    {:ref, row.ref}
  end

  defp build(ctx, stages, store),
    do: ArtifactContext.build(stages, store, ctx.tenant_id, ctx.actor)

  test "resolves required + optional names across producers, skipping unreferenced", ctx do
    stages = [TestFixtures.stage(name: "implementer", req: ["plan"], opt: ["approved-plan"])]

    store = %{
      "plan" => %{"planner" => store_ref(ctx, "plan", "planner", "PLAN")},
      "approved-plan" => %{"approver" => store_ref(ctx, "approved-plan", "approver", "APPROVED")},
      "diff" => %{"implementer" => store_ref(ctx, "diff", "implementer", "D")}
    }

    assert {:ok, text} = build(ctx, stages, store)
    assert text =~ "### plan"
    assert text =~ "planner"
    assert text =~ "PLAN"
    assert text =~ "### approved-plan"
    assert text =~ "APPROVED"
    refute text =~ "### diff"
  end

  test "omits a missing optional input", ctx do
    stages = [TestFixtures.stage(name: "implementer", req: ["plan"], opt: ["approved-plan"])]
    store = %{"plan" => %{"planner" => store_ref(ctx, "plan", "planner", "PLAN")}}

    assert {:ok, text} = build(ctx, stages, store)
    assert text =~ "### plan"
    refute text =~ "approved-plan"
  end

  test "renders every producer of a co-produced name", ctx do
    stages = [TestFixtures.stage(name: "fixer", req: ["findings"])]

    store = %{
      "findings" => %{
        "quality-reviewer" => store_ref(ctx, "findings", "quality-reviewer", "Q"),
        "security-reviewer" => store_ref(ctx, "findings", "security-reviewer", "S")
      }
    }

    assert {:ok, text} = build(ctx, stages, store)
    assert text =~ "quality-reviewer"
    assert text =~ "security-reviewer"
  end

  test "returns {:ok, \"\"} when nothing wanted is present", ctx do
    stages = [TestFixtures.stage(name: "planner", req: ["request"])]
    assert {:ok, ""} = build(ctx, stages, %{})
  end

  describe "error contract (P1-2 → controlled wave failure)" do
    test "a missing ref returns {:error, _}", ctx do
      stages = [TestFixtures.stage(name: "implementer", req: ["plan"])]
      store = %{"plan" => %{"planner" => {:ref, "art_deadbeefdead"}}}

      assert {:error, {:artifact_resolve_failed, {:ref, "art_deadbeefdead"}, _}} =
               build(ctx, stages, store)
    end

    test "a wrong-tenant ref returns {:error, _}", ctx do
      stages = [TestFixtures.stage(name: "implementer", req: ["plan"])]
      ref = store_ref(ctx, "plan", "planner", "PLAN")

      other = seed_tenant("artifact-context-other")
      store = %{"plan" => %{"planner" => ref}}

      assert {:error, {:artifact_resolve_failed, ^ref, _}} =
               ArtifactContext.build(stages, store, other, actor_for(other))
    end

    test "a corrupt/undecryptable value returns {:error, _}", ctx do
      stages = [TestFixtures.stage(name: "implementer", req: ["plan"])]
      {:ref, raw_ref} = ref = store_ref(ctx, "plan", "planner", "PLAN")

      # Clobber the ciphertext so decrypt raises (or decodes to a non-envelope).
      {1, _} =
        JidoClaw.Repo.update_all(
          from(a in "composer_artifacts",
            where: a.ref == ^raw_ref and a.tenant_id == ^ctx.tenant_id
          ),
          set: [encrypted_value: <<0, 1, 2, 3, 4>>]
        )

      store = %{"plan" => %{"planner" => ref}}
      assert {:error, {:artifact_resolve_failed, ^ref, _}} = build(ctx, stages, store)
    end
  end

  test "resolves + decrypts a folded seed ref (child_run_id: nil, wave_index: -1, Phase 2d)",
       ctx do
    # A genesis-folded seed is a real ref-stored row (child_run_id: nil, producer:
    # "seed", wave_index: -1) tagged `{:ref, ref}` in the store — build/4 must
    # resolve+decrypt it like any wave-produced artifact, not just resolve_value/2
    # in isolation.
    stages = [TestFixtures.stage(name: "planner", req: ["request"])]

    {:ok, row} =
      ComposerArtifact.store_pending(
        %{
          ref: JidoClaw.Refs.mint("art_"),
          name: "request",
          producer: "seed",
          term: "Build the auth feature",
          child_run_id: nil,
          parent_run_id: ctx.parent.id,
          wave_index: -1
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    store = %{"request" => %{"seed" => {:ref, row.ref}}}

    assert {:ok, text} = build(ctx, stages, store)
    assert text =~ "### request"
    assert text =~ "Build the auth feature"
  end

  test "a bare seed value that looks like a ref is used inline, never resolved (P2)", ctx do
    stages = [TestFixtures.stage(name: "implementer", req: ["plan"])]

    # Seed values (no `{:ref, _}` tag) that merely *look* like `art_<hex>` — the
    # old regex heuristic misread these as refs and failed the wave. Now an
    # untagged term is always an inline seed: rendered verbatim, never resolved.
    store = %{
      "plan" => %{
        "planner" => %{"request" => %{"user" => "art_deadbeef"}},
        "seeder" => "art_deadbeefdead"
      }
    }

    assert {:ok, text} = build(ctx, stages, store)
    assert text =~ "art_deadbeef"
    assert text =~ "art_deadbeefdead"
  end
end
