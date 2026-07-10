defmodule JidoClaw.RouteComposer.EvidenceFloorTest do
  @moduledoc """
  Item 10 (OB1-3) — the evidence floor end-to-end through the real composer
  (stub workers, stubbed `Evidence.reader()` seam, scripted `VerifyStub`
  porcelain — no LLM, no real git): breach → engine findings on Hook R →
  fixer re-fire → clean re-check → converge; plus the vendor-arm/redaction
  skips, the multi-producer aggregate, the cap-suppression temp-fold proof,
  the `{:fix_failed, ["evidence"]}` terminal, and the projection recovery
  equivalence.

  Non-async (`TenantCase`): mutates global app env + runs async Reactor steps
  under a shared sandbox.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Projection, as: ComposerProjection
  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer
  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.RouteComposer.TestSupport.StubWorker

  defmodule StubReader do
    @moduledoc """
    The `Evidence.reader()` seam stub: returns canned transcript rows from
    `:evidence_stub_rows_sequence` (one entry per gather, consumed in call
    order, last entry sticky) — the runtime-minted request_id is why a raw
    row-seed would race.
    """
    alias JidoClaw.RouteComposer.TestSupport.StubStore

    @spec tool_rows(String.t(), String.t(), keyword()) :: {:ok, [map()]}
    def tool_rows(_session_id, _request_id, _opts) do
      sequence = Application.get_env(:jido_claw, :evidence_stub_rows_sequence, [[]])
      n = StubStore.bump(:evidence_reads)
      {:ok, Enum.at(sequence, min(n, length(sequence)) - 1)}
    end
  end

  setup do
    StubStore.setup()
    previous_server = Application.get_env(:jido_claw, :step_agent_server)
    previous_evidence = Application.get_env(:jido_claw, :evidence)

    Application.put_env(
      :jido_claw,
      :agent_templates_override,
      TestFixtures.phase1_template_override(StubWorker)
    )

    Application.put_env(:jido_claw, :step_agent_server, StubAgentServer)
    Application.put_env(:jido_claw, :evidence, reader: StubReader)

    on_exit(fn ->
      Application.delete_env(:jido_claw, :agent_templates_override)
      Application.delete_env(:jido_claw, :route_composer_stub_outputs)
      Application.delete_env(:jido_claw, :evidence_stub_rows_sequence)
      Application.delete_env(:jido_claw, :route_composer_verify_stub)

      case previous_evidence do
        nil -> Application.delete_env(:jido_claw, :evidence)
        env -> Application.put_env(:jido_claw, :evidence, env)
      end

      case previous_server do
        nil -> Application.delete_env(:jido_claw, :step_agent_server)
        mod -> Application.put_env(:jido_claw, :step_agent_server, mod)
      end
    end)

    %{tenant_id: tenant, workspace: workspace, session: session} =
      seed_full(tenant_label: "evidence")

    context = %{
      tenant_id: tenant,
      session_id: "evidence-sess",
      session_uuid: session.id,
      workspace_id: "evidence-ws",
      workspace_uuid: workspace.id,
      project_dir: File.cwd!()
    }

    {:ok, tenant: tenant, context: context}
  end

  # ---------------------------------------------------------------------------
  # Canned rows / outputs
  # ---------------------------------------------------------------------------

  defp call_row(command) do
    %{
      "role" => "tool_call",
      "tool_call_id" => "c1",
      "metadata" => %{"tool_name" => "run_command", "arguments" => %{"command" => command}}
    }
  end

  defp result_row(exit_code) do
    %{
      "role" => "tool_result",
      "tool_call_id" => "c1",
      "metadata" => %{
        "tool_name" => "run_command",
        "result" => %{"status" => "ok", "value" => %{"exit_code" => exit_code}}
      }
    }
  end

  defp red_rows, do: [call_row("mix test"), result_row(1)]
  defp green_rows, do: [call_row("mix test"), result_row(0)]

  defp redacted_rows do
    [%{"role" => "tool_call", "tool_call_id" => "c1", "metadata" => %{"redacted" => true}}]
  end

  # Coder/fixer outputs carrying a tests_passed claim. `files_changed` is
  # deliberately absent so only the transcript kinds classify (the VerifyStub
  # porcelain default diffs empty and would flip a files claim).
  defp claiming_outputs do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: build it"},
      "coder" => %{
        "signals" => ["code-written"],
        "diff" => "DIFF: +ok",
        "evidence" => %{"tests_passed" => ["mix test"]}
      },
      "reviewer" => TestFixtures.phase1_clean_reviewer(),
      "fixer" => %{
        "signals" => ["code-written"],
        "fix" => "FIX: reran the tests honestly",
        "evidence" => %{"tests_passed" => ["mix test"]}
      }
    }
  end

  defp run(ctx, opts \\ []) do
    base = [
      catalog: TestFixtures.self_heal_fixture_catalog(),
      live: TestFixtures.self_heal_seed_live(),
      artifacts: TestFixtures.self_heal_seed_artifacts(),
      tenant: ctx.tenant,
      actor: actor_for(ctx.tenant),
      context: ctx.context,
      max_waves: Keyword.get(opts, :max_waves, 20),
      timeout: 30_000
    ]

    RouteComposer.run_sync(
      Keyword.merge(base, Keyword.take(opts, [:rerun_cap, :infra_cap, :catalog]))
    )
  end

  defp recovery_evidence_catalog do
    %{
      "implementer" =>
        TestFixtures.stage(
          name: "implementer",
          unit: {:worker_template, "coder"},
          task: "Implement the request; emit code-written.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"]
        )
    }
  end

  # ---------------------------------------------------------------------------
  # Breach → re-fire → clean re-check → converge
  # ---------------------------------------------------------------------------

  describe "breach → fixer re-fire → clean re-check → converge" do
    test "a fabricated tests_passed claim flags, feeds the fixer, clears on the honest redo",
         ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      # Read 1 (the coder wave): red rows — the claim is a false green. Every
      # later read (the fixer wave): green rows — the redo is honest.
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows(), green_rows()])

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # The clearing re-check: clean:evidence live, findings:evidence retracted.
      assert MapSet.member?(summary.final_live, "clean:evidence")
      refute MapSet.member?(summary.final_live, "findings:evidence")

      # The fixer was summoned by the live findings:evidence and ran.
      assert MapSet.member?(summary.ran, "fixer")

      # The RECORD welded durably: the aggregated artifacts under producer
      # "evidence" (findings + action_needed + evidence-report)…
      produced = produced_artifact_pairs(summary.parent_run_id, ctx)
      assert {"findings", "evidence"} in produced
      assert {"action_needed", "evidence"} in produced
      assert {"evidence-report", "evidence"} in produced

      # …the fixer feed (Hook R by shape — the temp fold resolved the fresh
      # artifact refs into the producerless feedback inputs)…
      assert {"review-feedback", "evidence"} in produced
      assert {"review-action", "evidence"} in produced

      # …the explicit signal pair on BOTH flips (welded markers only union,
      # so the retractions must be explicit)…
      assert ["findings:evidence"] in published_signal_sets(summary.parent_run_id, ctx)
      assert ["clean:evidence"] in published_signal_sets(summary.parent_run_id, ctx)
      assert ["findings:evidence"] in retracted_signal_sets(summary.parent_run_id, ctx)

      # …and the evidence finding rounds: the breach round's stage-scoped key,
      # then the clearing round's explicit empty keys (the round must advance).
      assert [breach_round, clear_round] =
               summary.parent_run_id
               |> finding_key_events(ctx, "evidence")
               |> Enum.map(& &1.payload["keys"])

      assert [key] = breach_round
      assert key =~ ~r/^[0-9a-f]{64}$/
      assert clear_round == []

      # The breach ledger: two evidence_classified events — breach true
      # (the implementer's fabrication, per-stage attribution), then false.
      assert [first, second] = evidence_classified_events(summary.parent_run_id, ctx)

      assert [%{"stage" => "implementer", "breach" => true} = entry] =
               first.payload["classifications"]

      assert entry["statuses"]["tests_passed"]["unsupported"] == 1
      assert is_binary(entry["request_id"])
      assert [%{"stage" => "fixer", "breach" => false}] = second.payload["classifications"]

      # Byte-shape pin (review P2): an AC-less run's ledger events carry NO
      # `ac` section — existing events stay byte-identical.
      refute Map.has_key?(first.payload, "ac")

      # Breach count projected into the durable terminal result.
      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :completed
      assert parent.result["evidence_breaches"] == %{"implementer" => 1}
      assert summary.evidence_breaches == %{"implementer" => 1}
    end

    test "the evidence-report rides the next review wave's context", ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows(), green_rows()])
      Application.put_env(:jido_claw, :route_composer_capture_task, self())

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # A reviewer task assembled AFTER the breach carries the rendered
      # evidence-report block (the optional producerless input).
      assert_receive {:wave_task, "reviewer", task}, 5_000
      reviewer_tasks = [task | drain_reviewer_tasks()]

      assert Enum.any?(reviewer_tasks, &(&1 =~ "evidence-report")),
             "expected an evidence-report block in a review wave's context"

      assert Enum.any?(reviewer_tasks, &(&1 =~ "engine-verified")),
             "expected the per-stage evidence diagnosis text in a review task"
    after
      Application.delete_env(:jido_claw, :route_composer_capture_task)
    end
  end

  # ---------------------------------------------------------------------------
  # Unfixable fabrication → stall → {:fix_failed, ["evidence"]}
  # ---------------------------------------------------------------------------

  describe "unfixable fabrication" do
    test "always-red rows stall the evidence key and terminalize fix_failed(evidence)", ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      # Every read red: the coder fabricates, the fixer keeps fabricating.
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows()])

      assert {:ok, summary} = run(ctx, rerun_cap: 5, max_waves: 30)
      assert summary.terminal == :fix_failed
      assert summary.reason == ["evidence"]

      ks = kinds(summary.parent_run_id, ctx)
      assert :route_fix_failed in ks
      refute :route_budget_exhausted in ks
      refute :route_converged in ks

      parent = reload(summary.parent_run_id, ctx)
      assert parent.status == :failed
      assert parent.result["disposition"] == "fix_failed"
      assert String.starts_with?(parent.error, "fix_failed: lenses=evidence")

      # The breach facts stand: findings:evidence still live at the terminal,
      # and the in-memory ledger attributes both fabricating stages (the
      # failure-terminal payload carries disposition + error, not the
      # converged-path summary subset — the durable authority for counts is
      # the evidence_classified event stream).
      assert MapSet.member?(summary.final_live, "findings:evidence")
      assert summary.evidence_breaches["implementer"] == 1
      assert summary.evidence_breaches["fixer"] >= 1

      breached_stages =
        summary.parent_run_id
        |> evidence_classified_events(ctx)
        |> Enum.flat_map(& &1.payload["classifications"])
        |> Enum.filter(& &1["breach"])
        |> Enum.map(& &1["stage"])

      assert "implementer" in breached_stages
      assert "fixer" in breached_stages
    end
  end

  # ---------------------------------------------------------------------------
  # Cap suppression (the temp-fold proof)
  # ---------------------------------------------------------------------------

  describe "re-review budget suppression" do
    test "a FIRST breach with the fixer rerun-capped suppresses the re-fire via the temp fold",
         ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows()])

      # rerun_cap 0: the fixer's budget is exhausted from wave one, so the
      # FIRST breach must already suppress — which requires findings:evidence
      # to be visible in the SAME wave's suppression fold (the temp-fold
      # device; on state.live alone the first re-fire would slip through).
      assert {:ok, summary} = run(ctx, rerun_cap: 0, max_waves: 30)
      assert summary.terminal == :fix_failed
      assert "evidence" in summary.reason

      # The record welded (breach facts stand)…
      produced = produced_artifact_pairs(summary.parent_run_id, ctx)
      assert {"findings", "evidence"} in produced

      # …but NO fixer feed and NO fixer invalidation ever welded (the re-fire
      # half stayed suppressed on every breach).
      refute {"review-feedback", "evidence"} in produced

      fixer_invalidations =
        summary.parent_run_id
        |> events(ctx, :stages_invalidated)
        |> Enum.filter(fn e -> "fixer" in (e.payload["stages"] || []) end)

      assert fixer_invalidations == []
    end
  end

  # ---------------------------------------------------------------------------
  # The vendor-arm / redaction skips
  # ---------------------------------------------------------------------------

  describe "skip taxonomy" do
    test "a second edit to an already-dirty path is proved by changed fingerprints", ctx do
      outputs =
        put_in(claiming_outputs(), ["coder"], %{
          "signals" => ["code-written"],
          "diff" => "DIFF: repeat edit",
          "files_changed" => ["lib/dirty.ex"]
        })

      Application.put_env(:jido_claw, :route_composer_stub_outputs, outputs)
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [[]])

      # Porcelain's XY row stays byte-identical across a real second edit.
      # The signed amendment adds bounded content proof without changing the
      # status-diff or containment semantics.
      Application.put_env(:jido_claw, :route_composer_verify_stub, %{
        porcelain_all: [" M lib/dirty.ex\n", " M lib/dirty.ex\n"],
        path_fingerprints: [
          %{"lib/dirty.ex" => "before-fingerprint"},
          %{"lib/dirty.ex" => "after-fingerprint"}
        ]
      })

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged
      refute MapSet.member?(summary.final_live, "findings:evidence")
      refute :evidence_classified in kinds(summary.parent_run_id, ctx)

      assert {:ok, 2} = StubStore.fetch(:verify_stub_path_fingerprints_calls)
    end

    test "zero tool rows: transcript kinds skip; files still reconcile (and can breach)", ctx do
      outputs =
        put_in(claiming_outputs(), ["coder"], %{
          "signals" => ["code-written"],
          "diff" => "DIFF: +ok",
          # A files claim over a path the wave diff does NOT contain — the
          # files kind must reconcile (and flag) even with no transcript.
          "files_changed" => ["lib/untouched.ex"],
          "evidence" => %{"tests_passed" => ["mix test"]}
        })

      Application.put_env(:jido_claw, :route_composer_stub_outputs, outputs)
      # The vendor arm: no tool rows at all.
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [[]])
      # Scripted wave snapshots: clean before, one unrelated change after.
      Application.put_env(:jido_claw, :route_composer_verify_stub, %{
        porcelain_all: ["", "?? lib/other.ex\n"]
      })

      assert {:ok, summary} = run(ctx, rerun_cap: 5, max_waves: 30)

      # The files kind produced the breach; the tests kind skipped (never a
      # finding from a skip).
      assert [first | _rest] = evidence_classified_events(summary.parent_run_id, ctx)
      assert [entry] = first.payload["classifications"]
      assert entry["breach"] == true
      assert entry["statuses"]["files_touched"]["unsupported"] == 1
      assert entry["statuses"]["tests_passed"]["skipped"] == 1
      assert entry["counts"]["unsupported"] == 1
    end

    test "redacted rows skip :redacted — degraded, never suspicious", ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [redacted_rows()])

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      # No breach, no evidence signals, no ledger events — trust.
      refute MapSet.member?(summary.final_live, "findings:evidence")
      refute :evidence_classified in kinds(summary.parent_run_id, ctx)
      refute Map.has_key?(reload(summary.parent_run_id, ctx).result, "evidence_breaches")
    end

    test "a never-flagged clean run welds no evidence markers at all", ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [green_rows()])

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      ks = kinds(summary.parent_run_id, ctx)
      refute :evidence_classified in ks
      refute MapSet.member?(summary.final_live, "findings:evidence")
      refute MapSet.member?(summary.final_live, "clean:evidence")

      assert Enum.all?(
               produced_artifact_pairs(summary.parent_run_id, ctx),
               fn {_name, producer} -> producer != "evidence" end
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-producer aggregation
  # ---------------------------------------------------------------------------

  describe "multi-producer wave" do
    test "two breaching producers in one wave aggregate into ONE artifact set + ONE round",
         ctx do
      # A second coder stage in the implementer's Kahn level: both consume
      # `plan`, both trigger on plan-ready.
      sibling =
        TestFixtures.stage(
          name: "test-author",
          unit: {:worker_template, "coder"},
          task: "Author the tests; emit code-written.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["tests"],
          pub: ["code-written", "scope-shift"]
        )

      catalog = Map.put(TestFixtures.self_heal_fixture_catalog(), "test-author", sibling)

      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows()])

      assert {:ok, summary} = run(ctx, catalog: catalog, rerun_cap: 5, max_waves: 30)

      # ONE ledger event for the producer wave, BOTH stages attributed.
      assert [first | _rest] = evidence_classified_events(summary.parent_run_id, ctx)

      assert first.payload["classifications"]
             |> Enum.map(& &1["stage"])
             |> Enum.sort() == ["implementer", "test-author"]

      # ONE evidence finding_keys marker for that wave, keys = the union
      # (stage-scoped locations ⇒ two distinct keys — same-wave stages must
      # not collapse into one identity).
      [first_round | _rest] = finding_key_events(summary.parent_run_id, ctx, "evidence")
      assert [_key_a, _key_b] = first_round.payload["keys"]

      # ONE aggregated artifact set under producer "evidence" for that wave:
      # the first wave's triples carry exactly one findings ref.
      produced = produced_artifact_pairs(summary.parent_run_id, ctx)
      assert {"findings", "evidence"} in produced
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery equivalence
  # ---------------------------------------------------------------------------

  describe "projection recovery" do
    test "a recovered open wave keeps its lost baseline nil on a completed-child rebind",
         ctx do
      actor = actor_for(ctx.tenant)

      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [[]])

      Application.put_env(:jido_claw, :route_composer_verify_stub, %{
        porcelain_all: [" M lib/dirty.ex\n"],
        path_fingerprints: [%{"lib/dirty.ex" => "post-edit-fingerprint"}]
      })

      {:ok, parent} =
        RouteComposer.create_parent_run(
          catalog: recovery_evidence_catalog(),
          live: ["request-received", "code"],
          artifacts: %{"request" => %{"seed" => "finish the edit"}},
          tenant: ctx.tenant,
          actor: actor,
          context: ctx.context,
          max_waves: 5
        )

      {:ok, _started} =
        WorkflowLog.append(parent, :wave_started, %{wave_index: 0, stages: ["implementer"]},
          tenant: ctx.tenant,
          actor: actor
        )

      durable_ctx = %{tenant: ctx.tenant, actor: actor}
      child = TestFixtures.craft_child(parent, durable_ctx, 0, :running)

      {:ok, diff_ref} =
        ComposerArtifact.store_wave_artifact(
          "diff",
          "implementer",
          "DIFF: recovered real edit",
          child,
          0,
          tenant: ctx.tenant,
          actor: actor
        )

      envelope = %{
        "wave_index" => 0,
        "emissions" => [
          %{
            "stage" => "implementer",
            "signals" => ["code-written"],
            "artifacts" => %{"diff" => diff_ref},
            "request_id" => "recovered-request",
            "evidence" => %{"files_touched" => ["lib/dirty.ex"]}
          }
        ]
      }

      {:ok, _completed} =
        WorkflowLog.append(child, :run_completed, %{result: envelope},
          tenant: ctx.tenant,
          actor: actor
        )

      recovered_parent = reload(parent.id, ctx)

      {:ok, pid} =
        RouteComposer.ensure_started([tenant: ctx.tenant, actor: actor], recovered_parent)

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
      assert reload(parent.id, ctx).status == :completed

      # The original dispatch-time baseline was process-local and is gone.
      # Recovery must skip the files kind instead of capturing post-edit state
      # as a fake "before" and accusing the completed child of fabrication.
      refute :evidence_classified in kinds(parent.id, ctx)
      refute Enum.any?(published_signal_sets(parent.id, ctx), &(&1 == ["findings:evidence"]))

      assert {:ok, 1} = StubStore.fetch(:verify_stub_porcelain_all_calls)
      assert {:ok, 1} = StubStore.fetch(:verify_stub_path_fingerprints_calls)
    end

    test "projecting the durable log rebuilds the breach ledger and the evidence signals",
         ctx do
      Application.put_env(:jido_claw, :route_composer_stub_outputs, claiming_outputs())
      Application.put_env(:jido_claw, :evidence_stub_rows_sequence, [red_rows(), green_rows()])

      assert {:ok, summary} = run(ctx)
      assert summary.terminal == :converged

      seed = %{
        live: MapSet.new(TestFixtures.self_heal_seed_live()),
        artifacts: TestFixtures.self_heal_seed_artifacts(),
        ran: MapSet.new(),
        premises: %{},
        prev_route: [],
        wave_index: 0
      }

      projected = ComposerProjection.project(seed, all_events(summary.parent_run_id, ctx))

      # The rebuilt fold agrees with the in-memory terminal state on every
      # evidence-owned fact: the breach ledger, the signal flip, the rounds.
      assert projected.evidence_breaches == %{"implementer" => 1}
      assert MapSet.member?(projected.live, "clean:evidence")
      refute MapSet.member?(projected.live, "findings:evidence")
      assert projected.finding_rounds["evidence"].round == 2
      assert projected.live == summary.final_live
    end
  end

  # --- helpers ---

  defp all_events(parent_id, ctx) do
    {:ok, events} =
      WorkflowEvent.for_run(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))

    events
  end

  defp kinds(parent_id, ctx), do: Enum.map(all_events(parent_id, ctx), & &1.kind)

  defp events(parent_id, ctx, kind),
    do: Enum.filter(all_events(parent_id, ctx), &(&1.kind == kind))

  defp evidence_classified_events(parent_id, ctx) do
    parent_id
    |> events(ctx, :evidence_classified)
    |> Enum.sort_by(& &1.seq)
  end

  defp finding_key_events(parent_id, ctx, lens) do
    parent_id
    |> events(ctx, :finding_keys)
    |> Enum.filter(&(&1.payload["lens"] == lens))
    |> Enum.sort_by(& &1.seq)
  end

  # Every {name, producer} pair any artifacts_produced event carried.
  defp produced_artifact_pairs(parent_id, ctx) do
    parent_id
    |> events(ctx, :artifacts_produced)
    |> Enum.flat_map(fn e -> e.payload["artifacts"] || [] end)
    |> Enum.map(fn a -> {a["name"], a["producer"]} end)
    |> MapSet.new()
  end

  defp published_signal_sets(parent_id, ctx) do
    parent_id
    |> events(ctx, :signals_published)
    |> Enum.map(fn e -> Enum.sort(e.payload["signals"] || []) end)
  end

  defp retracted_signal_sets(parent_id, ctx) do
    parent_id
    |> events(ctx, :signals_retracted)
    |> Enum.map(fn e -> Enum.sort(e.payload["signals"] || []) end)
  end

  defp drain_reviewer_tasks(acc \\ []) do
    receive do
      {:wave_task, "reviewer", task} -> drain_reviewer_tasks([task | acc])
      {:wave_task, _template, _task} -> drain_reviewer_tasks(acc)
    after
      0 -> acc
    end
  end

  defp reload(parent_id, ctx) do
    {:ok, parent} = WorkflowRun.by_id(parent_id, tenant: ctx.tenant, actor: actor_for(ctx.tenant))
    parent
  end
end
