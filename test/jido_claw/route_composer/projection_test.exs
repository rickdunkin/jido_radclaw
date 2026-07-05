defmodule JidoClaw.RouteComposer.ProjectionTest do
  @moduledoc """
  AR-2 Phase 2c — `RouteComposer.Projection.project/2` folds the durable composer
  delta log back onto the seed. Synthetic logs cover every folded kind; the
  equivalence test proves `project(seed, durable deltas)` reproduces the in-memory
  `Fold` result for a multi-wave run — including a paired-verdict flip that
  retracts a live signal (round-tripping via `signals_retracted`).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.Fold
  alias JidoClaw.RouteComposer.Projection
  alias JidoClaw.RouteComposer.StageEmission

  defp seed(overrides \\ %{}) do
    Map.merge(
      %{
        live: MapSet.new(["request-received", "code"]),
        artifacts: %{"request" => %{"seed" => "R"}},
        ran: MapSet.new(),
        premises: %{},
        prev_route: [],
        wave_index: 0
      },
      overrides
    )
  end

  defp event(kind, payload, seq), do: %{kind: kind, payload: payload, seq: seq}

  describe "fresh / no-op folds" do
    test "project(seed, [run_started]) == seed (a fresh run projects unchanged)" do
      s = seed()
      assert Projection.project(s, [event(:run_started, %{}, 1)]) == s
    end

    test "genesis + unknown + gate-lifecycle kinds are no-ops" do
      s = seed()

      events = [
        event(:run_started, %{}, 1),
        event(:wave_paused, %{wave_index: 0}, 2),
        event(:wave_resumed, %{wave_index: 0}, 3),
        event(:run_recovered, %{}, 4)
      ]

      assert Projection.project(s, events) == s
    end

    test "events are folded in seq order regardless of list order" do
      s = seed()

      out_of_order = [
        event(:signals_published, %{signals: ["b"]}, 2),
        event(:signals_retracted, %{signals: ["b"]}, 3),
        event(:signals_published, %{signals: ["a"]}, 1)
      ]

      # seq 1 publishes a, seq 2 publishes b, seq 3 retracts b → only a remains.
      result = Projection.project(s, out_of_order)
      assert MapSet.member?(result.live, "a")
      refute MapSet.member?(result.live, "b")
    end
  end

  describe "additive folds" do
    test "wave_completed unions stages into ran and advances wave_index" do
      result =
        Projection.project(seed(), [
          event(:wave_completed, %{wave_index: 0, stages: ["planner"]}, 1),
          event(:wave_completed, %{wave_index: 1, stages: ["approver", "implementer"]}, 2)
        ])

      assert MapSet.equal?(result.ran, MapSet.new(["planner", "approver", "implementer"]))
      assert result.wave_index == 2
    end

    test "wave_index advances to max(_, idx + 1) — idempotent under a re-dispatch" do
      result =
        Projection.project(seed(), [
          event(:wave_completed, %{wave_index: 0, stages: ["a"]}, 1),
          event(:wave_completed, %{wave_index: 0, stages: ["a"]}, 2)
        ])

      assert result.wave_index == 1
    end

    test "signals_published unions into live" do
      result =
        Projection.project(seed(), [
          event(:signals_published, %{signals: ["plan-ready", "auth-surface"]}, 1)
        ])

      assert MapSet.member?(result.live, "plan-ready")
      assert MapSet.member?(result.live, "auth-surface")
    end

    test "artifacts_produced indexes the tagged ref into the store (matching Fold)" do
      result =
        Projection.project(seed(), [
          event(
            :artifacts_produced,
            %{artifacts: [%{name: "plan", producer: "planner", ref: "art_p"}]},
            1
          )
        ])

      assert result.artifacts["plan"] == %{"planner" => {:ref, "art_p"}}
      # seed artifact untouched.
      assert result.artifacts["request"] == %{"seed" => "R"}
    end

    test "route_composed sets premises (latest-wins) and prev_route (snapshot route)" do
      result =
        Projection.project(seed(), [
          event(:route_composed, %{route: ["planner"], premises: %{"k" => "v1"}}, 1),
          event(:route_composed, %{route: ["approver"], premises: %{"k" => "v2"}}, 2)
        ])

      assert result.prev_route == ["approver"]
      assert result.premises == %{"k" => "v2"}
    end

    test "string-keyed (JSONB-reloaded) payloads fold identically to atom-keyed" do
      result =
        Projection.project(seed(), [
          event(:wave_completed, %{"wave_index" => 0, "stages" => ["planner"]}, 1),
          event(:signals_published, %{"signals" => ["plan-ready"]}, 2),
          event(
            :artifacts_produced,
            %{"artifacts" => [%{"name" => "plan", "producer" => "planner", "ref" => "art_p"}]},
            3
          )
        ])

      assert MapSet.member?(result.ran, "planner")
      assert MapSet.member?(result.live, "plan-ready")
      assert result.artifacts["plan"] == %{"planner" => {:ref, "art_p"}}
      assert result.wave_index == 1
    end
  end

  describe "subtractive folds (defined-only kinds)" do
    test "signals_retracted removes from live" do
      s = seed(%{live: MapSet.new(["a", "b", "c"])})
      result = Projection.project(s, [event(:signals_retracted, %{signals: ["b"]}, 1)])
      assert MapSet.equal?(result.live, MapSet.new(["a", "c"]))
    end

    test "stages_invalidated removes from ran" do
      s = seed(%{ran: MapSet.new(["planner", "approver"])})
      result = Projection.project(s, [event(:stages_invalidated, %{stages: ["planner"]}, 1)])
      assert MapSet.equal?(result.ran, MapSet.new(["approver"]))
    end

    test "stages_invalidated advances wave_index ONLY when closed_wave_index is present (4e)" do
      s = seed(%{ran: MapSet.new(["planner"]), wave_index: 1})

      # With closed_wave_index (the reject-parked-gate path): advance past the wave.
      advanced =
        Projection.project(s, [
          event(:stages_invalidated, %{stages: ["planner"], closed_wave_index: 1}, 1)
        ])

      assert advanced.wave_index == 2

      # Without it (a generic completed-wave rerun): wave_index untouched (no key skip).
      unchanged =
        Projection.project(s, [event(:stages_invalidated, %{stages: ["planner"]}, 1)])

      assert unchanged.wave_index == 1
    end

    test "stages_invalidated bumps the per-stage rerun_counts (the cap source)" do
      s = seed(%{ran: MapSet.new(["planner"]), rerun_counts: %{}})

      result =
        Projection.project(s, [
          event(:stages_invalidated, %{stages: ["planner"]}, 1),
          event(:stages_invalidated, %{stages: ["planner", "plan-gate"]}, 2)
        ])

      assert result.rerun_counts == %{"planner" => 2, "plan-gate" => 1}
    end

    # Camus C1-3: the infra tally fold. Never touches `ran` (the infra'd stage
    # was never folded), bumps `infra_counts` per stage, and honors the same
    # optional `closed_wave_index` advance as `stages_invalidated`.
    test "stage_infra bumps infra_counts and leaves ran + rerun_counts alone" do
      s = seed(%{ran: MapSet.new(["planner"]), rerun_counts: %{}, infra_counts: %{}})

      result =
        Projection.project(s, [
          event(:stage_infra, %{stages: ["quality-reviewer"]}, 1),
          event(:stage_infra, %{"stages" => ["quality-reviewer", "risk-reviewer"]}, 2)
        ])

      assert result.infra_counts == %{"quality-reviewer" => 2, "risk-reviewer" => 1}
      assert MapSet.equal?(result.ran, MapSet.new(["planner"]))
      assert result.rerun_counts == %{}
    end

    test "stage_infra advances wave_index ONLY when closed_wave_index is present (max-idempotent)" do
      s = seed(%{wave_index: 1, infra_counts: %{}})

      advanced =
        Projection.project(s, [
          event(:stage_infra, %{stages: ["quality-reviewer"], closed_wave_index: 1}, 1),
          # A benign replay of the same closed index is idempotent (max).
          event(:stage_infra, %{stages: ["quality-reviewer"], closed_wave_index: 1}, 2)
        ])

      assert advanced.wave_index == 2
      assert advanced.infra_counts == %{"quality-reviewer" => 2}

      unchanged =
        Projection.project(s, [event(:stage_infra, %{stages: ["quality-reviewer"]}, 1)])

      assert unchanged.wave_index == 1
    end

    test "stage_infra tolerates a seed with no infra_counts key (synthetic logs)" do
      result = Projection.project(seed(), [event(:stage_infra, %{stages: ["r"]}, 1)])
      assert result.infra_counts == %{"r" => 1}
    end

    # Item 5: the tamper record fold — the tick terminalizes off this ahead of
    # every other branch, so a crash-window rebuild re-terminalizes.
    test "stage_tampered folds tampered_stages (string and atom keys), never ran" do
      s = seed(%{ran: MapSet.new(["planner"])})

      result =
        Projection.project(s, [
          event(:stage_tampered, %{stage: "verify", reason: "r1", report_ref: "art_a"}, 1),
          event(
            :stage_tampered,
            %{"stage" => "verify", "reason" => "r2", "report_ref" => "art_b"},
            2
          )
        ])

      assert result.tampered_stages == %{"verify" => {"r2", "art_b"}}
      assert MapSet.equal?(result.ran, MapSet.new(["planner"]))
    end

    # Item 5 (C1-6b): the first head_observed is the durable baseline; a later
    # DIFFERING sha derives the seal (the run committed work).
    test "head_observed derives observed_head (baseline) then sealed_head (on a change)" do
      baseline = Projection.project(seed(), [event(:head_observed, %{head: "h1"}, 1)])
      assert baseline.observed_head == "h1"
      assert Map.get(baseline, :sealed_head) == nil

      sealed =
        Projection.project(seed(), [
          event(:head_observed, %{head: "h1"}, 1),
          # A benign same-sha replay derives nothing…
          event(:head_observed, %{"head" => "h1"}, 2),
          # …a change seals.
          event(:head_observed, %{"head" => "h2"}, 3)
        ])

      assert sealed.observed_head == "h2"
      assert sealed.sealed_head == "h2"
    end

    # Item 5: the certificate fold (latest wins) + the invalidation clear — a
    # stale certificate must never back a later green.
    test "verify_certified folds verified_integrity; invalidating the stage clears it" do
      cert = %{stage: "verify", head: "h1", tree_digest: "d1", mode: "working_tree"}

      certified = Projection.project(seed(), [event(:verify_certified, cert, 1)])

      assert certified.verified_integrity == %{
               stage: "verify",
               head: "h1",
               tree_digest: "d1",
               mode: :working_tree
             }

      cleared =
        Projection.project(seed(), [
          event(:verify_certified, cert, 1),
          event(:stages_invalidated, %{stages: ["verify"]}, 2)
        ])

      assert cleared.verified_integrity == nil

      # Invalidating an UNRELATED stage keeps the certificate.
      kept =
        Projection.project(seed(%{ran: MapSet.new(["planner"])}), [
          event(:verify_certified, cert, 1),
          event(:stages_invalidated, %{stages: ["planner"]}, 2)
        ])

      assert kept.verified_integrity.stage == "verify"
    end

    test "verify_report_recorded is provenance-only (no state effect)" do
      s = seed()

      assert Projection.project(s, [
               event(:verify_report_recorded, %{stage: "verify", report_ref: "art_x"}, 1)
             ]) == s
    end

    test "a retracted plan-approved + invalidated stages stay gone across the rebuild (4e)" do
      # The stale-approval shape: publish then retract plan-approved, invalidate the
      # planner+plan-gate. project(seed, log) is the NET state — nothing resurrected.
      s =
        seed(%{
          live: MapSet.new(["code", "plan-approved"]),
          ran: MapSet.new(["planner", "plan-gate"])
        })

      result =
        Projection.project(s, [
          event(:signals_retracted, %{signals: ["plan-approved"]}, 1),
          event(:stages_invalidated, %{stages: ["planner", "plan-gate"]}, 2)
        ])

      refute MapSet.member?(result.live, "plan-approved")
      assert MapSet.equal?(result.ran, MapSet.new())
    end

    test "artifacts_invalidated deletes store[name][producer], pruning an empty name" do
      s =
        seed(%{
          artifacts: %{"plan" => %{"planner" => {:ref, "art_p"}}, "request" => %{"seed" => "R"}}
        })

      result =
        Projection.project(s, [
          event(:artifacts_invalidated, %{artifacts: [%{name: "plan", producer: "planner"}]}, 1)
        ])

      refute Map.has_key?(result.artifacts, "plan")
      assert result.artifacts["request"] == %{"seed" => "R"}
    end

    test "AR-8c verify-loop: invalidating {executor, verifier} drops both, bumps both, keeps wave_index" do
      s =
        seed(%{
          ran: MapSet.new(["system-executor", "system-verifier", "planner"]),
          wave_index: 2,
          rerun_counts: %{}
        })

      result =
        Projection.project(s, [
          event(:stages_invalidated, %{stages: ["system-executor", "system-verifier"]}, 1)
        ])

      # Both leave `ran`; the planner stays.
      assert MapSet.equal?(result.ran, MapSet.new(["planner"]))
      assert result.rerun_counts == %{"system-executor" => 1, "system-verifier" => 1}
      # No closed_wave_index ⇒ wave_index untouched (a generic completed-wave rerun).
      assert result.wave_index == 2
    end

    test "AR-8c verify-loop: the verify-feedback marker folds the tagged ref into the store" do
      # The fenced batch the loop emits on a findings:<lens> re-fire:
      # stages_invalidated (no closed_wave_index) + artifacts_produced carrying the
      # BARE findings ref into `verify-feedback`. The projection reconstructs the
      # TAGGED {:ref, ref} mirror the in-memory `apply_invalidation` stores — the
      # projection-equivalence invariant (C3/C4).
      s =
        seed(%{
          ran: MapSet.new(["system-executor", "system-verifier"]),
          artifacts: %{"findings" => %{"system-verifier" => {:ref, "art_f"}}},
          rerun_counts: %{}
        })

      result =
        Projection.project(s, [
          event(:stages_invalidated, %{stages: ["system-executor", "system-verifier"]}, 1),
          event(
            :artifacts_produced,
            %{artifacts: [%{name: "verify-feedback", producer: "system-verifier", ref: "art_f"}]},
            2
          )
        ])

      # verify-feedback mirrors the findings ref (tagged), keyed by the verifier.
      assert result.artifacts["verify-feedback"] == %{"system-verifier" => {:ref, "art_f"}}
      # The original findings entry is untouched (only `ran`/`rerun_counts` changed).
      assert result.artifacts["findings"] == %{"system-verifier" => {:ref, "art_f"}}
      assert MapSet.equal?(result.ran, MapSet.new())
      assert result.rerun_counts == %{"system-executor" => 1, "system-verifier" => 1}
    end
  end

  describe "equivalence invariant — project(seed, log) == in-memory Fold" do
    test "a multi-wave run incl. a paired-verdict flip round-trips through signals_retracted" do
      s = seed()

      # --- In-memory: three waves of Fold ---
      w0 = [
        %StageEmission{stage: "planner", signals: ["plan-ready"], artifacts: %{"plan" => "art_p"}}
      ]

      w1 = [%StageEmission{stage: "q", signals: ["findings:quality"]}]
      w2 = [%StageEmission{stage: "q", signals: ["clean:quality"]}]

      s0 = Fold.fold(s, w0)
      s1 = Fold.fold(s0, w1)
      s2 = Fold.fold(s1, w2)

      # --- Durable: the deltas the loop derives by diffing pre/post Fold state ---
      # Wave 2's clean:quality retracts the live findings:quality — captured as a
      # signals_retracted delta, NOT assumed empty.
      events = [
        event(:wave_completed, %{wave_index: 0, stages: ["planner"]}, 1),
        event(:signals_published, %{signals: signals_pub(s, s0)}, 2),
        event(:artifacts_produced, %{artifacts: artifacts_pub(s, s0)}, 3),
        event(:wave_completed, %{wave_index: 1, stages: ["q"]}, 4),
        event(:signals_published, %{signals: signals_pub(s0, s1)}, 5),
        event(:wave_completed, %{wave_index: 2, stages: ["q"]}, 6),
        event(:signals_published, %{signals: signals_pub(s1, s2)}, 7),
        event(:signals_retracted, %{signals: signals_ret(s1, s2)}, 8)
      ]

      projected = Projection.project(s, events)

      # The Fold-owned fields match exactly — the equivalence invariant.
      assert MapSet.equal?(projected.live, s2.live)
      assert projected.artifacts == s2.artifacts
      assert MapSet.equal?(projected.ran, s2.ran)
      # And the paired-verdict flip really happened: findings retracted, clean live.
      assert MapSet.member?(projected.live, "clean:quality")
      refute MapSet.member?(projected.live, "findings:quality")
      # wave_index = completed-wave count.
      assert projected.wave_index == 3
    end

    # AR-4: the self-heal hooks WELD their rerun markers into the wave commit and
    # mirror them in memory via `apply_markers/2`. Proving `apply_markers == project`
    # over the SAME marker batch is the projection-equivalence invariant for the
    # welded path — a crash after a fixer wave re-projects exactly the in-memory
    # mirror (no "fixer ran, no re-review trigger" half-state).
    test "apply_markers (welded in-memory mirror) == project (durable fold) — Hook R batch" do
      s =
        seed(%{
          ran: MapSet.new(["quality-reviewer", "correctness-reviewer", "fixer"]),
          artifacts: %{
            # this round's flagged correctness findings/action_needed
            "findings" => %{"correctness-reviewer" => {:ref, "art_fc"}},
            "action_needed" => %{"correctness-reviewer" => {:ref, "art_ac"}},
            # a since-cleaned lens's STALE feedback from a prior round
            "review-feedback" => %{"quality-reviewer" => {:ref, "art_old"}},
            "review-action" => %{"quality-reviewer" => {:ref, "art_oldA"}}
          },
          rerun_counts: %{}
        })

      # The Hook R welded batch, in canonical order: clear the stale feedback,
      # produce this round's, then re-fire the (already-ran) fixer.
      markers = [
        {:artifacts_invalidated,
         %{
           artifacts: [
             %{name: "review-feedback", producer: "quality-reviewer"},
             %{name: "review-action", producer: "quality-reviewer"}
           ]
         }},
        {:artifacts_produced,
         %{
           artifacts: [
             %{name: "review-feedback", producer: "correctness-reviewer", ref: "art_fc"},
             %{name: "review-action", producer: "correctness-reviewer", ref: "art_ac"}
           ]
         }},
        {:stages_invalidated, %{stages: ["fixer"]}}
      ]

      in_memory = Projection.apply_markers(s, markers)

      durable_events =
        markers
        |> Enum.with_index(1)
        |> Enum.map(fn {{k, p}, i} -> event(k, p, i) end)

      durable = Projection.project(s, durable_events)

      # Equivalence by construction (both fold the same markers via apply_event).
      assert in_memory == durable

      # And the effects are right: the stale quality feedback is gone, this round's
      # correctness feed is in, the fixer left `ran` (re-fires), counts bumped.
      assert in_memory.artifacts["review-feedback"] == %{
               "correctness-reviewer" => {:ref, "art_fc"}
             }

      assert in_memory.artifacts["review-action"] == %{"correctness-reviewer" => {:ref, "art_ac"}}
      refute MapSet.member?(in_memory.ran, "fixer")
      assert in_memory.rerun_counts == %{"fixer" => 1}
    end
  end

  # The loop's diff helpers, mirrored: published = post \ pre, retracted = pre \ post.
  defp signals_pub(pre, post), do: Enum.sort(MapSet.difference(post.live, pre.live))
  defp signals_ret(pre, post), do: Enum.sort(MapSet.difference(pre.live, post.live))

  defp artifacts_pub(pre, post) do
    for {name, producers} <- post.artifacts,
        {producer, entry} <- producers,
        get_in(pre.artifacts, [name, producer]) != entry do
      %{name: name, producer: producer, ref: bare(entry)}
    end
  end

  defp bare({:ref, ref}), do: ref
  defp bare(other), do: other
end
