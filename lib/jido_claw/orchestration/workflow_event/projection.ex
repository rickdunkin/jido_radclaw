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

  # Phase 0 status-authority set. `run_recovered`/`run_halted`/`step_*`/gate
  # kinds are NOT authority here — gate kinds gain mappings when human gates
  # land (Reactor doc §4.5).
  @status_authority_kinds [
    :run_started,
    :run_resumed,
    :run_completed,
    :run_failed,
    :run_cancelled
  ]

  @non_terminal [:pending, :running, :awaiting_approval]

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
    * `run_resumed` only from `:awaiting_approval`

  Any terminal -> terminal or out-of-order kind is `:illegal`.
  """
  @spec next_status(atom(), atom()) :: {:ok, atom()} | :illegal
  def next_status(:pending, :run_started), do: {:ok, :running}
  def next_status(:running, :run_completed), do: {:ok, :completed}
  def next_status(status, :run_failed) when status in @non_terminal, do: {:ok, :failed}
  def next_status(status, :run_cancelled) when status in @non_terminal, do: {:ok, :cancelled}
  def next_status(:awaiting_approval, :run_resumed), do: {:ok, :running}
  def next_status(_current, _kind), do: :illegal

  @doc """
  The `WorkflowRun` attribute changes a status-authority `kind` implies.

  `occurred_at` is sourced from the persisted event so `started_at` /
  `completed_at` always equal the event time. `result`/`error` come from
  the **raw** (unredacted) payload so the run columns keep raw values —
  only the durable event payload is redacted.
  """
  @spec status_attrs(atom(), map(), DateTime.t()) :: map()
  def status_attrs(:run_started, _payload, occurred_at),
    do: %{status: :running, started_at: occurred_at}

  def status_attrs(:run_completed, payload, occurred_at),
    do: %{status: :completed, completed_at: occurred_at, result: fetch(payload, :result)}

  def status_attrs(:run_failed, payload, occurred_at),
    do: %{status: :failed, completed_at: occurred_at, error: fetch(payload, :error)}

  def status_attrs(:run_cancelled, _payload, occurred_at),
    do: %{status: :cancelled, completed_at: occurred_at}

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
