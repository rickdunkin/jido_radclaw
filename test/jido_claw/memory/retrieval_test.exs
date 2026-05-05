defmodule JidoClaw.Memory.RetrievalTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias JidoClaw.Memory
  alias JidoClaw.Memory.Fact
  alias JidoClaw.Workspaces.Resolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

    {:ok, ws} =
      Resolver.ensure_workspace(
        "default",
        "/tmp/retrieval_test_#{System.unique_integer([:positive])}",
        []
      )

    tool_context = %{
      tenant_id: "default",
      user_id: nil,
      workspace_uuid: ws.id,
      session_uuid: nil
    }

    {:ok, tool_context: tool_context, workspace: ws}
  end

  defp create_session(ws) do
    external_id = "ext_#{System.unique_integer([:positive])}"
    started_at = DateTime.utc_now()

    {:ok, session} =
      JidoClaw.Conversations.Session
      |> Ash.Changeset.for_create(:start, %{
        tenant_id: "default",
        workspace_id: ws.id,
        kind: :repl,
        external_id: external_id,
        started_at: started_at
      })
      |> Ash.create(domain: JidoClaw.Conversations)

    session.id
  end

  describe "no-match recall regression" do
    test "non-empty query with no matches returns []", %{tool_context: tc} do
      :ok = Memory.remember_from_user(%{key: "foo", content: "alpha", type: "fact"}, tc)
      :ok = Memory.remember_from_user(%{key: "bar", content: "beta", type: "fact"}, tc)

      results = Memory.recall("completely-unrelated-zzz-string", tool_context: tc, limit: 5)
      assert results == []
    end
  end

  describe "scope-chain regression" do
    test "workspace fact recalled from a session-scoped tool_context", %{
      workspace: ws
    } do
      ws_only_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id
      }

      :ok =
        Memory.remember_from_user(
          %{key: "api_url", content: "https://api.example.com", type: "fact"},
          ws_only_ctx
        )

      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      results = Memory.recall("api_url", tool_context: session_ctx, limit: 5)
      assert Enum.any?(results, fn r -> r.key == "api_url" end)
    end
  end

  describe "ANN model resolution regression" do
    setup do
      stub_voyage = Module.concat([__MODULE__, StubVoyage])

      unless Code.ensure_loaded?(stub_voyage) do
        Code.compile_quoted(
          quote do
            defmodule unquote(stub_voyage) do
              # Returns a fixed unit vector irrespective of input — the
              # SQL ranks by cosine distance between this vector and the
              # stored fact's embedding (set to the same vector below),
              # so this row should always rank first in the ANN pool.
              def embed_for_query(_q, _model), do: {:ok, fixed_embedding()}
              def fixed_embedding, do: List.duplicate(0.001, 1024)
            end
          end
        )
      end

      {:ok, stub_voyage: stub_voyage}
    end

    test "explicit embedding_model voyage-4-large produces ANN hits even when FTS+lex miss",
         %{tool_context: tc, stub_voyage: stub} do
      embedding = stub.fixed_embedding()

      :ok =
        Memory.remember_from_user(
          %{key: "stripe_for_billing", content: "Use Stripe for billing", type: "fact"},
          tc
        )

      [seeded] = Ash.read!(Fact)

      # Manually populate the embedding row to mimic a successful
      # backfill (Memory.remember_from_user defaults to disabled when
      # the workspace policy is :disabled, which is the case here).
      Ash.Changeset.for_update(seeded, :transition_embedding_status, %{
        embedding: embedding,
        embedding_status: :ready,
        embedding_model: "voyage-4-large"
      })
      |> Ash.update!()

      # A query that does not lexically match the seeded content/label/tags
      # so FTS and lex pools are zeroed; ANN must do the work.
      results =
        Memory.recall(
          "completely-orthogonal-tokens-zzz",
          tool_context: tc,
          limit: 5,
          embedding_model: "voyage-4-large",
          query_embedding: embedding,
          voyage_module: stub
        )

      assert Enum.any?(results, fn r -> r.key == "stripe_for_billing" end)

      # Repeat with the default model (no explicit embedding_model).
      results_default =
        Memory.recall(
          "completely-orthogonal-tokens-zzz",
          tool_context: tc,
          limit: 5,
          query_embedding: embedding,
          voyage_module: stub
        )

      assert Enum.any?(results_default, fn r -> r.key == "stripe_for_billing" end)
    end
  end

  describe "hybrid search per-pool precedence dedup" do
    test "lower-scope sibling cannot win a label when the closer-scope row is pushed below the per-pool LIMIT pre-fix",
         %{workspace: ws} do
      # The reviewer's bug: each FTS/ANN/Lex pool applied LIMIT N*4
      # BEFORE the cross-pool precedence dedup. A closer-scope row at
      # the same label as a lower-scope row could rank below that cap
      # — pre-fix it was excluded from `ranked`, so the lower-scope
      # sibling alone made it through and won the label.
      #
      # Cap math (limit=3 → cap=12): we need 12+ higher-FTS-scoring
      # matching rows to actually push the session row past the cap.
      # Without that pressure, both rows fit comfortably under the cap
      # pre-fix and the test passes for the wrong reason.
      ws_ctx = %{tenant_id: "default", workspace_uuid: ws.id}
      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      # Session-scope `preference` — content has lots of non-query
      # tokens diluting both the FTS density and the pg_trgm
      # similarity score. Will rank lowest among matches.
      :ok =
        Memory.remember_from_user(
          %{
            key: "preference",
            content: "session-scoped preference for diagnostic mode",
            type: "fact"
          },
          session_ctx
        )

      # Workspace-scope `preference` competing at the same label —
      # 5x "diagnostic" gives it the highest FTS rank, and the short
      # label keeps its lex_text trigram count low (highest pg_trgm
      # similarity). It dominates BOTH pools.
      :ok =
        Memory.remember_from_user(
          %{
            key: "preference",
            content: "diagnostic diagnostic diagnostic diagnostic diagnostic",
            type: "fact"
          },
          ws_ctx
        )

      # 11 filler workspace rows with deliberately long labels so
      # their lex_text trigram count is HIGHER than workspace_pref's
      # (lower pg_trgm similarity). With workspace_pref dominating
      # both FTS (5x diagnostic) and lex (shortest lex_text), its
      # combined RRF is top 1 — pre-fix it surfaces in top 3 even
      # though session_pref should have won the `preference` label.
      # Post-fix: per-pool precedence dedup filters workspace_pref
      # before the cap, session_pref is the only candidate at the
      # `preference` label, and the wrong winner is gone.
      Enum.each(1..11, fn i ->
        :ok =
          Memory.remember_from_user(
            %{
              key: "very_long_filler_label_for_padding_#{i}",
              content: "diagnostic mention",
              type: "fact"
            },
            ws_ctx
          )
      end)

      # Capture the workspace_pref row so the assertion can target it
      # by id rather than relying on a content marker (which would
      # itself increase the lex_text and shift workspace_pref's rank).
      [workspace_pref] =
        Ash.read!(JidoClaw.Memory.Fact)
        |> Enum.filter(fn f ->
          f.label == "preference" and f.scope_kind == :workspace
        end)

      results = Memory.recall("diagnostic", tool_context: session_ctx, limit: 3)
      preference_rows = Enum.filter(results, &(&1.key == "preference"))

      # The lower-precedence workspace_pref must never surface as the
      # winner for the `preference` label. Pre-fix: workspace_pref
      # dominates both FTS and lex pools, the cap excludes session_pref,
      # and final dedup picks workspace_pref → its content appears in
      # the result list. Post-fix: per-pool precedence dedup filters
      # workspace_pref before the cap; session_pref is the only
      # candidate at this label and the wrong winner is impossible.
      refute Enum.any?(preference_rows, fn r -> r.content == workspace_pref.content end)
    end
  end

  describe "hybrid search :by_precedence — direct candidate-set inspection" do
    test "lower-precedence sibling at the same label is excluded from the candidate set even when it ranks #1 in the pools",
         %{workspace: ws} do
      # Direct test of the per-pool precedence dedup contract: the
      # lower-precedence sibling at a contested label must not appear
      # in HybridSearchSql's result list under :by_precedence dedup,
      # even when its FTS/lex scores would put it at the top of every
      # pool.
      ws_ctx = %{tenant_id: "default", workspace_uuid: ws.id}
      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      :ok =
        Memory.remember_from_user(
          %{
            key: "preference",
            content: "session-scoped preference for diagnostic mode",
            type: "fact"
          },
          session_ctx
        )

      :ok =
        Memory.remember_from_user(
          %{
            key: "preference",
            content: "diagnostic diagnostic diagnostic diagnostic diagnostic",
            type: "fact"
          },
          ws_ctx
        )

      # Long filler labels — see the upstream test for the rationale.
      Enum.each(1..11, fn i ->
        :ok =
          Memory.remember_from_user(
            %{
              key: "very_long_filler_label_for_padding_#{i}",
              content: "diagnostic mention",
              type: "fact"
            },
            ws_ctx
          )
      end)

      [workspace_pref] =
        Ash.read!(JidoClaw.Memory.Fact)
        |> Enum.filter(fn f ->
          f.label == "preference" and f.scope_kind == :workspace
        end)

      # limit=3 → cap=12. Total matching = 13. Cap excludes 1 row
      # pre-fix; post-fix the per-pool dedup filters workspace_pref
      # before ranking so 12 ≤ cap and session_pref makes it through.
      ranked =
        JidoClaw.Memory.HybridSearchSql.run(%{
          tenant_id: "default",
          scope_chain: [{:session, session_id}, {:workspace, ws.id}],
          query: "diagnostic",
          query_embedding: nil,
          embedding_model: "voyage-4-large",
          limit: 3,
          dedup: :by_precedence,
          bitemporal: :current_truth
        })

      contents = Enum.map(ranked, & &1.fact.content)

      # The lower-precedence workspace_pref must never appear in the
      # ranked set under :by_precedence: per-pool precedence dedup
      # filters it before pool ranking, so it never enters `ranked`.
      refute Enum.any?(contents, &(&1 == workspace_pref.content))
    end
  end

  describe "source rank order (plan §3.13)" do
    test "imported_legacy outranks model_remember when scope_rank ties", %{
      workspace: ws
    } do
      ws_ctx = %{tenant_id: "default", workspace_uuid: ws.id}

      {:ok, legacy_row} =
        JidoClaw.Memory.Fact.import_legacy(%{
          tenant_id: "default",
          scope_kind: :workspace,
          workspace_id: ws.id,
          label: "preference",
          content: "imported-legacy-content",
          tags: ["fact"],
          trust_score: 0.5,
          import_hash: "legacy_#{System.unique_integer([:positive])}"
        })

      # Keep the legacy row in current-truth (`invalid_at` is in the
      # future) while making it invisible to the partial unique index
      # (`WHERE invalid_at IS NULL`) so a same-scope model row at the
      # same label can coexist.
      JidoClaw.Repo.query!(
        "UPDATE memory_facts SET invalid_at = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(legacy_row.id),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        ]
      )

      :ok =
        Memory.remember_from_model(
          %{key: "preference", content: "model-remember-content", type: "fact"},
          ws_ctx
        )

      results = Memory.recall("preference", tool_context: ws_ctx, limit: 5)
      preference_rows = Enum.filter(results, &(&1.key == "preference"))

      assert length(preference_rows) == 1
      assert hd(preference_rows).content == "imported-legacy-content"
    end

    test "scope precedence wins over source: imported_legacy at workspace vs model_remember at session",
         %{workspace: ws} do
      # End-to-end: closer-scope row wins regardless of source rank.
      # imported_legacy at the workspace scope is a higher-precedence
      # source than model_remember (per the new ordering), but the
      # session-scope model_remember row is at a closer scope, so it
      # wins by scope_rank. Source rank only matters when scope
      # precedence ties.
      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      # Workspace-scope row, pinned to :imported_legacy via direct write
      # (Memory.remember_* doesn't expose the source). Use a unique
      # import_hash so the legacy unique identity is satisfied.
      {:ok, _legacy} =
        JidoClaw.Memory.Fact.import_legacy(%{
          tenant_id: "default",
          scope_kind: :workspace,
          workspace_id: ws.id,
          label: "preference",
          content: "imported-legacy-content",
          tags: ["fact"],
          trust_score: 0.5,
          import_hash: "legacy_#{System.unique_integer([:positive])}"
        })

      # Session-scope :model_remember at the same label.
      :ok =
        JidoClaw.Memory.remember_from_model(
          %{key: "preference", content: "model-remember-content", type: "fact"},
          session_ctx
        )

      results = Memory.recall("content", tool_context: session_ctx, limit: 5)
      preference_rows = Enum.filter(results, &(&1.key == "preference"))

      assert length(preference_rows) == 1
      # Session scope wins by scope_rank — closer wins regardless of
      # the workspace row's higher source_rank.
      assert hd(preference_rows).content == "model-remember-content"
    end
  end

  describe "current_truth bitemporal" do
    test "future-dated valid_at rows are excluded from default recall", %{
      tool_context: tc
    } do
      :ok =
        Memory.remember_from_user(
          %{key: "current_today", content: "today_value", type: "fact"},
          tc
        )

      :ok =
        Memory.remember_from_user(
          %{key: "future_only", content: "future_value", type: "fact"},
          tc
        )

      future_fact =
        Ash.read!(JidoClaw.Memory.Fact)
        |> Enum.find(fn f -> f.label == "future_only" end)

      # Push the future_only row's valid_at one hour into the future.
      JidoClaw.Repo.query!(
        "UPDATE memory_facts SET valid_at = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(future_fact.id),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        ]
      )

      results = Memory.list_recent(tc, 10)
      keys = Enum.map(results, & &1.key)

      assert "current_today" in keys
      refute "future_only" in keys
    end

    test "rows with future invalid_at are still surfaced (currently valid)", %{
      tool_context: tc
    } do
      :ok =
        Memory.remember_from_user(
          %{key: "expires_soon", content: "still_valid", type: "fact"},
          tc
        )

      [fact] = Ash.read!(JidoClaw.Memory.Fact)

      # Set invalid_at to one hour from now — row is still currently
      # valid until then. expired_at stays nil so the row is the live
      # representation.
      JidoClaw.Repo.query!(
        "UPDATE memory_facts SET invalid_at = $2 WHERE id = $1",
        [
          Ecto.UUID.dump!(fact.id),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        ]
      )

      results = Memory.list_recent(tc, 10)
      assert Enum.any?(results, fn r -> r.key == "expires_soon" end)
    end
  end

  describe "bitemporal world_at" do
    test "returns a superseded fact at world_t inside its valid window", %{
      tool_context: tc
    } do
      :ok = Memory.remember_from_user(%{key: "mode", content: "v1", type: "fact"}, tc)
      [fact] = Ash.read!(Fact)

      t0 = DateTime.utc_now() |> DateTime.add(86_400, :second)
      half_day_later = DateTime.add(t0, 12 * 3600, :second)
      half_day_earlier = DateTime.add(t0, -12 * 3600, :second)

      # Hand-roll the bitemporal columns: this row represents the fact
      # that "v1 was the truth from a day ago up until t0".
      JidoClaw.Repo.query!(
        "UPDATE memory_facts SET valid_at = $2, invalid_at = $3, expired_at = $3 WHERE id = $1",
        [
          Ecto.UUID.dump!(fact.id),
          DateTime.add(t0, -86_400, :second),
          t0
        ]
      )

      # Inside the valid window — should be returned.
      results_inside =
        Memory.recall("v1",
          tool_context: tc,
          limit: 5,
          bitemporal: {:world_at, half_day_earlier}
        )

      assert Enum.any?(results_inside, fn r -> r.content == "v1" end)

      # After invalid_at — should NOT be returned.
      results_outside =
        Memory.recall("v1",
          tool_context: tc,
          limit: 5,
          bitemporal: {:world_at, half_day_later}
        )

      refute Enum.any?(results_outside, fn r -> r.content == "v1" end)
    end
  end

  describe "recency scope-chain dedup" do
    test "closer-scope row wins per label even when newer parent-scope row + noise would fill an Elixir-side overfetch buffer",
         %{workspace: ws} do
      # Old Elixir-side dedup over an overfetch buffer: T0 session row
      # is older than 10+ newer workspace rows; the buffer might not
      # contain the session row at all, so dedup picks the (newer)
      # workspace row at the same label. SQL-side dedup must always
      # keep the closer-scope row per label.
      ws_ctx = %{tenant_id: "default", workspace_uuid: ws.id}
      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      # Older session-scope `preference`.
      :ok =
        Memory.remember_from_user(
          %{key: "preference", content: "session_X", type: "fact"},
          session_ctx
        )

      # Noise pushes the session row out of any overfetch window of
      # `limit * chain_length` rows.
      Enum.each(1..15, fn i ->
        :ok =
          Memory.remember_from_user(
            %{key: "noise_#{i}", content: "row_#{i}", type: "fact"},
            ws_ctx
          )
      end)

      # Newer workspace-scope `preference` — would shadow the session
      # row under the old Elixir buffer.
      :ok =
        Memory.remember_from_user(
          %{key: "preference", content: "workspace_Y", type: "fact"},
          ws_ctx
        )

      # Limit large enough to include the surviving `preference` row.
      results = Memory.list_recent(session_ctx, 20)
      preference_rows = Enum.filter(results, &(&1.key == "preference"))

      assert length(preference_rows) == 1
      # SQL precedence cascade: session beats workspace for the same label.
      assert hd(preference_rows).content == "session_X"
    end

    test "session-scoped row wins over workspace-scoped row at same label", %{
      workspace: ws
    } do
      ws_ctx = %{tenant_id: "default", workspace_uuid: ws.id}

      :ok =
        Memory.remember_from_user(
          %{key: "preference", content: "X", type: "fact"},
          ws_ctx
        )

      session_id = create_session(ws)

      session_ctx = %{
        tenant_id: "default",
        workspace_uuid: ws.id,
        session_uuid: session_id
      }

      :ok =
        Memory.remember_from_user(
          %{key: "preference", content: "Y", type: "fact"},
          session_ctx
        )

      results = Memory.list_recent(session_ctx, 5)
      preference_rows = Enum.filter(results, &(&1.key == "preference"))

      assert length(preference_rows) == 1
      [row] = preference_rows
      # Closer scope wins — the session-scoped row's content is "Y".
      assert row.content == "Y"
    end
  end
end
