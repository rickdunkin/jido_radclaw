defmodule JidoClaw.Forge.ResumeStateTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.ResumeState

  @id "11111111-2222-3333-4444-555555555555"
  @other_id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  defp anchored(workdir \\ "/work") do
    {:ok, rs} = ResumeState.mint_client(ResumeState.new(), @id, workdir)
    rs
  end

  describe "anchor lifecycle" do
    test "new/1 starts unanchored, armed, startup-sourced" do
      rs = ResumeState.new(workdir: "/w")

      assert rs.arming == :armed
      assert rs.status == :unanchored
      assert rs.session_id == nil
      assert rs.workdir == "/w"
      assert rs.session_start_source == :startup
      refute rs.retry_used
      assert rs.epoch == 0
      assert rs.revision == 0
    end

    test "mint_client anchors immediately with client ownership" do
      {:ok, rs} = ResumeState.mint_client(ResumeState.new(), @id, "/work")

      assert rs.status == :anchored
      assert rs.ownership == :client
      assert rs.session_id == @id
      assert rs.workdir == "/work"
      assert %DateTime{} = rs.anchored_at
      refute rs.retry_used
    end

    test "mint_client refuses on non-unanchored states" do
      assert {:error, :already_anchored} = ResumeState.mint_client(anchored(), @other_id, "/w")

      poisoned = ResumeState.poison(anchored())
      assert {:error, :poisoned} = ResumeState.mint_client(poisoned, @other_id, "/w")
    end

    test "mint_client validates the session id" do
      rs = ResumeState.new()

      assert {:error, :invalid_session_id} = ResumeState.mint_client(rs, "", "/w")
      assert {:error, :invalid_session_id} = ResumeState.mint_client(rs, "a\nb", "/w")

      long = String.duplicate("a", 513)
      assert {:error, :invalid_session_id} = ResumeState.mint_client(rs, long, "/w")
    end

    test "capture_backend is provisional until trusted (CH2-6)" do
      {:ok, rs} = ResumeState.capture_backend(ResumeState.new(), @id, "/work")

      assert rs.status == :provisional
      assert rs.ownership == :backend

      trusted = ResumeState.trust(rs)
      assert trusted.status == :anchored
      assert %DateTime{} = trusted.anchored_at
    end

    test "trust is total — non-provisional states pass through" do
      rs = anchored()
      assert ResumeState.trust(rs) == rs

      poisoned = ResumeState.poison(rs)
      assert ResumeState.trust(poisoned).status == :poisoned
    end

    test "clear wipes the anchor and records the source" do
      cleared = ResumeState.clear(anchored(), :new)

      assert cleared.status == :unanchored
      assert cleared.session_id == nil
      assert cleared.ownership == nil
      assert cleared.anchored_at == nil
      assert cleared.session_start_source == :new

      assert ResumeState.clear(anchored(), :clear).session_start_source == :clear
    end

    test "clear on a poisoned state is a no-op — poisoning is sticky" do
      poisoned = ResumeState.poison(anchored())
      assert ResumeState.clear(poisoned, :new) == poisoned
      assert poisoned.session_id == @id
    end

    test "poison keeps the id for the never-reuse check" do
      poisoned = ResumeState.poison(anchored())

      assert poisoned.status == :poisoned
      assert poisoned.session_id == @id
    end

    test "rearm_new_anchor refuses the poisoned id" do
      poisoned = ResumeState.poison(anchored())

      assert {:error, :poisoned_id_reuse} =
               ResumeState.rearm_new_anchor(poisoned, @id, "/w", :client)
    end

    test "rearm_new_anchor establishes a different id and resets the retry latch" do
      poisoned =
        anchored()
        |> ResumeState.mark_retry_used()
        |> ResumeState.poison()

      {:ok, rearmed} = ResumeState.rearm_new_anchor(poisoned, @other_id, "/w2", :client)

      assert rearmed.status == :anchored
      assert rearmed.session_id == @other_id
      assert rearmed.workdir == "/w2"
      assert rearmed.session_start_source == :new
      refute rearmed.retry_used

      {:ok, backend} = ResumeState.rearm_new_anchor(poisoned, @other_id, "/w2", :backend)
      assert backend.status == :provisional
    end

    test "rearm_new_anchor requires a poisoned state" do
      assert {:error, :not_poisoned} =
               ResumeState.rearm_new_anchor(anchored(), @other_id, "/w", :client)
    end

    test "a fresh anchor after clear resets retry_used" do
      cleared =
        anchored()
        |> ResumeState.mark_retry_used()
        |> ResumeState.clear(:new)

      assert cleared.retry_used

      {:ok, rs} = ResumeState.mint_client(cleared, @other_id, "/w")
      refute rs.retry_used
    end

    test "continuing marks the resume source" do
      assert ResumeState.continuing(anchored()).session_start_source == :resume
    end

    test "stamp sets epoch and revision" do
      rs = ResumeState.stamp(anchored(), 3, 7)
      assert rs.epoch == 3
      assert rs.revision == 7
    end
  end

  describe "guidance lifecycle" do
    test "put_guidance parks pending and bumps guidance_rev" do
      {:ok, rs} = ResumeState.put_guidance(anchored(), "use the staging config")

      assert rs.pending_guidance == %{status: :pending, text: "use the staging config"}
      assert rs.guidance_rev == 1
      assert ResumeState.live_guidance?(rs)
    end

    test "put_guidance rejects over the 16KB bound, never truncates" do
      over = String.duplicate("a", 16_385)
      assert {:error, :guidance_too_large} = ResumeState.put_guidance(anchored(), over)

      at_bound = String.duplicate("a", 16_384)
      assert {:ok, _} = ResumeState.put_guidance(anchored(), at_bound)
    end

    test "put_guidance rejects non-binary input" do
      assert {:error, :guidance_not_binary} = ResumeState.put_guidance(anchored(), %{a: 1})
    end

    test "guidance_inflight requires pending" do
      {:ok, pending} = ResumeState.put_guidance(anchored(), "answer")
      {:ok, inflight} = ResumeState.guidance_inflight(pending)

      assert inflight.pending_guidance == %{status: :inflight, text: "answer"}
      assert inflight.guidance_rev == 2
      assert ResumeState.live_guidance?(inflight)

      assert {:error, :no_pending_guidance} = ResumeState.guidance_inflight(anchored())
      assert {:error, :no_pending_guidance} = ResumeState.guidance_inflight(inflight)
    end

    test "guidance_consumed drops text but keeps the marker" do
      {:ok, pending} = ResumeState.put_guidance(anchored(), "answer")
      {:ok, inflight} = ResumeState.guidance_inflight(pending)
      consumed = ResumeState.guidance_consumed(inflight)

      assert consumed.pending_guidance == %{status: :consumed, text: nil}
      assert consumed.guidance_rev == 3
      refute ResumeState.live_guidance?(consumed)

      guidance_less = anchored()
      assert ResumeState.guidance_consumed(guidance_less) == guidance_less
    end
  end

  describe "resolve_mode/2" do
    test "anchored + matching cwd is the only continuation" do
      assert ResumeState.resolve_mode(anchored("/work"), "/work") == :continuation
    end

    test "everything else is fresh-armed with a reason" do
      assert ResumeState.resolve_mode(anchored("/work"), "/elsewhere") ==
               {:fresh_armed, :cwd_mismatch}

      assert ResumeState.resolve_mode(anchored("/work"), nil) == {:fresh_armed, :no_workdir}

      no_wd = %{anchored("/work") | workdir: nil}
      assert ResumeState.resolve_mode(no_wd, "/work") == {:fresh_armed, :no_workdir}

      assert ResumeState.resolve_mode(ResumeState.new(), "/work") ==
               {:fresh_armed, :unanchored}

      {:ok, provisional} = ResumeState.capture_backend(ResumeState.new(), @id, "/work")
      assert ResumeState.resolve_mode(provisional, "/work") == {:fresh_armed, :provisional}

      poisoned = ResumeState.poison(anchored("/work"))
      assert ResumeState.resolve_mode(poisoned, "/work") == {:fresh_armed, :poisoned}
    end
  end

  describe "valid_session_id?/1" do
    test "accepts UUID-like ids and rejects argv-unsafe shapes" do
      assert ResumeState.valid_session_id?(@id)
      assert ResumeState.valid_session_id?("thread_abc123")

      refute ResumeState.valid_session_id?("")
      refute ResumeState.valid_session_id?(nil)
      refute ResumeState.valid_session_id?(:atom)
      refute ResumeState.valid_session_id?("has\nnewline")
      refute ResumeState.valid_session_id?("has\ttab")
      refute ResumeState.valid_session_id?("has\x00null")
      refute ResumeState.valid_session_id?(<<0xFF, 0xFE>>)
      refute ResumeState.valid_session_id?(String.duplicate("a", 513))
      assert ResumeState.valid_session_id?(String.duplicate("a", 512))
    end
  end

  describe "state codec" do
    test "encode_state/decode_state round-trips every status" do
      retried_continuing =
        anchored()
        |> ResumeState.mark_retry_used()
        |> ResumeState.continuing()

      states = [
        ResumeState.new(workdir: "/w"),
        anchored(),
        elem(ResumeState.capture_backend(ResumeState.new(), @id, "/w"), 1),
        ResumeState.poison(anchored()),
        retried_continuing,
        ResumeState.stamp(anchored(), 4, 9)
      ]

      for rs <- states do
        {:ok, decoded} =
          rs
          |> ResumeState.encode_state()
          |> ResumeState.decode_state()

        assert decoded.status == rs.status
        assert decoded.ownership == rs.ownership
        assert decoded.session_id == rs.session_id
        assert decoded.workdir == rs.workdir
        assert decoded.session_start_source == rs.session_start_source
        assert decoded.retry_used == rs.retry_used
        assert decoded.epoch == rs.epoch
        assert decoded.revision == rs.revision

        if rs.anchored_at do
          assert DateTime.compare(decoded.anchored_at, rs.anchored_at) == :eq
        end
      end
    end

    test "encode_state never carries guidance text" do
      {:ok, rs} = ResumeState.put_guidance(anchored(), "the secret answer")
      encoded = ResumeState.encode_state(rs)

      refute Map.has_key?(encoded, "text")
      refute Map.has_key?(encoded, "pending_guidance")
      refute inspect(encoded) =~ "the secret answer"
    end

    test "decode_state refuses malformed copies" do
      valid = ResumeState.encode_state(anchored())

      malformed = [
        nil,
        "string",
        %{},
        Map.delete(valid, "v"),
        Map.put(valid, "v", 2),
        Map.put(valid, "status", "bogus"),
        Map.put(valid, "status", :anchored),
        Map.put(valid, "epoch", "3"),
        Map.put(valid, "epoch", -1),
        Map.put(valid, "retry_used", "false"),
        Map.put(valid, "session_start_source", "sideways"),
        Map.put(valid, "ownership", "nobody"),
        Map.put(valid, "anchored_at", "not-a-date"),
        # cross-field: a live anchor requires an id; unanchored must not carry one
        Map.put(valid, "session_id", nil),
        Map.put(valid, "session_id", "bad\nid"),
        Map.put(valid, "status", "unanchored"),
        Map.put(ResumeState.encode_state(ResumeState.new()), "session_id", @id)
      ]

      for input <- malformed do
        assert ResumeState.decode_state(input) == :error,
               "expected :error for #{inspect(input)}"
      end
    end

    test "a poisoned copy may carry its recorded id or none" do
      encoded = ResumeState.encode_state(ResumeState.poison(anchored()))

      assert {:ok, %{session_id: @id}} = ResumeState.decode_state(encoded)

      id_less = Map.put(encoded, "session_id", nil)
      assert {:ok, %{session_id: nil}} = ResumeState.decode_state(id_less)
    end
  end

  describe "guidance codec" do
    test "marker carries status + rev + epoch, never text" do
      assert ResumeState.encode_guidance_marker(anchored()) == nil

      {:ok, rs} = ResumeState.put_guidance(ResumeState.stamp(anchored(), 2, 5), "answer")
      marker = ResumeState.encode_guidance_marker(rs)

      assert marker == %{"v" => 1, "status" => "pending", "guidance_rev" => 1, "epoch" => 2}
      refute inspect(marker) =~ "answer"
    end

    test "encode_guidance encrypts text into the vault envelope and round-trips" do
      {:ok, rs} = ResumeState.put_guidance(ResumeState.stamp(anchored(), 2, 5), "the answer")
      {:ok, encoded} = ResumeState.encode_guidance(rs)

      assert %{"v" => 1, "status" => "pending", "guidance_rev" => 1, "epoch" => 2} =
               Map.delete(encoded, "text")

      assert %{"v" => 1, "alg" => "vault", "data" => b64} = encoded["text"]
      refute inspect(encoded) =~ "the answer"
      assert {:ok, _} = Base.decode64(b64)

      {:ok, copy} = ResumeState.decode_guidance(encoded)

      assert copy == %{
               status: :pending,
               guidance_rev: 1,
               epoch: 2,
               text: "the answer",
               repark_reason: nil
             }
    end

    test "encode_guidance is nil-safe and text-less for consumed" do
      assert ResumeState.encode_guidance(anchored()) == {:ok, nil}

      {:ok, pending} = ResumeState.put_guidance(anchored(), "answer")
      consumed = ResumeState.guidance_consumed(pending)
      {:ok, encoded} = ResumeState.encode_guidance(consumed)

      assert encoded["status"] == "consumed"
      refute Map.has_key?(encoded, "text")
    end

    test "decode_guidance surfaces corruption loudly, never silently" do
      {:ok, rs} = ResumeState.put_guidance(anchored(), "answer")
      {:ok, encoded} = ResumeState.encode_guidance(rs)

      corrupt = [
        Map.put(encoded, "text", %{"v" => 1, "alg" => "vault", "data" => "!!!not-base64"}),
        Map.put(encoded, "text", %{
          "v" => 1,
          "alg" => "vault",
          "data" => Base.encode64("tampered")
        }),
        Map.put(encoded, "text", %{"v" => 9, "alg" => "vault", "data" => "AAAA"}),
        Map.put(encoded, "text", "plaintext-shaped"),
        Map.put(encoded, "status", "bogus"),
        %{"not" => "a guidance copy"},
        "garbage"
      ]

      for input <- corrupt do
        assert ResumeState.decode_guidance(input) == {:error, :corrupt_guidance},
               "expected corrupt for #{inspect(input, printable_limit: 80)}"
      end

      assert ResumeState.decode_guidance(nil) == {:ok, nil}
    end
  end

  describe "select/4" do
    defp stamped(epoch, revision), do: ResumeState.stamp(anchored(), epoch, revision)

    defp guidance_copy(status, rev, epoch, text \\ nil),
      do: %{status: status, guidance_rev: rev, epoch: epoch, text: text}

    test "returns nil when no state copy exists" do
      assert ResumeState.select(nil, nil, nil, nil) == nil
    end

    test "anchor state is the newest {epoch, revision} across both stores" do
      md = stamped(2, 3)
      cp = stamped(2, 1)
      assert ResumeState.select(md, nil, cp, nil).revision == 3

      older_epoch_higher_rev = stamped(1, 99)
      newer_epoch = stamped(2, 0)
      assert ResumeState.select(older_epoch_higher_rev, nil, newer_epoch, nil).epoch == 2

      assert ResumeState.select(nil, nil, cp, nil).revision == 1
      assert ResumeState.select(md, nil, nil, nil).revision == 3
    end

    test "guidance status: highest guidance_rev within the selected epoch" do
      md_state = stamped(2, 3)

      # metadata marker newer than checkpoint copy — for each status
      for status <- [:pending, :inflight, :consumed] do
        merged =
          ResumeState.select(
            md_state,
            guidance_copy(status, 5, 2),
            stamped(2, 1),
            guidance_copy(:pending, 4, 2, "older text")
          )

        assert merged.pending_guidance.status == status
        assert merged.guidance_rev == 5
        # text only ever rides a checkpoint WINNER — a newer metadata
        # marker wins status with text honestly absent
        assert merged.pending_guidance.text == nil
      end
    end

    test "checkpoint guidance winner carries its text" do
      merged =
        ResumeState.select(
          stamped(2, 3),
          guidance_copy(:pending, 4, 2),
          stamped(2, 1),
          guidance_copy(:pending, 6, 2, "the answer")
        )

      assert merged.pending_guidance == %{status: :pending, text: "the answer"}
      assert merged.guidance_rev == 6
    end

    test "guidance from another epoch never rides" do
      merged =
        ResumeState.select(
          stamped(3, 0),
          guidance_copy(:pending, 9, 2),
          stamped(2, 5),
          guidance_copy(:pending, 9, 2, "stale epoch text")
        )

      assert merged.epoch == 3
      assert merged.pending_guidance == nil
      assert merged.guidance_rev == 0
    end

    test "equal guidance_rev tie resolves to the text-carrying checkpoint copy (F6)" do
      # The NORMAL checked-save state: one struct encoded both copies, so
      # both carry the same rev — the metadata marker winning would strip
      # the operator's answer.
      merged =
        ResumeState.select(
          stamped(2, 3),
          guidance_copy(:pending, 4, 2),
          stamped(2, 1),
          guidance_copy(:pending, 4, 2, "the parked answer")
        )

      assert merged.pending_guidance == %{status: :pending, text: "the parked answer"}
      assert merged.guidance_rev == 4
    end

    test "a strictly-newer metadata marker still wins the tie-broken merge" do
      # e.g. a best-effort consumed marker that landed after the checkpoint.
      merged =
        ResumeState.select(
          stamped(2, 3),
          guidance_copy(:consumed, 5, 2),
          stamped(2, 1),
          guidance_copy(:inflight, 4, 2, "already answered")
        )

      assert merged.pending_guidance == %{status: :consumed, text: nil}
      assert merged.guidance_rev == 5
    end

    test "the winner copy's repark_reason rides the merge" do
      copy = Map.put(guidance_copy(:consumed, 4, 2), :repark_reason, :guidance_text_missing)
      merged = ResumeState.select(stamped(2, 3), nil, stamped(2, 1), copy)

      assert merged.repark_reason == :guidance_text_missing
    end
  end

  describe "guidance delivery accessors" do
    defp inflight_with(text) do
      {:ok, pending} = ResumeState.put_guidance(anchored(), text)
      {:ok, inflight} = ResumeState.guidance_inflight(pending)
      inflight
    end

    test "inflight_text/1 returns text only for inflight guidance" do
      assert ResumeState.inflight_text(inflight_with("answer")) == "answer"

      assert ResumeState.inflight_text(anchored()) == nil
      {:ok, pending} = ResumeState.put_guidance(anchored(), "answer")
      assert ResumeState.inflight_text(pending) == nil
      assert ResumeState.inflight_text(ResumeState.guidance_consumed(pending)) == nil
    end

    test "guidance_undelivered/1 reverts inflight to pending, keeps text, bumps rev" do
      rs = inflight_with("answer")
      reverted = ResumeState.guidance_undelivered(rs)

      assert reverted.pending_guidance == %{status: :pending, text: "answer"}
      assert reverted.guidance_rev == rs.guidance_rev + 1
    end

    test "guidance_undelivered/1 is a no-op on every other state" do
      for rs <- [anchored(), elem(ResumeState.put_guidance(anchored(), "a"), 1)] do
        assert ResumeState.guidance_undelivered(rs) == rs
      end
    end

    test "fresh_start?/1 is false only for a resumed turn" do
      refute ResumeState.fresh_start?(ResumeState.continuing(anchored()))

      assert ResumeState.fresh_start?(ResumeState.new())
      assert ResumeState.fresh_start?(anchored())
      assert ResumeState.fresh_start?(ResumeState.clear(anchored(), :new))
    end

    test "mark_guidance_lost/1 grafts a re-parkable marker and preserves the reason" do
      rs = ResumeState.mark_guidance_lost(anchored())
      assert rs.pending_guidance == %{status: :pending, text: nil}
      assert rs.guidance_rev == 1

      carrying = %{anchored() | repark_reason: :inflight_delivery_ambiguous}

      assert ResumeState.mark_guidance_lost(carrying).repark_reason ==
               :inflight_delivery_ambiguous
    end
  end

  describe "adopt_recovered_guidance/2" do
    defp copy(status, rev, opts \\ []) do
      %{
        status: status,
        guidance_rev: rev,
        epoch: 1,
        text: Keyword.get(opts, :text),
        repark_reason: Keyword.get(opts, :repark_reason)
      }
    end

    test "nil copy → :none, state untouched" do
      rs = anchored()
      assert ResumeState.adopt_recovered_guidance(rs, {:ok, nil}) == {:none, rs}
    end

    test "pending with text restores status/text/rev" do
      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(
          anchored(),
          {:ok, copy(:pending, 7, text: "the answer")}
        )

      assert disposition == :restored
      assert adopted.pending_guidance == %{status: :pending, text: "the answer"}
      assert adopted.guidance_rev == 7
      assert adopted.repark_reason == nil
    end

    test "pending without text consume-grafts and re-parks as text-missing" do
      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(anchored(), {:ok, copy(:pending, 7)})

      assert disposition == {:repark, :guidance_text_missing}
      assert adopted.pending_guidance == %{status: :consumed, text: nil}
      # Grafted at the copy's rev then consumed (rev+1) — out-revs the stale copy.
      assert adopted.guidance_rev == 8
      assert adopted.repark_reason == :guidance_text_missing
    end

    test "inflight consume-grafts and re-parks as delivery-ambiguous — never resends" do
      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(
          anchored(),
          {:ok, copy(:inflight, 3, text: "maybe delivered")}
        )

      assert disposition == {:repark, :inflight_delivery_ambiguous}
      assert adopted.pending_guidance == %{status: :consumed, text: nil}
      assert adopted.guidance_rev == 4
      assert adopted.repark_reason == :inflight_delivery_ambiguous
    end

    test "consumed without a reason keeps the marker" do
      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(anchored(), {:ok, copy(:consumed, 5)})

      assert disposition == :kept
      assert adopted.pending_guidance == %{status: :consumed, text: nil}
      assert adopted.guidance_rev == 5
      assert adopted.repark_reason == nil
    end

    test "a copy carrying repark_reason re-parks with the SAME reason, restored verbatim" do
      # The second-recovery authority row: the persisted reason survives
      # repeated crashes until an answer clears it — never a :ready recovery.
      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(
          anchored(),
          {:ok, copy(:consumed, 8, repark_reason: :inflight_delivery_ambiguous)}
        )

      assert disposition == {:repark, :inflight_delivery_ambiguous}
      assert adopted.pending_guidance == %{status: :consumed, text: nil}
      # Restored verbatim — no re-bump.
      assert adopted.guidance_rev == 8
      assert adopted.repark_reason == :inflight_delivery_ambiguous
    end

    test "corrupt guidance consume-grafts a durable marker at the state's own rev" do
      rs = anchored()

      {disposition, adopted} =
        ResumeState.adopt_recovered_guidance(rs, {:error, :corrupt_guidance})

      assert disposition == {:repark, :corrupt_guidance}
      # No decodable copy exists, so the graft is synthetic: the consumed
      # marker + reason land at the state's own rev (+1 via the consume),
      # making the re-park durable and authoritative like every other lane.
      assert adopted.pending_guidance == %{status: :consumed, text: nil}
      assert adopted.guidance_rev == rs.guidance_rev + 1
      assert adopted.repark_reason == :corrupt_guidance
    end

    test "the corrupt-lane graft rides the codec and re-parks at the next recovery" do
      {_disposition, adopted} =
        ResumeState.adopt_recovered_guidance(anchored(), {:error, :corrupt_guidance})

      {:ok, encoded} = ResumeState.encode_guidance(adopted)
      {:ok, decoded} = ResumeState.decode_guidance(encoded)

      {disposition, readopted} =
        ResumeState.adopt_recovered_guidance(anchored(), {:ok, decoded})

      # Second-recovery authority: the persisted reason re-parks forever
      # until an answer clears it — never a silent :ready recovery.
      assert disposition == {:repark, :corrupt_guidance}
      assert readopted.pending_guidance == %{status: :consumed, text: nil}
      # Restored verbatim — no re-bump.
      assert readopted.guidance_rev == decoded.guidance_rev
      assert readopted.repark_reason == :corrupt_guidance
    end
  end

  describe "repark_reason durability" do
    test "rides the metadata marker codec and whitelist-decodes" do
      rs = %{
        ResumeState.guidance_consumed(elem(ResumeState.put_guidance(anchored(), "a"), 1))
        | repark_reason: :guidance_text_missing
      }

      marker = ResumeState.encode_guidance_marker(rs)
      assert marker["repark_reason"] == "guidance_text_missing"

      {:ok, decoded} = ResumeState.decode_guidance(marker)
      assert decoded.repark_reason == :guidance_text_missing
    end

    test "rides the checkpoint envelope codec alongside encrypted text" do
      {:ok, parked} = ResumeState.put_guidance(anchored(), "answer")
      rs = %{parked | repark_reason: :corrupt_guidance}

      {:ok, encoded} = ResumeState.encode_guidance(rs)
      assert encoded["repark_reason"] == "corrupt_guidance"
      assert Map.has_key?(encoded, "text")

      {:ok, decoded} = ResumeState.decode_guidance(encoded)
      assert decoded.repark_reason == :corrupt_guidance
      assert decoded.text == "answer"
    end

    test "an unknown reason string decodes to nil, never String.to_atom" do
      {:ok, rs} = ResumeState.put_guidance(anchored(), "a")
      marker = Map.put(ResumeState.encode_guidance_marker(rs), "repark_reason", "surprise_atom")

      {:ok, decoded} = ResumeState.decode_guidance(marker)
      assert decoded.repark_reason == nil
      # The copy itself stays usable — a bad reason never corrupts it.
      assert decoded.status == :pending
    end

    test "absent when nil — the marker stays byte-identical to the pre-repark shape" do
      {:ok, rs} = ResumeState.put_guidance(ResumeState.stamp(anchored(), 2, 5), "answer")
      marker = ResumeState.encode_guidance_marker(rs)

      refute Map.has_key?(marker, "repark_reason")
    end

    test "put_guidance/2 is the only clearer" do
      rs = %{anchored() | repark_reason: :guidance_text_missing}

      {:ok, answered} = ResumeState.put_guidance(rs, "fresh answer")
      assert answered.repark_reason == nil
      assert answered.pending_guidance == %{status: :pending, text: "fresh answer"}

      # Consuming does NOT clear it — the marker stays authoritative.
      still =
        ResumeState.guidance_consumed(%{rs | pending_guidance: %{status: :inflight, text: "x"}})

      assert still.repark_reason == :guidance_text_missing
    end
  end
end
