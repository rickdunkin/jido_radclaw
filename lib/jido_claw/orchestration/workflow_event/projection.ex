defmodule JidoClaw.Orchestration.WorkflowEvent.Projection do
  @moduledoc """
  Pure projection functions over the `WorkflowEvent` log.

  `WorkflowRun.status` is **projection-owned**: it is written only by the
  append path, never mutated directly. These functions are the single
  source of truth for *which* event kinds carry status authority, *what*
  status an event implies, and the *legal* transitions between statuses.
  They are shared by:

    * `JidoClaw.Orchestration.WorkflowEvent.Changes.Allocate` — runs
      `next_status/2` as a transition guard and `status_attrs/3` to write
      the materialized column in the append transaction;
    * `JidoClaw.Orchestration.WorkflowRecovery` — folds stranded runs to
      `:failed` through the same vocabulary;
    * tests — `project_status/1` folds an event list to prove the
      materialized column equals the fold.

  ## Atom/string key tolerance

  `status_attrs/3` reads `result`/`error` out of the payload. The change
  projects from the **raw in-memory** payload (atom keys), while a fold
  over **persisted** events sees JSONB-round-tripped string keys, so every
  payload access tolerates both (`payload[:result] || payload["result"]`).
  """

  # AR-2 composer parent-terminal kinds (Phase 2c), grouped by the existing
  # `WorkflowRun.status` each implies — the composer adds NO new status atom, it
  # reuses `:completed`/`:failed`/`:cancelled`. The loop produces `:route_converged`
  # + the four `@route_failed_kinds`; `:route_rejected`/`:route_abandoned` are
  # defined + projected now, producers (Phase 4 gates) later. `route_*` failures
  # stay distinct from the abnormal-path generic `:run_failed` (both → `:failed`),
  # so `terminal_status?/1` covers either.
  @route_failed_kinds [
    :route_not_converged,
    :route_deadlocked,
    :route_budget_exhausted,
    :route_failed
  ]
  @route_cancelled_kinds [:route_rejected, :route_abandoned]
  # AR-8c `:route_verify_failed`, AR-4 `:route_fix_failed`, camus C1-3
  # `:route_review_infra_failed`, and item 5's `:route_verify_tampered` are
  # status-authority TERMINALS (they must fold into the status column), but
  # they are deliberately kept OUT of `@route_failed_kinds` and
  # `@route_cancelled_kinds` — those drive the guard clauses in
  # `next_status`/`status_attrs`, and membership there would shadow the
  # explicit per-kind clauses (which lift BOTH `error` and the
  # `result.disposition`, a `:failed`-with-result combination neither family
  # does). Camus C1-4's `:route_done_with_findings` is the COMPLETED twin of
  # that note: the first completed-family kind with a disposition, kept out of
  # both failure families for the same shadowing reason.
  @route_terminal_kinds [
                          :route_converged,
                          :route_done_with_findings,
                          :route_verify_failed,
                          :route_fix_failed,
                          :route_review_infra_failed,
                          :route_verify_tampered
                        ] ++
                          @route_failed_kinds ++ @route_cancelled_kinds

  # Status-authority set. `run_recovered`/`run_halted`/`step_*` are NOT
  # authority — `run_halted` is provenance only (the in-txn `approval_requested`
  # is what flips the run to `:awaiting_approval`). The gate kinds carry
  # authority: `approval_requested` (→ `:awaiting_approval`),
  # `approval_resolved` (approve = "decision recorded, resuming" → `:running`),
  # and `run_abandoned` (operator gave up on a parked
  # gate → terminal `:abandoned`). The composer's additive/subtractive wave deltas
  # are deliberately NOT authority — they persist as pure-log events and the parent
  # stays `:running` across a wave; only `@route_terminal_kinds` carry authority.
  @status_authority_kinds [
                            :run_started,
                            :run_resumed,
                            :run_completed,
                            :run_failed,
                            :run_cancelled,
                            :run_abandoned,
                            :approval_requested,
                            :approval_resolved
                          ] ++ @route_terminal_kinds

  @non_terminal [:pending, :running, :awaiting_approval]

  # The terminal run statuses — a run here can no longer make progress.
  # Complement of @non_terminal; the single source every other module folds onto.
  @terminal [:completed, :failed, :cancelled, :abandoned]

  @doc "The terminal run statuses (the run can no longer make progress)."
  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal

  @doc "Whether `status` is terminal. Total: a non-atom returns false."
  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status) when is_atom(status), do: status in @terminal
  def terminal_status?(_status), do: false

  @doc """
  Returns `true` when `kind` is a status-authority event — one that the
  append path must fold into the materialized `WorkflowRun.status` column
  in the same transaction.
  """
  @spec status_authority?(atom()) :: boolean()
  def status_authority?(kind) when is_atom(kind), do: kind in @status_authority_kinds

  @doc """
  Transition guard. Returns `{:ok, new_status}` for a legal
  `current_status -> kind` transition, or `:illegal` otherwise.

  Preserves the pending/running/terminal invariants the removed
  `start`/`complete`/`fail`/`cancel` actions enforced, now that `:append`
  is the only writer:

    * `run_started` only from `:pending`
    * `run_completed` only from `:running`
    * `run_failed` from any non-terminal
    * `run_cancelled` from any non-terminal
    * `run_abandoned` **only from `:awaiting_approval`** — the parked-gate
      state, where nothing is executing by construction. The catch-all
      `:illegal` (rolling back the append) is the guard against abandoning a
      live run; widening to in-flight runs is future work gated on
      lease/cancellation semantics (§4.11).
    * `approval_requested` only from `:running` (a gate step pauses the run)
    * `approval_resolved` only from `:awaiting_approval` (approve = resuming)
    * `run_resumed` from `:awaiting_approval` **or** `:running` — the latter is
      idempotent: on the operator approve path `approval_resolved` already set
      `:running`, and `init/1` then appends `run_resumed` (Decision 6), so the
      resume's own `run_resumed` must not be `:illegal`.

  Any terminal -> terminal or out-of-order kind is `:illegal`.
  """
  @spec next_status(atom(), atom()) :: {:ok, atom()} | :illegal
  def next_status(:pending, :run_started), do: {:ok, :running}
  def next_status(:running, :run_completed), do: {:ok, :completed}
  def next_status(status, :run_failed) when status in @non_terminal, do: {:ok, :failed}
  def next_status(status, :run_cancelled) when status in @non_terminal, do: {:ok, :cancelled}
  def next_status(:awaiting_approval, :run_abandoned), do: {:ok, :abandoned}
  def next_status(:running, :approval_requested), do: {:ok, :awaiting_approval}
  def next_status(:awaiting_approval, :approval_resolved), do: {:ok, :running}
  def next_status(:awaiting_approval, :run_resumed), do: {:ok, :running}
  def next_status(:running, :run_resumed), do: {:ok, :running}

  # AR-2 composer terminals (Phase 2c). `route_converged` mirrors `run_completed`
  # (`:running` only — the composer parent is `:running` for the whole route);
  # the four failure kinds mirror `run_failed` (any non-terminal → `:failed`);
  # `route_rejected`/`route_abandoned` mirror `run_cancelled` (any non-terminal →
  # `:cancelled`). A terminal → terminal append still falls to `:illegal`.
  def next_status(:running, :route_converged), do: {:ok, :completed}

  # Camus C1-4: an approved review-stall release completes the run — from
  # `:running` ONLY, like `route_converged` (the composer parent stays
  # `:running` for the whole route INCLUDING the stall park; there is no
  # `:awaiting_approval` leg on this axis).
  def next_status(:running, :route_done_with_findings), do: {:ok, :completed}

  # AR-8c: a verify-failed machine change projects onto `:failed` (like the other
  # failure kinds), from any non-terminal. An explicit clause — `:route_verify_failed`
  # is intentionally absent from `@route_failed_kinds` (which would shadow the
  # disposition-lifting `status_attrs` clause below).
  def next_status(status, :route_verify_failed) when status in @non_terminal, do: {:ok, :failed}

  # AR-4: a fix-failed code change projects onto `:failed` (like verify-failed),
  # from any non-terminal. An explicit clause — `:route_fix_failed` is also absent
  # from `@route_failed_kinds` (which would shadow the disposition-lifting clause).
  def next_status(status, :route_fix_failed) when status in @non_terminal, do: {:ok, :failed}

  # Camus C1-3: a review-infra-failed run projects onto `:failed`, from any
  # non-terminal. An explicit clause for the same shadowing reason as its two
  # disposition-lifting siblings above.
  def next_status(status, :route_review_infra_failed) when status in @non_terminal,
    do: {:ok, :failed}

  # Item 5: a tampered verify projects onto `:failed`, from any non-terminal —
  # an explicit clause for the same disposition-lifting reason as its siblings.
  def next_status(status, :route_verify_tampered) when status in @non_terminal,
    do: {:ok, :failed}

  def next_status(status, kind) when status in @non_terminal and kind in @route_failed_kinds,
    do: {:ok, :failed}

  def next_status(status, kind) when status in @non_terminal and kind in @route_cancelled_kinds,
    do: {:ok, :cancelled}

  def next_status(_current, _kind), do: :illegal

  @doc """
  The `WorkflowRun` attribute changes a status-authority `kind` implies.

  `occurred_at` is sourced from the persisted event so `started_at` /
  `completed_at` always equal the event time. `result`/`error` come from
  the **raw** (unredacted) payload so the run columns keep raw values —
  only the durable event payload is redacted.

  ## Checkpoint lifecycle (Decision 7)

  The **terminal** clauses (`run_completed`/`run_failed`/`run_cancelled`/
  `run_abandoned` and the AR-2 composer `route_*` terminals) set
  `clear_checkpoint: true` — `:set_status`'s explicit
  clear argument, which force-changes the **real encrypted column**
  (`encrypted_resume_checkpoint`) to true SQL NULL — so a run's frozen halt
  blob is cleared in the *same transaction* as the terminal status flip, with
  no per-call cleanup. Deliberately NOT the cloaked `resume_checkpoint`
  argument: routing `nil` through AshCloak's encrypt rewrite would store
  ciphertext-of-nil, and every presence check (recovery classification,
  `guard_resumable`, `GateResume`) would read it as "checkpoint present". The
  non-terminal clauses (`approval_requested` → `:awaiting_approval`,
  `approval_resolved` / `run_resumed` → `:running`)
  leave it untouched: the checkpoint is written by the runner on pause and
  must survive until the run terminates.
  """
  @spec status_attrs(atom(), map(), DateTime.t()) :: map()
  def status_attrs(:run_started, _payload, occurred_at),
    do: %{status: :running, started_at: occurred_at}

  def status_attrs(:run_completed, payload, occurred_at),
    do: terminal_lifting_result(:completed, payload, occurred_at)

  def status_attrs(:run_failed, payload, occurred_at),
    do: terminal_lifting_error(:failed, payload, occurred_at)

  def status_attrs(:run_cancelled, _payload, occurred_at),
    do: %{status: :cancelled, completed_at: occurred_at, clear_checkpoint: true}

  def status_attrs(:run_abandoned, _payload, occurred_at),
    do: %{status: :abandoned, completed_at: occurred_at, clear_checkpoint: true}

  def status_attrs(:approval_requested, _payload, _occurred_at),
    do: %{status: :awaiting_approval}

  def status_attrs(:approval_resolved, _payload, _occurred_at),
    do: %{status: :running}

  def status_attrs(:run_resumed, _payload, _occurred_at),
    do: %{status: :running}

  # AR-2 composer terminals (Phase 2c). `route_converged` models on
  # `:run_completed` (lifts `result`); the four failure kinds model on
  # `:run_failed` (lift `error`). `route_rejected`/`route_abandoned` get their
  # OWN clause — `:cancelled` but lifting `result` (NOT `:run_cancelled`, which
  # drops its payload) so the disposition the gate records (`result.disposition`)
  # survives onto the run column. All clear the checkpoint like every terminal.
  def status_attrs(:route_converged, payload, occurred_at),
    do: terminal_lifting_result(:completed, payload, occurred_at)

  # Camus C1-4 — the first COMPLETED-with-disposition combination: lift
  # `result` (disposition `"done_with_findings"` + keys/counts) onto the run
  # column, so the operator query is
  # `status == :completed AND result.disposition == "done_with_findings"`.
  def status_attrs(:route_done_with_findings, payload, occurred_at),
    do: terminal_lifting_result(:completed, payload, occurred_at)

  # AR-8c / AR-4 — the novel `:failed`-WITH-disposition combination: lift BOTH
  # `error` (the findings-derived reason string, scrubbed for a sensitive run) AND
  # `result` (the non-sensitive `%{disposition: "verify_failed" | "fix_failed"}`),
  # so the operator query is `status == :failed AND result.disposition == "..."`.
  # Both placed BEFORE the `@route_failed_kinds` guard (which lifts only `error`).
  def status_attrs(:route_verify_failed, payload, occurred_at),
    do: terminal_lifting_error_and_result(:failed, payload, occurred_at)

  def status_attrs(:route_fix_failed, payload, occurred_at),
    do: terminal_lifting_error_and_result(:failed, payload, occurred_at)

  def status_attrs(:route_review_infra_failed, payload, occurred_at),
    do: terminal_lifting_error_and_result(:failed, payload, occurred_at)

  def status_attrs(:route_verify_tampered, payload, occurred_at),
    do: terminal_lifting_error_and_result(:failed, payload, occurred_at)

  def status_attrs(kind, payload, occurred_at) when kind in @route_failed_kinds,
    do: terminal_lifting_error(:failed, payload, occurred_at)

  def status_attrs(kind, payload, occurred_at) when kind in @route_cancelled_kinds,
    do: terminal_lifting_result(:cancelled, payload, occurred_at)

  # The two terminal attribute shapes — `status` + `completed_at` +
  # `clear_checkpoint`, lifting either `result` (completed/converged, or cancelled
  # carrying a disposition) or `error` (failed). Factored so each shape lives once
  # (reach repeated-map-shape); the raw payload tolerates atom/string keys.
  defp terminal_lifting_result(status, payload, occurred_at) do
    %{
      status: status,
      completed_at: occurred_at,
      result: fetch(payload, :result),
      clear_checkpoint: true
    }
  end

  defp terminal_lifting_error(status, payload, occurred_at) do
    %{
      status: status,
      completed_at: occurred_at,
      error: fetch(payload, :error),
      clear_checkpoint: true
    }
  end

  # AR-8c / AR-4 / camus C1-3 — `:failed` lifting BOTH `error` and `result` (the
  # disposition). The verify-failed, fix-failed, AND review-infra-failed terminals
  # share this exact shape (single-sourced, not cloned): the error string is the
  # (scrubbable) reason, the result the non-sensitive disposition marker.
  defp terminal_lifting_error_and_result(status, payload, occurred_at) do
    %{
      status: status,
      completed_at: occurred_at,
      error: fetch(payload, :error),
      result: fetch(payload, :result),
      clear_checkpoint: true
    }
  end

  @doc """
  Fold a list of events (sorted by `seq`) to a status, applying
  `next_status/2` per status-authority event.

  Authority at runtime is the materialized column; this exists to *prove*
  column == fold in tests. Illegal transitions never persist (the change
  rolls them back), so they cannot appear in a real log; if one somehow
  does, the fold ignores it and keeps the prior status.
  """
  @spec project_status([map()]) :: atom()
  def project_status(events) do
    events
    |> Enum.sort_by(& &1.seq)
    |> Enum.reduce(:pending, fn event, status ->
      fold(status, event.kind)
    end)
  end

  defp fold(status, kind) do
    if status_authority?(kind) do
      case next_status(status, kind) do
        {:ok, new_status} -> new_status
        :illegal -> status
      end
    else
      status
    end
  end

  defp fetch(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end
end
