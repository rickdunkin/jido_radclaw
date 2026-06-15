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

  # Status-authority set. `run_recovered`/`run_halted`/`step_*` are NOT
  # authority — `run_halted` is provenance only (the in-txn `approval_requested`
  # is what flips the run to `:awaiting_approval`). The gate kinds carry
  # authority: `approval_requested` (→ `:awaiting_approval`),
  # `approval_resolved` (approve = "decision recorded, resuming" → `:running`),
  # `approval_retracted` (stale approval withdrawn pre-resume →
  # `:awaiting_approval`), and `run_abandoned` (operator gave up on a parked
  # gate → terminal `:abandoned`).
  @status_authority_kinds [
    :run_started,
    :run_resumed,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :run_abandoned,
    :approval_requested,
    :approval_resolved,
    :approval_retracted
  ]

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
    * `approval_retracted` only from `:running` — a recorded-but-not-yet-acted
      approval is withdrawn pre-resume, parking the run back at
      `:awaiting_approval` so a revised plan must re-earn its approval. The
      pre-resume race fence lives in `Cases.retract/3`.
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
  def next_status(:running, :approval_retracted), do: {:ok, :awaiting_approval}
  def next_status(:awaiting_approval, :run_resumed), do: {:ok, :running}
  def next_status(:running, :run_resumed), do: {:ok, :running}
  def next_status(_current, _kind), do: :illegal

  @doc """
  The `WorkflowRun` attribute changes a status-authority `kind` implies.

  `occurred_at` is sourced from the persisted event so `started_at` /
  `completed_at` always equal the event time. `result`/`error` come from
  the **raw** (unredacted) payload so the run columns keep raw values —
  only the durable event payload is redacted.

  ## Checkpoint lifecycle (Decision 7)

  The **terminal** clauses (`run_completed`/`run_failed`/`run_cancelled`/
  `run_abandoned`) set `clear_checkpoint: true` — `:set_status`'s explicit
  clear argument, which force-changes the **real encrypted column**
  (`encrypted_resume_checkpoint`) to true SQL NULL — so a run's frozen halt
  blob is cleared in the *same transaction* as the terminal status flip, with
  no per-call cleanup. Deliberately NOT the cloaked `resume_checkpoint`
  argument: routing `nil` through AshCloak's encrypt rewrite would store
  ciphertext-of-nil, and every presence check (recovery classification,
  `guard_resumable`, `GateResume`) would read it as "checkpoint present". The
  non-terminal clauses (`approval_requested` / `approval_retracted` →
  `:awaiting_approval`, `approval_resolved` / `run_resumed` → `:running`)
  leave it untouched: the checkpoint is written by the runner on pause and
  must survive until the run terminates.
  """
  @spec status_attrs(atom(), map(), DateTime.t()) :: map()
  def status_attrs(:run_started, _payload, occurred_at),
    do: %{status: :running, started_at: occurred_at}

  def status_attrs(:run_completed, payload, occurred_at),
    do: %{
      status: :completed,
      completed_at: occurred_at,
      result: fetch(payload, :result),
      clear_checkpoint: true
    }

  def status_attrs(:run_failed, payload, occurred_at),
    do: %{
      status: :failed,
      completed_at: occurred_at,
      error: fetch(payload, :error),
      clear_checkpoint: true
    }

  def status_attrs(:run_cancelled, _payload, occurred_at),
    do: %{status: :cancelled, completed_at: occurred_at, clear_checkpoint: true}

  def status_attrs(:run_abandoned, _payload, occurred_at),
    do: %{status: :abandoned, completed_at: occurred_at, clear_checkpoint: true}

  def status_attrs(:approval_requested, _payload, _occurred_at),
    do: %{status: :awaiting_approval}

  def status_attrs(:approval_resolved, _payload, _occurred_at),
    do: %{status: :running}

  # Retraction parks the run back at the gate; the checkpoint is deliberately
  # untouched — it is exactly what the eventual (re-)resume needs.
  def status_attrs(:approval_retracted, _payload, _occurred_at),
    do: %{status: :awaiting_approval}

  def status_attrs(:run_resumed, _payload, _occurred_at),
    do: %{status: :running}

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
