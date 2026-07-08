defmodule JidoClaw.FrontDoor do
  @moduledoc """
  The single shared front door (AR-2 §8/§14, Phase 3c): the one decision point
  every user turn passes through after the user message is recorded.

  `decide/2` runs AR-8 triage once (a fail-safe `JidoClaw.Triage.classify/2`
  call — never a spawned worker) and picks a route:

    * `{:inline, verdict}` — `talk` (incl. a triage failure degraded to `talk`):
      the turn stays on today's inline agent path, byte-for-byte unchanged.
    * `{:composer, {:ok, resp}}` — a `code`/`system`/`sketch` verdict whose composer
      run started; `resp.message` is the assistant ack. A `sketch` run is launched
      in a hard-isolated, per-prototype `.prototypes/<id>/` sandbox (AR-8b).
    * `{:composer, {:error, resp}}` — a `code`/`system`/`sketch` verdict whose run
      **failed to start**: a bounded error ack. **This is NOT a fall-through to the
      inline agent** (which has write/run/git tools) — a confident change verdict
      whose run won't start must not be silently handed to the mutation-capable chat
      agent (P1). A `sketch` whose sandbox can't be created (no `project_dir`, a
      hostile `.prototypes` symlink/shape) lands here too — never on the inline
      agent, which would write the real tree. The AR-8b-2 C2 **oscillation
      debounce** (a `sketch ⇄ code` flip-flop) also returns this tag with a "re-send
      to confirm" ack — no run is minted, and the re-send proceeds.
    * `{:clarify, resp}` — queue item 8 (OB1-1): an `ambiguous` `code`/`system`
      verdict on a `:loop` surface entered the bounded clarify loop instead of
      composing; `resp.message` is a question round / recap / hold / failure ack
      and **no run is minted**. The loop's durable state lives under
      `metadata["pending_clarify"]`; the next turn on a `:loop` surface continues
      it (answers fold in, the ask re-scores) until compose, override, pivot, cap,
      or TTL. `:one_shot` surfaces never see this tag — they compose immediately
      with degraded labeling. Mechanics: `JidoClaw.FrontDoor.Clarify` +
      `docs/system/ambiguity-clarify.md`.

  ## AR-8b-2 — cross-run sketch graduation (C1 + C2)

  When a session sketched a throwaway and a later turn becomes a `code`/`system`
  build, C1 seeds the fresh composer run with a **fresh LLM summary** of what the
  prototype established (the prototype *informs*, it does not auto-merge). The
  signal is a **durable candidate** under `metadata["pending_prototype"]` (written
  on a non-sensitive sketch launch, consumed on a relevant graduation), keyed by
  redacted topic-token overlap and a bounded TTL — so `last_triage_path` stays
  observability-only. A `:secrets` sketch writes **no** candidate (and clears any
  stale one), so a secret-involving throwaway never graduates and its topic never
  reaches public metadata. C2 debounces rapid path-flipping off a bounded
  `metadata["path_transitions"]` log; both guards **fail open** to a normal launch.

  This is the only **user-turn** caller of `RouteComposer.create_parent_run/1` /
  `ensure_started/2` (boot recovery, `workflow_recovery.ex`, also calls
  `ensure_started`). Stickiness is per-turn re-classification + recent history
  (faithful to Alp River): the prior path is observability/cold-start only, never
  read to decide — so a parked `talk` flips to `code` on "do it" because the fresh
  verdict sees the prior proposal + "do it" in the same prompt.

  ## `ctx`

  A plain map the turn seams build, carrying the turn's scope:
  `:tenant_id`, `:session_id`, `:session_uuid`, `:workspace_id`, `:workspace_uuid`,
  `:project_dir`, `:user_id`, `:actor`, `:agent_id`, `:agent_template`. Required for
  a composer launch: `:tenant_id` + an actor (falls back to `Actor.system/1`).
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Error
  alias JidoClaw.Forge
  alias JidoClaw.FrontDoor.Clarify
  alias JidoClaw.FrontDoor.Clarify.State, as: ClarifyState
  alias JidoClaw.FrontDoor.PrototypeSummary
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.Premises
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Telemetry
  alias JidoClaw.Trace
  alias JidoClaw.Triage
  alias JidoClaw.Triage.Verdict
  alias JidoClaw.VFS.Sandbox

  @history_window 6
  @preview_max 120
  @default_sensitive_deadline_ms 1_800_000

  # AR-8b-2 C2 oscillation guard: count adjacent sketch↔code/system flips inside
  # this window; debounce on the threshold-th flip (a single `sketch → code`
  # graduation is 1 flip and never debounced). C1 graduation candidate TTL is a
  # backstop — `relevant?/2` is the primary guard.
  @osc_window_ms 60_000
  @osc_flip_threshold 2
  @graduation_candidate_ttl_ms :timer.hours(2)

  # Topic-token extraction for C1 relevance. Drop generic function/process words
  # so only real topic words anchor relevance (biases toward NOT graduating — a
  # false negative degrades to a normal `code` run; a false positive would seed a
  # misleading summary). The marker denylist keeps redaction leftovers (`bearer`)
  # and secret-class words from ever becoming relevance anchors.
  @token_stopwords MapSet.new(~w(the a an and or but for nor yet with from into onto this that
                        these those your you our their there here what when where which
                        while will would should could able make made just like only also
                        then than them they have been being does done about over under
                        build sketch prototype throwaway implement create feature real
                        really thing stuff want need please code system change))

  @token_markers MapSet.new(~w(bearer redacted secret token password apikey anthropic github))

  # Verdict signal atom → composer topic string (the catalog's wire vocabulary).
  @signal_topics %{
    ambiguous: "ambiguous",
    bug: "bug",
    novel_domain: "novel-domain",
    multi_file: "multi-file",
    auth_surface: "auth-surface",
    secrets: "secrets",
    perms_change: "perms-change",
    destructive_op: "destructive-op",
    irreversible: "irreversible",
    needs_tests: "needs-tests",
    significant_build: "significant-build",
    scope_shift: "scope-shift"
  }

  @type ack :: %{path: Verdict.path(), parent_run_id: String.t(), message: String.t()}
  @type error_ack :: %{path: Verdict.path(), message: String.t()}
  @type clarify_ack :: %{path: Verdict.path(), message: String.t()}

  @doc """
  Triage the turn and route it. See the module doc for the four return tags.
  """
  @spec decide(String.t(), map()) ::
          {:inline, Verdict.t()}
          | {:composer, {:ok, ack()}}
          | {:composer, {:error, error_ack()}}
          | {:clarify, clarify_ack()}
  def decide(message, ctx) when is_binary(message) and is_map(ctx) do
    # Load the session ONCE (best-effort; nil ⇒ everything fails open) and thread
    # it to every reader/writer. All metadata writes are atomic `jsonb_set` on the
    # row, so snapshot staleness across sequential writes in one turn is irrelevant.
    session = load_session(ctx)

    # A live clarify loop intercepts the turn BEFORE triage — but only on a
    # `:loop` surface. A `:one_shot` surface NEVER continues a pending loop
    # (main cron reuses its session, `dispatcher.ex` — the next scheduled task
    # must not read as an answer): clear it loudly and run normal triage.
    # Expired/junk state lazily clears into normal triage too.
    case Clarify.load_pending(session, now()) do
      {:live, state} ->
        if clarify_surface(ctx) == :loop do
          continue_clarify(message, state, ctx, session)
        else
          clear_pending_stale(session, ctx, :one_shot_cleared)
          triage_and_route(message, ctx, session)
        end

      {:expired, _state} ->
        clear_pending_stale(session, ctx, :expired)
        triage_and_route(message, ctx, session)

      :none ->
        triage_and_route(message, ctx, session)
    end
  end

  # Today's decide/2 body, verbatim behavior for every non-clarify turn.
  defp triage_and_route(message, ctx, session) do
    history = recent_history(ctx, message)
    # classify/2 is the fail-safe boundary, so this hard-matches `{:ok, %Verdict{}}`.
    {:ok, %Verdict{} = verdict} = Triage.classify(message, history: history)

    # Cheap candidate read (no LLM): a non-expired, RELEVANT pending prototype on a
    # graduating `code`/`system` turn. Read here, but only HYDRATED (summarized)
    # after the oscillation guard returns `:proceed`.
    candidate = pending_graduation(message, verdict, session)
    # Observability only (last_triage_path); order-independent — atomic per-key.
    persist_path(ctx, verdict.path, session)

    if Verdict.composer?(verdict) do
      # P2: a `:secrets` sketch walls off cross-run graduation — clear any stale
      # candidate up front, BEFORE the guard, so neither a launch failure NOR a
      # debounce can let a prior non-sensitive prototype survive into a sensitive
      # context. (The new-candidate WRITE stays in start_composer's success branch.)
      clear_candidate_for_sensitive_sketch(verdict, session, ctx)

      if Clarify.trigger?(verdict) do
        clarify_lane(message, verdict, history, ctx, session, candidate)
      else
        standard_composer(message, verdict, ctx, session, candidate)
      end
    else
      # A talk turn clears the C2 "ask once" speed-bump.
      maybe_clear_marker(session, ctx)
      {:inline, verdict}
    end
  end

  # The pre-clarify composer branch, moved verbatim.
  defp standard_composer(message, verdict, ctx, session, candidate) do
    case oscillation_guard(session, verdict.path, ctx) do
      :proceed ->
        graduation = hydrate_graduation(candidate)
        result = start_composer(message, verdict, ctx, graduation, session)
        after_launch(result, verdict, ctx, session, graduation)
        {:composer, result}

      {:debounce, ack} ->
        # No launch, NO summary ⇒ candidate + transition log untouched, so the
        # confirming re-send still graduates.
        {:composer, {:error, ack}}
    end
  end

  # ---------------------------------------------------------------------------
  # Clarify lane (queue item 8 — OB1-1 + OR2-5)
  # ---------------------------------------------------------------------------

  # An `ambiguous` code/system verdict. A nil session (unloadable row) has
  # nowhere to persist the loop ⇒ fail open to today's composer; a `:one_shot`
  # surface composes immediately with degraded labeling; a `:loop` surface
  # opens the loop.
  defp clarify_lane(message, verdict, history, ctx, session, candidate) do
    cond do
      is_nil(session) ->
        standard_composer(message, verdict, ctx, session, candidate)

      clarify_surface(ctx) == :one_shot ->
        one_shot_clarify(message, verdict, history, ctx, session, candidate)

      true ->
        open_clarify(message, verdict, history, ctx, session, candidate)
    end
  end

  # The open turn: score once, persist the loop state, and only then show the
  # questions. The persist result is CHECKED (functional state — never
  # `safe_write/1`, front_door.ex's observability-key wrapper): a failed write
  # must not show questions the next turn can't correlate. Scorer or persist
  # failure ⇒ fail open to the standard composer path.
  defp open_clarify(message, verdict, history, ctx, session, candidate) do
    case Clarify.open(message, verdict, history, now()) do
      {:ok, state, ack} ->
        case persist_pending(session, ctx, ClarifyState.to_metadata(state)) do
          {:ok, _session} ->
            emit_clarify(:open, :ok)
            {:clarify, %{path: verdict.path, message: ack}}

          {:error, reason} ->
            Logger.warning(
              "[FrontDoor] clarify open persist failed (fail-open to composer): " <>
                Error.summarize_reason(reason)
            )

            emit_clarify(:open, :persist_failed)
            standard_composer(message, verdict, ctx, session, candidate)
        end

      {:error, reason} ->
        Logger.debug("[FrontDoor] clarify open scorer failed: #{Error.summarize_reason(reason)}")
        emit_clarify(:open, clarify_scorer_outcome(reason))
        standard_composer(message, verdict, ctx, session, candidate)
    end
  end

  # `:no_open_questions` is the decision layer's "non-qualifying score with
  # nothing left to ask" infra reason — a scorer contract violation,
  # distinguished in telemetry from a transport/shape failure.
  defp clarify_scorer_outcome(:no_open_questions), do: :empty_ledger
  defp clarify_scorer_outcome(_reason), do: :scorer_failed

  # Decision 5: unattended surfaces never park questions — one scorer call for
  # slots/score, then an immediate degraded compose; scorer failure composes
  # exactly as today.
  defp one_shot_clarify(message, verdict, history, ctx, session, candidate) do
    case Clarify.score_once_for_slots(message, verdict, history, now()) do
      {:ok, spec} ->
        compose_from_clarify(spec, ctx, session)

      {:error, reason} ->
        Logger.debug(
          "[FrontDoor] one-shot clarify scorer failed: #{Error.summarize_reason(reason)}"
        )

        emit_clarify(:open, clarify_scorer_outcome(reason))
        standard_composer(message, verdict, ctx, session, candidate)
    end
  end

  # A continue turn against live pending state. Directives that show another
  # ack persist first but SERVE THE ROUND even on a persist failure (stale
  # state self-heals — the next fold sees this message in history), loudly.
  defp continue_clarify(message, state, ctx, session) do
    history = recent_history(ctx, message)

    case Clarify.continue(state, message, history, now(), Clarify.round_cap()) do
      {:questions, new_state, ack} ->
        serve_round(:round, new_state, ack, ctx, session)

      {:hold, new_state, ack} ->
        serve_round(:hold, new_state, ack, ctx, session)

      {:failure, new_state, ack} ->
        serve_round(:scorer_failed, new_state, ack, ctx, session)

      {:compose, spec} ->
        compose_from_clarify(spec, ctx, session)

      :new_ask ->
        # The pivot escape: clear the loop and run the message through fresh
        # triage (which may itself open a NEW loop for the new ask).
        clear_pending_stale(session, ctx, :new_ask)
        triage_and_route(message, ctx, session)
    end
  end

  defp serve_round(event, %ClarifyState{} = new_state, ack, ctx, session) do
    case persist_pending(session, ctx, ClarifyState.to_metadata(new_state)) do
      {:ok, _session} ->
        emit_clarify(event, :ok)

      {:error, reason} ->
        Logger.warning(
          "[FrontDoor] clarify round persist failed (serving on stale state): " <>
            Error.summarize_reason(reason)
        )

        emit_clarify(event, :persist_failed)
    end

    {:clarify, %{path: new_state.verdict.path, message: ack}}
  end

  # Compose from a clarify spec. Item 9's lint gate runs FIRST: blockers (the
  # ledger-derived safety set) re-open a clarify round below the round cap
  # instead of composing; at cap / on one-shot the compose proceeds (#8's
  # semantics own the exit) and the plan gate's re-lint carries the warnings.
  defp compose_from_clarify(spec, ctx, session) do
    case Clarify.lint_gate(spec, now()) do
      {:compose, gated_spec, report} ->
        emit_premises_lint(report)
        launch_from_clarify(gated_spec, ctx, session)

      {:reopen, state, ack, report} ->
        emit_premises_lint(report)
        serve_round(:lint_block, state, ack, ctx, session)
    end
  end

  # `nil` = the one-shot skip (no clarify-side lint ran; the gate re-lint
  # still covers the premises-borne checks).
  defp emit_premises_lint(nil), do: :ok
  defp emit_premises_lint(%{grade: grade}), do: Telemetry.emit_premises_lint(grade, :clarify)

  # Launch from a (lint-cleared) clarify spec: `start_composer` FIRST; the
  # pending state is cleared ONLY on `{:ok, parent}` (the `consume_candidate`
  # precedent) — a launch failure keeps the loop live so the error ack's
  # re-send re-enters it and retries the compose. Cleanup failures never
  # prevent `after_launch/4`.
  defp launch_from_clarify(spec, ctx, session) do
    verdict = spec.verdict

    # Graduation is re-read + hydrated at COMPOSE time, relevance keyed off
    # the CLARIFIED intent (`verdict.intent`), never the confirm-turn message
    # — "yes, that's right" has no topic tokens and would false-negative a
    # relevant prototype.
    candidate = pending_graduation(spec.state.original_message, verdict, session)
    graduation = hydrate_graduation(candidate)
    clarify = %{premises: spec.premises, sensitive?: spec.sensitive?}

    case start_composer(spec.seed, verdict, ctx, graduation, session, clarify) do
      {:ok, _ack} = result ->
        clear_pending_after_launch(session, ctx)
        # A clarified compose bypasses the oscillation guard by design, but the
        # guard's proceed path is where the "ask once" marker normally clears —
        # clear it here (the same write) so a stale marker can't suppress a
        # later REAL debounce.
        maybe_clear_marker(session, ctx)
        after_launch(result, verdict, ctx, session, graduation)
        emit_clarify(:compose, compose_outcome(spec))
        {:composer, result}

      {:error, _error_ack} = result ->
        emit_clarify(:compose, :launch_failed)
        {:composer, result}
    end
  end

  defp compose_outcome(%{origin: :override}), do: :override
  defp compose_outcome(%{origin: :one_shot}), do: :one_shot_degraded
  defp compose_outcome(%{degraded?: true}), do: :degraded
  defp compose_outcome(_spec), do: :clean

  defp clarify_surface(ctx) do
    case Map.get(ctx, :clarify_surface) do
      :one_shot -> :one_shot
      _loop_or_absent -> :loop
    end
  end

  # Functional clarify-state writes: the Ash result is RETURNED (never
  # `safe_write/1`) — a swallowed failure here loses the loop, not an
  # observability key. Raises/exits normalize to `{:error, _}`.
  defp persist_pending(nil, _ctx, _payload), do: {:error, :no_session}

  defp persist_pending(session, ctx, payload) do
    ConversationsSession.set_pending_clarify(session, payload, write_opts(ctx))
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp clear_pending(session, ctx) do
    case persist_pending(session, ctx, nil) do
      {:ok, _session} -> :ok
      {:error, :no_session} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Lazy clears (expired / one-shot / pivot): loud on failure, never blocking.
  defp clear_pending_stale(session, ctx, event) do
    outcome =
      case clear_pending(session, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[FrontDoor] pending_clarify clear (#{event}) failed: " <>
              Error.summarize_reason(reason)
          )

          :clear_failed
      end

    emit_clarify(event, outcome)
    :ok
  end

  # A failed clear AFTER a successful launch is a loud, Trace'd, TTL-bounded
  # residual (the next turn would read the stale loop until it expires) —
  # documented in docs/system/ambiguity-clarify.md.
  defp clear_pending_after_launch(session, ctx) do
    case clear_pending(session, ctx) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[FrontDoor] pending_clarify clear failed after launch (TTL-bounded residual): " <>
            Error.summarize_reason(reason)
        )

        emit_clarify(:persist_failed, :clear_after_launch)
        :ok
    end
  end

  # One emission helper: the counter, the Trace guardrail event, and the
  # SignalBus signal (the `emit_oscillation/2` precedent).
  defp emit_clarify(event, outcome) do
    Telemetry.emit_clarify(event, outcome)

    Trace.emit(
      :guardrail,
      %{guardrail: "clarify", event: event, outcome: outcome},
      %{system_time: System.system_time()}
    )

    JidoClaw.SignalBus.emit("jido_claw.triage.clarify", %{
      event: to_string(event),
      outcome: to_string(outcome)
    })

    :ok
  end

  # P2: a `:secrets` sketch clears any stale `pending_prototype` regardless of whether
  # its own launch then succeeds, fails, or is debounced. (Replacing a candidate
  # otherwise only happens on a write, so a never-launched sensitive sketch must clear
  # explicitly.)
  defp clear_candidate_for_sensitive_sketch(
         %Verdict{path: :sketch, signals: signals},
         session,
         ctx
       ) do
    if :secrets in signals, do: write_pending_prototype(session, ctx, nil), else: :ok
  end

  defp clear_candidate_for_sensitive_sketch(_verdict, _session, _ctx), do: :ok

  # ---------------------------------------------------------------------------
  # Composer launch (the Option-A seed)
  # ---------------------------------------------------------------------------

  # The trailing `clarify` map (queue item 8) defaults empty so every
  # pre-clarify caller stays byte-identical: `:premises` merges LAST into
  # `build_premises/5` and `:sensitive?` ORs into `mark_sensitive/2` (answers
  # can introduce secrets AFTER triage's `:secrets` signal was decided).
  defp start_composer(message, %Verdict{} = verdict, ctx, graduation, session, clarify \\ %{}) do
    # The explicit launch decision (D7 Window 1): a `:sketch` turn resolves a
    # hard-isolated `.prototypes/<id>/` sandbox up front (AR-8b) and, when the
    # verdict carries `:must_execute`, ALSO mints a no-egress Forge Docker session
    # (the exec tier). A `code`/`system` turn passes the launch scope through
    # unchanged. A prototype-dir failure is `{:error, _}` → the bounded ack —
    # NEVER a pass-through to the mutation-capable inline agent (P1c).
    case sketch_scope(verdict, ctx) do
      {:error, reason} ->
        composer_launch_error(verdict.path, reason)

      launch ->
        finish_launch(launch, message, verdict, ctx, session, graduation, clarify)
    end
  end

  defp finish_launch(launch, message, %Verdict{} = verdict, ctx, session, graduation, clarify) do
    # `intent` is load-bearing AND must be non-empty: `planner` requires the
    # `intent` artifact and the router's availability is key-presence based, so a
    # blank/nil intent would falsely satisfy the requirement and run `planner`
    # blind. Use the verdict's crisp intent when present, else the raw message.
    # C1 appends the prototype summary (the verdict intent stays leading +
    # load-bearing); a `nil` summary leaves it byte-identical.
    base_intent = present(verdict.intent) || message
    intent = graduated_intent(base_intent, graduation)
    path = verdict.path
    sensitive? = :secrets in verdict.signals or Map.get(clarify, :sensitive?, false)
    {project_dir, workspace_id} = launch_scope(launch)
    premises_extra = launch_premises(launch)
    forge_key = launch_forge_key(launch)

    # `:secrets` ∈ signals → mark_sensitive/2 merges sanitize + a bounded deadline
    # (a direct call, not a one-step pipe — SinglePipe).
    opts =
      mark_sensitive(
        [
          tenant: Map.fetch!(ctx, :tenant_id),
          actor: actor(ctx),
          name: "composer",
          catalog: Catalog.all(),
          live: seed_live(launch, verdict),
          # FULL intent stored in the artifact; the ack shows a capped preview.
          artifacts: %{"request" => %{"seed" => message}, "intent" => %{"triage" => intent}},
          # Option (A): seed `triage` as already-run so the composer never asks
          # WaveBuilder to build the non-executable `{:seed, _}` stage.
          ran: ["triage"],
          # `forge_session_key` (D5) rides the persisted CONTEXT (the worker-scope /
          # restart / teardown home), NOT premises (summary-label-only).
          context: composer_context(ctx, project_dir, workspace_id, forge_key),
          # Front-door launch cleans its own orphan (boot recovery does not — 3b).
          terminalize_on_failure?: true,
          # prototype_id/dir ride premises for Phase C (AR-8b-2) provenance;
          # `graduated_from` (C1) is folded in even when the summary is nil.
          premises:
            build_premises(path, verdict, premises_extra, graduation, clarify_premises(clarify))
        ],
        sensitive?
      )

    case guarded_launch(opts, forge_key) do
      {:ok, parent} ->
        # Write the candidate only for a successful NON-SENSITIVE sketch; a
        # sensitive sketch already cleared any stale one in `decide/2`; no-op for
        # code/system.
        set_sketch_candidate(path, sensitive?, parent, premises_extra, base_intent, ctx, session)

        {:ok,
         %{
           path: path,
           parent_run_id: parent.id,
           message: launch_ack(launch, path, intent, parent.id, sensitive?)
         }}

      {:error, reason} ->
        composer_launch_error(path, reason)
    end
  end

  # Window 1b (D7): the front door owns Forge cleanup from session-creation until
  # `ensure_started/2` returns `{:ok, _}`. If a composer-launch step then fails
  # while an exec session is live, tear it down (`:cancelled` — the session WAS
  # aborted) BEFORE surfacing the bounded error, because the composer's terminal
  # teardown never runs (the composer never started). A non-exec launch has no
  # `forge_key` → the teardown no-ops. After `ensure_started` succeeds, the
  # composer's terminal hook (5.6) owns teardown.
  defp guarded_launch(opts, forge_key) do
    with {:ok, parent} <- composer().create_parent_run(opts),
         {:ok, _pid} <- composer().ensure_started(opts, parent) do
      {:ok, parent}
    else
      {:error, reason} ->
        teardown_forge_session(forge_key)
        {:error, reason}
    end
  end

  defp teardown_forge_session(forge_key) when is_binary(forge_key) and forge_key != "" do
    forge().stop_session(forge_key)
    :ok
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp teardown_forge_session(_forge_key), do: :ok

  # P1 SAFETY: a confident code/system (or sketch) verdict whose run won't start
  # does NOT fall through to the mutation-capable inline agent. The ack is a
  # SHORT, STABLE string (this path bypasses the tool redaction/shaping pipeline,
  # so never `inspect(reason)` into it); the detail is logged via a SUMMARIZED
  # (payload-dropping) reason — the global LogRedactor is belt-and-suspenders.
  defp composer_launch_error(path, reason) do
    Logger.warning("[FrontDoor] composer launch failed: #{Error.summarize_reason(reason)}")

    {:error,
     %{
       path: path,
       message:
         "I classified this as a #{path} change but couldn't start the run " <>
           "(it's been logged). It was not run through the chat agent — please retry."
     }}
  end

  # Map the verdict's early signals to composer topics, intersected with the
  # `triage` stage's declared `publishes` so the seeded emission is coherent with
  # its catalog contract.
  defp mapped_signals(%Verdict{signals: signals}) do
    publishes = MapSet.new(Catalog.get("triage").publishes)

    signals
    |> Enum.map(&Map.get(@signal_topics, &1))
    |> Enum.filter(fn topic -> not is_nil(topic) and MapSet.member?(publishes, topic) end)
  end

  # The atom-keyed scope subset the composer threads into every wave (and persists
  # JSON-safe for recovery). Nils dropped so the persisted subset stays clean.
  # `project_dir`/`workspace_id` are passed in (resolved by `sketch_scope/2`): the
  # ctx values for code/system, the per-prototype `.prototypes/<id>/` + scoped id
  # for sketch. Both persist via `@persisted_context_keys` so the sandbox survives
  # crash recovery. `workspace_id` is included — `AgentRunner` otherwise falls back
  # to `"wf_<tag>"`.
  defp composer_context(ctx, project_dir, workspace_id, forge_key) do
    %{
      project_dir: project_dir,
      tenant_id: Map.get(ctx, :tenant_id),
      session_id: Map.get(ctx, :session_id),
      session_uuid: Map.get(ctx, :session_uuid),
      workspace_id: workspace_id,
      workspace_uuid: Map.get(ctx, :workspace_uuid),
      user_id: Map.get(ctx, :user_id),
      agent_id: Map.get(ctx, :agent_id),
      agent_template: Map.get(ctx, :agent_template),
      # AR-8b-2 F2 (D5): the Forge session handle for the jailed exec worker
      # (nil-rejected, so non-exec runs are unchanged). Persisted via
      # `@persisted_context_keys` so it survives restart and reaches
      # `resolve_scope/2` → `apply_visibility {:only, [:forge_session_key]}` → the
      # worker's `tool_context`.
      forge_session_key: forge_key
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Resolve the launch decision for a turn (D7 Window 1). A `:sketch` turn creates
  # a hard-isolated `.prototypes/<id>/` sandbox (symlink-safe + validated by
  # `VFS.Sandbox`); a missing `project_dir` or hostile shape surfaces as
  # `{:error, _}` → the bounded ack (NOT a pass-through). On a `:must_execute`
  # sketch it ALSO mints a no-egress Forge Docker session; the explicit outcome
  # is `{:exec, scope, premises, forge_key}` (session ready) /
  # `{:plain_degraded, scope, premises, notice}` (exec setup failed → file-only +
  # notice) / `{:plain, scope, premises}` (ordinary sketch or `code`/`system`).
  defp sketch_scope(%Verdict{path: :sketch} = verdict, ctx) do
    case Sandbox.create_prototype_dir(Map.get(ctx, :project_dir)) do
      {:ok, %{dir: proto, id: id}} ->
        ws = sketch_workspace_id(Map.get(ctx, :workspace_id), id)
        premises_extra = %{"prototype_id" => id, "prototype_dir" => proto}
        decide_sketch_launch(verdict, proto, ws, premises_extra, ctx)

      {:error, reason} ->
        {:error, {:sketch_sandbox_unavailable, reason}}
    end
  end

  defp sketch_scope(_verdict, ctx),
    do: {:plain, {Map.get(ctx, :project_dir), Map.get(ctx, :workspace_id)}, %{}}

  # `:must_execute` → attempt the exec launch; otherwise a plain (file-only)
  # sketch. The verdict still says `:must_execute` even on the degraded path, so
  # the launch decision must be a first-class value — never re-derived downstream.
  defp decide_sketch_launch(%Verdict{signals: signals}, proto, ws, premises_extra, ctx) do
    if :must_execute in signals do
      attempt_exec_launch(proto, ws, premises_extra, ctx)
    else
      {:plain, {proto, ws}, premises_extra}
    end
  end

  # Mint the no-egress, globally-unmounted Docker session at the front door. A
  # missing real `workspace_uuid` (a `Session.workspace_id` is `:uuid`
  # non-nullable, and the synthetic `<ws>:proto:<id>` would fail the cast) ⇒ the
  # tier cannot persist a session ⇒ degrade. `start_session_ready/3` tears down
  # any partial session on failure, so a degrade leaks nothing.
  defp attempt_exec_launch(proto, ws, premises_extra, ctx) do
    case Map.get(ctx, :workspace_uuid) do
      uuid when is_binary(uuid) and uuid != "" ->
        # A FRESH bare UUID — never a `sketch:<id>` prefix (the Forge
        # `Session.name` invariant holds every name source is a fresh UUID).
        forge_key = Ash.UUID.generate()

        case forge().start_session_ready(forge_key, forge_exec_spec(proto, ctx, uuid)) do
          {:ok, ^forge_key} -> {:exec, {proto, ws}, premises_extra, forge_key}
          _error -> {:plain_degraded, {proto, ws}, premises_extra, exec_unavailable_notice()}
        end

      _ ->
        {:plain_degraded, {proto, ws}, premises_extra, exec_unavailable_notice()}
    end
  end

  # The Forge start spec (5.2): the backend is selected by the TOP-LEVEL `:sandbox`
  # atom (`:docker_sandbox` — distinct from the `:docker` POLICY atom), the knobs
  # live in the NESTED `:sandbox_spec` (1.5/1.6: a JSON-safe map mount, the
  # `--workdir`, the no-egress request, and the global-config opt-out).
  # Same-path (sbx 0.34.0): the proto dir mounts in-VM at its own host path —
  # container remapping is inexpressible — so workdir and the mount agree.
  # `workspace_uuid` is the REAL UUID (never the synthetic id — `scope_from_spec/1`
  # would fail to cast it); the synthetic id stays in `composer_context` only.
  defp forge_exec_spec(proto_dir, ctx, workspace_uuid) do
    %{
      sandbox: :docker_sandbox,
      sandbox_spec: %{
        extra_mounts: [%{"host" => proto_dir, "container" => proto_dir, "mode" => "rw"}],
        workdir: proto_dir,
        network: :none,
        isolate_global_config: true
      },
      runner: :shell,
      tenant_id: Map.get(ctx, :tenant_id),
      workspace_uuid: workspace_uuid
    }
  end

  defp exec_unavailable_notice,
    do: "Execution wasn't available, so this is a file-only sketch (it was not run)."

  # Launch-outcome accessors (the launch decision is a first-class value).
  defp launch_scope({:exec, scope, _premises, _key}), do: scope
  defp launch_scope({:plain_degraded, scope, _premises, _notice}), do: scope
  defp launch_scope({:plain, scope, _premises}), do: scope

  defp launch_premises({:exec, _scope, premises, _key}), do: premises
  defp launch_premises({:plain_degraded, _scope, premises, _notice}), do: premises
  defp launch_premises({:plain, _scope, premises}), do: premises

  defp launch_forge_key({:exec, _scope, _premises, key}), do: key
  defp launch_forge_key(_launch), do: nil

  # On a degraded exec sketch, surface the notice in the ack so a silent file-only
  # sketch isn't mistaken for a run.
  defp launch_ack({:plain_degraded, _scope, _premises, notice}, path, intent, run_id, sensitive?),
    do: notice <> " " <> ack_message(path, intent, run_id, sensitive?)

  defp launch_ack(_launch, path, intent, run_id, sensitive?),
    do: ack_message(path, intent, run_id, sensitive?)

  defp sketch_workspace_id(ws, id) when is_binary(ws) and ws != "", do: ws <> ":proto:" <> id
  defp sketch_workspace_id(_ws, id), do: "proto:" <> id

  # The seeded `live` topics, launch-outcome-aware (D4-B). A sketch seeds the
  # `"sketch"` path signal (without a live path the router skips route filtering)
  # plus EXACTLY ONE discriminator — `"must-execute"` for `:exec`, `"sketch-plain"`
  # for any sketch that isn't exec (`:plain_degraded` or a plain `:plain` sketch).
  # The `++ mapped_signals/1` tail is safe ONLY because neither discriminator is
  # in `@signal_topics` (Part 4), so `mapped_signals` never re-injects either. A
  # `code`/`system` run always seeds exactly ONE planning topic — `multi-plan`
  # when the verdict arms (AR-9), else `plan-needed` (triage's catalog publish
  # that `planner` subscribes — without one the route is empty and falsely
  # converges). Neither planning topic is in `@signal_topics`, so the choice is
  # made HERE only, never re-injected via the signals list.
  defp seed_live({:exec, _scope, _premises, _key}, verdict),
    do: sketch_seed("must-execute", verdict)

  defp seed_live({:plain_degraded, _scope, _premises, _notice}, verdict),
    do: sketch_seed("sketch-plain", verdict)

  defp seed_live({:plain, _scope, _premises}, %Verdict{path: :sketch} = verdict),
    do: sketch_seed("sketch-plain", verdict)

  defp seed_live({:plain, _scope, _premises}, %Verdict{path: path} = verdict),
    do:
      Enum.uniq(
        ["request-received", to_string(path), planning_seed(verdict)] ++ mapped_signals(verdict)
      )

  defp planning_seed(verdict), do: if(armed?(verdict), do: "multi-plan", else: "plan-needed")

  # The ONE place arming is decided (AR-9): the triage judgment (`multi_plan?`)
  # in conjunction with the `significant-build` early signal — triage-only, no
  # config kill-switch. Armed runs seed `multi-plan` INSTEAD OF `plan-needed`.
  defp armed?(%Verdict{multi_plan?: true, signals: signals}), do: :significant_build in signals
  defp armed?(_verdict), do: false

  defp sketch_seed(discriminator, verdict),
    do: Enum.uniq(["request-received", "sketch", discriminator] ++ mapped_signals(verdict))

  defp actor(ctx) do
    Map.get(ctx, :actor) || Actor.system(Map.fetch!(ctx, :tenant_id))
  end

  # The composer launcher, behind a seam (the `:ask_runtime` idiom) so a test can
  # force a `create_parent_run` / `ensure_started` failure and assert the front
  # door's bounded error ack + P1 no-fall-through, without a real composer.
  defp composer, do: Application.get_env(:jido_claw, :front_door_composer, RouteComposer)

  # The Forge facade, behind the SAME app-env key the bridge uses (AR-8b-2 F2
  # 5.0), so a test drives the exec-launch decision + Window-1b teardown via
  # `JidoClaw.Test.ForgeStub` without a live microVM.
  defp forge, do: Application.get_env(:jido_claw, :forge_facade, Forge)

  # ---------------------------------------------------------------------------
  # Recent history + stickiness persistence
  # ---------------------------------------------------------------------------

  # The current user message is already persisted (the seam adds it before
  # `decide/2`), so bound to the last few turns first, then drop the trailing dup;
  # `Prompt.user` re-appends the current turn last.
  defp recent_history(ctx, message) do
    ctx
    |> safe_get_messages()
    |> Enum.take(-(@history_window + 1))
    |> drop_trailing_current(message)
  end

  defp safe_get_messages(ctx) do
    with tenant when is_binary(tenant) <- Map.get(ctx, :tenant_id),
         session_id when is_binary(session_id) <- Map.get(ctx, :session_id) do
      SessionWorker.get_messages(tenant, session_id)
    else
      _ -> []
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp drop_trailing_current(history, message) do
    case Enum.reverse(history) do
      [%{role: "user", content: ^message} | rest] -> Enum.reverse(rest)
      _other -> history
    end
  end

  # Load the session struct once per turn (best-effort). A `nil` makes every
  # reader/writer below fail open.
  defp load_session(ctx) do
    with sid when is_binary(sid) <- Map.get(ctx, :session_uuid),
         tenant when is_binary(tenant) <- Map.get(ctx, :tenant_id),
         {:ok, session} <- ConversationsSession.by_id(sid, tenant: tenant, actor: actor(ctx)) do
      session
    else
      _ -> nil
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Best-effort observability / cold-start: store the latest verdict path under
  # `metadata["last_triage_path"]` as a STRING (NOT read to decide — graduation
  # keys off the durable `pending_prototype` candidate). Never fails the turn.
  defp persist_path(_ctx, _path, nil), do: :ok

  defp persist_path(ctx, path, session),
    do:
      safe_write(fn ->
        ConversationsSession.set_triage_path(session, to_string(path), write_opts(ctx))
      end)

  # Every metadata write is best-effort + atomic (`jsonb_set` on the row), so a
  # stale snapshot can't clobber a sibling key and a failure never blocks the
  # turn. One wrapper centralizes the fail-open (no clone-sibling rescues).
  defp safe_write(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp write_opts(ctx), do: [tenant: Map.get(ctx, :tenant_id), actor: actor(ctx)]

  # ---------------------------------------------------------------------------
  # C1 — prototype provenance (durable candidate → relevance-gated graduation)
  # ---------------------------------------------------------------------------

  # Cheap, NO-LLM read: a non-expired, topically-relevant pending prototype on a
  # graduating `code`/`system` turn. Returns the raw (string-keyed) candidate map
  # or nil. Fail-open to nil on any read failure.
  defp pending_graduation(message, %Verdict{path: path} = verdict, session)
       when path in [:code, :system] do
    with %{} = cand <- candidate(session),
         true <- fresh?(cand),
         tokens = significant_tokens(present(verdict.intent) || message),
         true <- relevant?(cand, tokens) do
      cand
    else
      _ -> nil
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp pending_graduation(_message, _verdict, _session), do: nil

  defp candidate(%{metadata: %{"pending_prototype" => %{} = cand}}), do: cand
  defp candidate(_session), do: nil

  # TTL backstop (relevance is the primary guard). Reuses the within-window clock
  # seam so tests can drive expiry deterministically.
  defp fresh?(%{"at" => at}), do: within_window?(at, graduation_ttl_ms())
  defp fresh?(_cand), do: false

  # Conservative token-overlap relevance: a non-empty intersection of the stored
  # (redacted) sketch tokens and the graduating intent's tokens. Empty/nil intent
  # ⇒ no tokens ⇒ not relevant (safe).
  defp relevant?(%{"sketch_tokens" => stored}, intent_tokens)
       when is_list(stored) and is_list(intent_tokens) do
    not MapSet.disjoint?(MapSet.new(stored), MapSet.new(intent_tokens))
  end

  defp relevant?(_cand, _intent_tokens), do: false

  # Redact → strip `[REDACTED:…]` placeholder spans → downcase → tokenize → drop
  # short/stopword/marker tokens → sorted-unique LIST (JSON-safe; never a MapSet
  # — `SetMetadataKey` runs `Jason.encode!/1`). Redaction runs FIRST (case-
  # sensitive key patterns) and also scrubs any secret out of the stored tokens.
  defp significant_tokens(text) when is_binary(text) do
    text
    |> Patterns.redact()
    |> strip_redaction_placeholders()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&significant_token?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp significant_tokens(_text), do: []

  defp strip_redaction_placeholders(text),
    do: Regex.replace(~r/\[REDACTED[^\]]*\]/, text, " ")

  defp significant_token?(token) do
    String.length(token) >= 4 and
      not MapSet.member?(@token_stopwords, token) and
      not MapSet.member?(@token_markers, token)
  end

  # The LLM summary — called ONLY on a real launch (the `:proceed` branch), so a
  # debounced turn never summarizes. `run_id` is preserved through hydration (→
  # `graduated_from`); `summary` is independent of provenance (stashed even nil).
  defp hydrate_graduation(nil), do: nil

  defp hydrate_graduation(%{} = cand) do
    dir = cand["prototype_dir"]

    summary =
      case PrototypeSummary.summarize(dir) do
        {:ok, text} -> text
        _ -> nil
      end

    %{
      prototype_id: cand["prototype_id"],
      prototype_dir: dir,
      run_id: cand["run_id"],
      summary: summary
    }
  end

  # Append the summary to the (leading, load-bearing) verdict intent. A nil
  # summary leaves the seed byte-identical.
  defp graduated_intent(base_intent, %{summary: summary}) when is_binary(summary) do
    base_intent <>
      "\n\nPrior exploration (a throwaway sketch, NOT to be merged) found: " <> summary
  end

  defp graduated_intent(base_intent, _graduation), do: base_intent

  # Clarify premises merge LAST (`Map.merge(m, %{})` keeps every pre-clarify
  # caller byte-identical). Triage-extracted criteria merge BEFORE the clarify
  # keys — a clarify loop's richer criteria win — and the whole map exits
  # through the typed-key write boundary (`Premises.normalize/1`, fail-open).
  defp build_premises(path, %Verdict{} = verdict, premises_extra, graduation, clarify_premises) do
    %{"path" => to_string(path), "est_size" => to_string(verdict.est_size)}
    |> Map.merge(premises_extra)
    |> merge_triage_criteria(verdict)
    |> merge_graduated_from(graduation)
    |> Map.merge(clarify_premises)
    |> Premises.normalize()
  end

  defp merge_triage_criteria(premises, %Verdict{acceptance_criteria: criteria})
       when is_list(criteria) and criteria != [] do
    Map.put(premises, "acceptance_criteria", criteria)
  end

  defp merge_triage_criteria(premises, _verdict), do: premises

  defp clarify_premises(%{premises: %{} = premises}), do: premises
  defp clarify_premises(_clarify), do: %{}

  defp merge_graduated_from(premises, %{prototype_id: id, prototype_dir: dir, run_id: run_id}) do
    Map.put(premises, "graduated_from", %{
      "prototype_id" => id,
      "prototype_dir" => dir,
      "run_id" => run_id
    })
  end

  defp merge_graduated_from(premises, _graduation), do: premises

  # On a successful NON-SENSITIVE sketch launch, WRITE the durable graduation
  # candidate. A `:secrets` sketch already cleared any stale one eagerly in
  # `decide/2`, so it falls to the catch-all here; code/system are a no-op too.
  defp set_sketch_candidate(
         :sketch,
         false,
         parent,
         %{"prototype_id" => id, "prototype_dir" => dir},
         intent,
         ctx,
         session
       ) do
    candidate = %{
      "prototype_id" => id,
      "prototype_dir" => dir,
      "run_id" => parent.id,
      "sketch_tokens" => significant_tokens(intent),
      "at" => iso_now()
    }

    write_pending_prototype(session, ctx, candidate)
  end

  defp set_sketch_candidate(_path, _sensitive?, _parent, _extra, _intent, _ctx, _session), do: :ok

  defp write_pending_prototype(nil, _ctx, _candidate), do: :ok

  defp write_pending_prototype(session, ctx, candidate),
    do:
      safe_write(fn ->
        ConversationsSession.set_pending_prototype(session, candidate, write_opts(ctx))
      end)

  # ---------------------------------------------------------------------------
  # Post-launch bookkeeping (C2 transition log + C1 candidate consume)
  # ---------------------------------------------------------------------------

  defp after_launch(result, %Verdict{} = verdict, ctx, session, graduation) do
    record_transition(result, verdict, ctx, session)
    consume_candidate(result, verdict, graduation, ctx, session)
    :ok
  end

  # A transition = a composer run that actually started (any path). The log holds
  # `%{"path", "at"}` only — NO run_id, keeping a sensitive launch's run id out of
  # public metadata (the flip-count guard needs nothing more).
  defp record_transition({:ok, _ack}, %Verdict{path: path}, ctx, session),
    do: append_transition(session, ctx, to_string(path))

  defp record_transition(_result, _verdict, _ctx, _session), do: :ok

  defp append_transition(nil, _ctx, _path), do: :ok

  defp append_transition(session, ctx, path) do
    entry = %{"path" => path, "at" => iso_now()}
    transitions = Enum.take([entry | existing_transitions(session)], @history_window)

    safe_write(fn ->
      ConversationsSession.set_path_transitions(session, transitions, write_opts(ctx))
    end)
  end

  defp existing_transitions(%{metadata: %{"path_transitions" => list}}) when is_list(list),
    do: list

  defp existing_transitions(_session), do: []

  # Single-use: consume the candidate only on a successful code/system launch that
  # actually graduated. An unrelated `code` turn (no graduation) leaves it for a
  # later relevant turn (TTL-bounded).
  defp consume_candidate({:ok, _ack}, %Verdict{path: path}, %{} = _graduation, ctx, session)
       when path in [:code, :system],
       do: write_pending_prototype(session, ctx, nil)

  defp consume_candidate(_result, _verdict, _graduation, _ctx, _session), do: :ok

  # ---------------------------------------------------------------------------
  # C2 — oscillation guard
  # ---------------------------------------------------------------------------

  # `:proceed | {:debounce, error_ack}`, fail-open to `:proceed`. "Ask once, then
  # proceed" (B1): a recent marker means this turn IS the confirming re-send —
  # proceed and consume the marker. Otherwise debounce on a thrash and set it.
  defp oscillation_guard(session, path, ctx) do
    cond do
      recently_prompted?(session) ->
        write_marker(session, ctx, nil)
        :proceed

      thrash?(session, path) ->
        write_marker(session, ctx, iso_now())
        emit_oscillation(path, session)
        {:debounce, debounce_ack(path)}

      true ->
        :proceed
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :proceed
  catch
    :exit, _ -> :proceed
  end

  defp recently_prompted?(%{metadata: %{"oscillation_prompted_at" => at}}) when is_binary(at),
    do: within_window?(at, @osc_window_ms)

  defp recently_prompted?(_session), do: false

  # Build the in-window path sequence (current first) and count adjacent
  # sketch↔code/system flips.
  defp thrash?(session, current_path) do
    flips([to_string(current_path) | in_window_paths(session)]) >= @osc_flip_threshold
  end

  defp in_window_paths(%{metadata: %{"path_transitions" => list}}) when is_list(list) do
    list
    |> Enum.filter(&transition_in_window?/1)
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
  end

  defp in_window_paths(_session), do: []

  defp transition_in_window?(%{"at" => at}), do: within_window?(at, @osc_window_ms)
  defp transition_in_window?(_entry), do: false

  # Pure (unit-testable): count adjacent flips across the sketch/non-sketch
  # boundary. `sketch → code` is 1 flip (a normal graduation — never debounced);
  # `sketch → code → sketch` is 2 (the first flip-back trips it).
  defp flips(paths) do
    paths
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> flip?(a, b) end)
  end

  defp flip?(a, b), do: sketch?(a) != sketch?(b)

  defp sketch?("sketch"), do: true
  defp sketch?(_path), do: false

  defp within_window?(iso, window_ms) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.diff(now(), dt, :millisecond) <= window_ms
      _ -> false
    end
  end

  defp within_window?(_iso, _window_ms), do: false

  defp maybe_clear_marker(nil, _ctx), do: :ok

  defp maybe_clear_marker(session, ctx) do
    if marker_present?(session), do: write_marker(session, ctx, nil), else: :ok
  end

  defp marker_present?(%{metadata: %{"oscillation_prompted_at" => at}}) when is_binary(at),
    do: true

  defp marker_present?(_session), do: false

  defp write_marker(nil, _ctx, _at), do: :ok

  defp write_marker(session, ctx, at),
    do:
      safe_write(fn ->
        ConversationsSession.set_oscillation_marker(session, at, write_opts(ctx))
      end)

  # No silent suppression: a debounce always emits telemetry + a signal (mirrors
  # `triage.classified`).
  defp emit_oscillation(path, session) do
    prior = last_composer_path(session)

    :telemetry.execute(
      [:jido_claw, :triage, :oscillation_guard],
      %{count: 1},
      %{path: path, prior: prior, reason: :debounce}
    )

    JidoClaw.SignalBus.emit("jido_claw.triage.oscillation_guard", %{
      path: to_string(path),
      prior: to_string(prior),
      reason: "debounce"
    })

    :ok
  end

  defp last_composer_path(%{metadata: %{"path_transitions" => [%{"path" => p} | _rest]}})
       when is_binary(p),
       do: p

  defp last_composer_path(_session), do: nil

  defp debounce_ack(path) do
    %{
      path: path,
      message:
        "You've flipped between sketch and #{path} a couple of times just now. " <>
          "Re-send to start the #{path} run, or say 'just sketch it' to stay in the sandbox."
    }
  end

  # Clock seam (deterministic tests; mirrors the `:ask_runtime` idiom).
  defp now, do: clock().utc_now()
  defp clock, do: Application.get_env(:jido_claw, :front_door_clock, DateTime)
  defp iso_now, do: DateTime.to_iso8601(now())

  defp graduation_ttl_ms,
    do:
      Application.get_env(:jido_claw, :graduation_candidate_ttl_ms, @graduation_candidate_ttl_ms)

  # ---------------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------------

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

  defp preview(text) do
    case String.slice(text, 0, @preview_max) do
      ^text -> text
      sliced -> sliced <> "…"
    end
  end

  # `:secrets` ∈ signals → mark sensitive + a bounded deadline. The scrubber then
  # redacts derived plaintext in every durable sink and the deadline caps secret-state
  # lifetime — now including PARKED (gate-awaiting) time (O-M2): a marked run's gate
  # park is time-boxed by a `RouteComposer` deadline timer that auto-abandons it, so a
  # `:secrets` run can no longer outlive this bound waiting on a human. `create_parent_run`
  # rejects a marked run with no positive `:deadline_ms` (validate_sensitive_deadline/2),
  # so both are set together; a non-secrets run is returned unchanged (unmarked, unbounded
  # — today's behavior, and its gate park waits indefinitely by design).
  defp mark_sensitive(opts, true),
    do:
      Keyword.merge(opts, sanitize_sensitive_context: true, deadline_ms: sensitive_deadline_ms())

  defp mark_sensitive(opts, false), do: opts

  defp sensitive_deadline_ms do
    Application.get_env(:jido_claw, :triage_sensitive_deadline_ms, @default_sensitive_deadline_ms)
  end

  # A sketch run is throwaway and lands in `.prototypes/` — its ack says so. The
  # sensitive clause (like the generic one below) still omits the intent preview.
  defp ack_message(:sketch, _intent, run_id, true),
    do: "Sketching a sensitive throwaway prototype in .prototypes/ (run #{run_id})."

  defp ack_message(:sketch, intent, run_id, false),
    do: "Sketching a throwaway prototype in .prototypes/ for: #{preview(intent)} (run #{run_id})."

  # A sensitive run's ack must NOT echo the intent: marking the run sensitive scrubs
  # durable sinks, but the ack string itself bypasses that pipeline and goes straight
  # to the surface, so a secret-bearing intent could leak through preview/1.
  defp ack_message(path, _intent, run_id, true),
    do: "Starting a sensitive #{path} run (run #{run_id})."

  defp ack_message(path, intent, run_id, false),
    do: "Starting a #{path} run for: #{preview(intent)} (run #{run_id})."
end
