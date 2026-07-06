defmodule JidoClaw.WorkflowView do
  @moduledoc """
  Tenant-scoped projection of durable workflow-run status.
  """

  require Ash.Query

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Replay.EventReader
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer.Observe
  alias JidoClaw.Tools.OutputLimit

  @active_statuses [:pending, :running, :awaiting_approval]

  # event_feed/3 pagination bounds (all tunable). The byte budget is the real
  # bound — on the whole page AND on each event; the count cap is a memory/fetch
  # pre-bound applied before byte-folding.
  @event_feed_default_limit 50
  @event_feed_max_limit 200
  @event_feed_byte_budget 24 * 1024

  # JSON list framing accounted for by byte_fold/2, so it is the SERIALIZED page
  # (not the bare per-event sum) that stays within budget: "[" … "]" is 2 bytes,
  # plus one "," between adjacent elements.
  @list_frame_bytes 2
  @element_sep_bytes 1

  # Headroom (event scalars, object punctuation, marker structure) held back
  # from a single event's fit target; the rest is split across the two large
  # leaf previews. Generous on purpose — fit_event/2 falls back to preview-less
  # markers if a pathological event still overflows.
  @event_marker_overhead 1024

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          active_count: non_neg_integer(),
          active_runs: [map()],
          recent_completions: [map()],
          findings_deferred: non_neg_integer(),
          generated_at: DateTime.t()
        }

  defstruct tenant_id: nil,
            active_count: 0,
            active_runs: [],
            recent_completions: [],
            findings_deferred: 0,
            generated_at: nil

  # runs/2 status/pagination bounds: callers (the Lua `jido.runs` binding)
  # get a bounded read whatever they pass.
  @runs_default_limit 25
  @runs_max_limit 50

  # runs/2 sort whitelist — the only orderings that reach Query.sort.
  @runs_sorts [[started_at: :desc], [completed_at: :desc]]

  @spec list(map() | keyword()) :: {:ok, t()} | {:error, :tenant_required}
  def list(scope_or_opts) do
    with {:ok, opts} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, build(opts)}
    end
  end

  @doc """
  Tenant-scoped run listing with honest errors — the data source for the
  Lua `jido.runs` binding (contrast `list/1`, a best-effort dashboard
  rollup that swallows read errors into `[]`; here a read failure
  surfaces `{:error, :runs_unavailable}`, never a misleading empty page).

  `opts` (keyword list or atom-keyed map):

    * `:statuses` — list of run-status atoms to include (callers validate
      raw input against the enum; default #{inspect(@active_statuses)}).
    * `:limit` — clamped to 1..#{@runs_max_limit}, default #{@runs_default_limit}.
    * `:sort` — one of `#{inspect(@runs_sorts)}` (a whitelist, never raw
      caller input into `Query.sort`); anything else falls back to the
      default `[started_at: :desc]`. `[completed_at: :desc]` is the
      completions ordering (the `list/1` rollup precedent).

  Returns `{:ok, [map]}` of `Visibility.run_view(:operator)` projections.
  """
  @spec runs(map() | keyword(), map() | keyword()) ::
          {:ok, [map()]} | {:error, :tenant_required | :runs_unavailable}
  def runs(scope_or_opts, opts \\ []) do
    with {:ok, scope} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      tenant_id = Keyword.fetch!(scope, :tenant_id)
      actor = Keyword.get(scope, :actor) || Actor.system(tenant_id)
      opts = Enum.to_list(opts)
      statuses = Keyword.get(opts, :statuses) || @active_statuses
      limit = clamp_runs_limit(Keyword.get(opts, :limit))

      WorkflowRun
      |> Query.filter(status in ^statuses)
      |> Query.sort(validate_runs_sort(Keyword.get(opts, :sort)))
      |> Query.limit(limit)
      |> Ash.read(tenant: tenant_id, actor: actor)
      |> case do
        {:ok, runs} ->
          now = DateTime.utc_now()
          {:ok, Enum.map(runs, &run_to_map(&1, now))}

        {:error, _} ->
          {:error, :runs_unavailable}
      end
    end
  end

  @doc "The default (active) status set `runs/2` filters by — single-sourced for callers validating status input."
  @spec active_statuses() :: [atom()]
  def active_statuses, do: @active_statuses

  @spec snapshot(String.t(), map() | keyword()) :: {:ok, map()} | {:error, atom()}
  def snapshot(run_id, scope_or_opts) when is_binary(run_id) do
    case JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      {:ok, opts} ->
        tenant_id = Keyword.fetch!(opts, :tenant_id)
        actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)

        case WorkflowRun.by_id(run_id, tenant: tenant_id, actor: actor) do
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, run} ->
            view =
              run
              |> run_to_map(DateTime.utc_now())
              |> put_composer(run, tenant_id, actor)

            {:ok, view}

          {:error, _} ->
            {:error, :not_found}
        end

      {:error, :tenant_required} ->
        {:error, :tenant_required}
    end
  end

  @doc """
  Return a run's raw `WorkflowEvent` feed (seq / kind / occurred_at / payload /
  metadata), tenant-scoped and **byte-bounded + seq-paginated**. The data source
  for the MCP `workflow_events` tool; also callable directly.

  `scope_or_opts` carries the tenant scope (`%{tenant_id: ...}` or a keyword
  list; a supplied `:actor` is used, else a tenant-bound system actor). `opts`
  is the pagination control — a keyword list OR an **atom-keyed** map (string
  keys are out of contract):

    * `:limit` — page target (default #{@event_feed_default_limit}, clamped to
      #{@event_feed_max_limit}); a page may return fewer because it is
      additionally byte-bounded.
    * `:after_seq` — return only events with `seq > after_seq`; pass back the
      prior call's `next_seq` to page forward.

  Returns `{:ok, %{run_id, run_status, count, events, next_seq}}` — `events` is a
  list of string-keyed maps (each JSON-encoding ≤ the byte budget; an oversized
  event's `payload`/`metadata` collapse to a bounded `"truncated" => true`
  marker) and `next_seq` is the last event's seq when more remain, else `nil`.

  A read failure on a run that exists surfaces `{:error,
  :event_feed_unavailable}` — never a misleading empty page (contrast `list/1`,
  a best-effort dashboard rollup that swallows read errors).
  """
  @spec event_feed(String.t(), map() | keyword(), map() | keyword()) ::
          {:ok, map()} | {:error, :tenant_required | :not_found | :event_feed_unavailable}
  def event_feed(run_id, scope_or_opts, opts \\ []) when is_binary(run_id) do
    with {:ok, scope} <- JidoClaw.RuntimeScope.require_tenant(scope_or_opts, scope_keys()) do
      tenant_id = Keyword.fetch!(scope, :tenant_id)
      actor = Keyword.get(scope, :actor) || Actor.system(tenant_id)
      # Normalize: a keyword list passes through; an atom-keyed map becomes one.
      opts = Enum.to_list(opts)

      case WorkflowRun.by_id(run_id, tenant: tenant_id, actor: actor) do
        {:ok, %WorkflowRun{} = run} -> read_event_feed(run, tenant_id, actor, opts)
        # nil (get_by miss) OR {:error, _} → clean not_found (the snapshot/2 pattern).
        _ -> {:error, :not_found}
      end
    end
  end

  @spec to_mcp_map(t()) :: map()
  def to_mcp_map(%__MODULE__{} = view) do
    view
    |> Map.from_struct()
    |> JsonSafe.encode()
  end

  defp build(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    actor = Keyword.get(opts, :actor) || Actor.system(tenant_id)
    active_runs = read_runs(tenant_id, actor, @active_statuses, [started_at: :desc], 25)

    completions =
      read_runs(tenant_id, actor, Projection.terminal_statuses(), [completed_at: :desc], 10)

    # One timestamp for the whole view: consistent deadline evidence across
    # every projected run, and it doubles as generated_at.
    now = DateTime.utc_now()

    recent_completions = Enum.map(completions, &run_to_map(&1, now))

    %__MODULE__{
      tenant_id: tenant_id,
      active_count: length(active_runs),
      active_runs: Enum.map(active_runs, &run_to_map(&1, now)),
      recent_completions: recent_completions,
      findings_deferred: findings_deferred(recent_completions),
      generated_at: now
    }
  end

  # Camus C1-4 rollup: deferred findings across the recent-completions window
  # (done_with_findings runs' waived-finding counts) — derived from what the
  # rollup already read, deliberately NOT a tenant-wide total (that is the
  # `Cases.waived_findings_ledger/2` / `jido.debt` surface).
  defp findings_deferred(recent_completions) do
    Enum.sum_by(recent_completions, fn run_map ->
      case run_map[:findings_deferred_count] do
        count when is_integer(count) and count >= 0 -> count
        _absent -> 0
      end
    end)
  end

  defp read_runs(tenant_id, actor, statuses, sort, limit) do
    WorkflowRun
    |> Query.filter(status in ^statuses)
    |> Query.sort(sort)
    |> Query.limit(limit)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, runs} -> runs
      {:error, _} -> []
    end
  end

  # This is the LLM/MCP surface — permanently operator-scoped (T2-2): payloads
  # are key-filtered/redacted/truncated by `Visibility`, with the `deadline`
  # evidence (T2-1) additively extending the legacy key set. `to_mcp_map`'s
  # JsonSafe.encode handles the evidence DateTimes.
  defp run_to_map(%WorkflowRun{} = run, now), do: Visibility.run_view(run, :operator, now)

  # AR-2 Phase 5 (§10.2): a composer run additively carries a `:composer` key —
  # the seed-free observe view (`Observe.summarize/1`) over the durable event
  # log. The key is ALWAYS a map (with an `available` flag) so an observe-read
  # failure is never silently indistinguishable from "no composer state": an
  # event-read error surfaces `available: false, reason: :observe_unavailable`,
  # a run that has not composed its first wave `available: false, reason:
  # :not_yet_composed`. A non-composer run is unchanged (no `:composer` key).
  defp put_composer(view, %WorkflowRun{workflow_type: "composer", id: id}, tenant_id, actor) do
    # O-M1: kind-filter the observe read to only the five marker kinds
    # `Observe.summarize/1` folds (route_composed / wave_completed /
    # stages_invalidated / stage_infra / wave_started — it deliberately ignores
    # wave_paused; `stage_infra` closes a wave-error-lane wave via
    # `closed_wave_index`, camus C1-3), shedding the per-step event spam that
    # dwarfs composer deltas on a long run.
    # NOT row-limited: `net_ran` folds cumulative history, so a `limit:` would
    # wrongly drop early `wave_completed`s. Bounded by wave count (⊆ `max_waves`).
    # No index covers `kind` (only `[tenant_id, workflow_run_id, seq]`), so the
    # win is fewer rows decoded/folded in the BEAM, not a cheaper scan. Reuses the
    # swappable `EventReader` `query:` seam (default `WorkflowEvent.for_run/2`).
    composer =
      case EventReader.for_run(id,
             query: [
               filter: [
                 kind: [
                   in: [
                     :route_composed,
                     :wave_completed,
                     :stages_invalidated,
                     :stage_infra,
                     :wave_started
                   ]
                 ]
               ],
               sort: [seq: :asc]
             ],
             tenant: tenant_id,
             actor: actor
           ) do
        {:ok, events} ->
          case Observe.summarize(events) do
            nil ->
              %{available: false, reason: :not_yet_composed}

            summary ->
              summary
              |> Map.put(:available, true)
              |> put_gate_block(id, tenant_id, actor)
          end

        {:error, _} ->
          %{available: false, reason: :observe_unavailable}
      end

    Map.put(view, :composer, composer)
  end

  defp put_composer(view, _run, _tenant, _actor), do: view

  # Authoritative blocked-on-gate signal, TWO sources: a CHILD run parked
  # `:awaiting_approval` (the plan/safety gates — the parent stays `:running`
  # across a child gate pause, §6), and a parent-bound pending `:review_stall`
  # case (camus C1-4 — the composer's child-less stall park, where nothing is
  # `:awaiting_approval` by design; the case row is the only durable signal).
  # `held` (lock-held stages) and `awaiting_approval` (gate park) stay
  # DISTINCT waiting states.
  defp put_gate_block(summary, parent_id, tenant_id, actor) do
    summary
    |> put_child_gate_block(parent_id, tenant_id, actor)
    |> put_stall_gate_block(parent_id, tenant_id, actor)
  end

  defp put_child_gate_block(summary, parent_id, tenant_id, actor) do
    WorkflowRun
    |> Query.filter(parent_run_id == ^parent_id and status == :awaiting_approval)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, runs} ->
        ids = Enum.map(runs, & &1.id)

        Map.merge(summary, %{
          awaiting_approval_available: true,
          awaiting_approval: ids != [],
          awaiting_child_run_ids: ids
        })

      {:error, _} ->
        # Do NOT collapse a read failure to `awaiting_approval: false` — that is
        # a false negative for the exact gate-block state this surface exposes.
        # Mark the signal untrusted instead (no misleading `awaiting_approval`).
        Map.put(summary, :awaiting_approval_available, false)
    end
  end

  # A pending review-stall case flips `awaiting_approval` too (it IS an
  # operator decision blocking the run — runs after the child block so its
  # `true` wins the merge) and carries its own marker + case id + the C3-2
  # resume hint. Same honesty posture: a failed case read marks the stall
  # signal untrusted rather than reading as "no stall".
  defp put_stall_gate_block(summary, parent_id, tenant_id, actor) do
    case AgentCase.pending_for_run(parent_id, tenant: tenant_id, actor: actor) do
      {:ok, cases} ->
        case Enum.find(cases, &(&1.kind == :review_stall)) do
          %AgentCase{} = stall ->
            summary
            |> Map.merge(%{
              review_stall_pending: true,
              review_stall_case_id: stall.id,
              awaiting_approval: true
            })
            |> put_stall_hint(stall)

          nil ->
            Map.put(summary, :review_stall_pending, false)
        end

      {:error, _} ->
        Map.put(summary, :review_stall_available, false)
    end
  end

  defp put_stall_hint(summary, %AgentCase{details: %{"resume_hint" => hint}})
       when is_binary(hint),
       do: Map.put(summary, :resume_hint, hint)

  defp put_stall_hint(summary, _stall), do: summary

  # The run row already exists here (by_id matched), so a read failure is a real
  # fault, NOT "no events" — surface :event_feed_unavailable rather than
  # collapsing to a misleading empty feed. Reads through the swappable
  # `EventReader` seam (default `WorkflowEvent.for_run/2`) via the standard
  # `query:` code-interface option, so the impl and the failure-injection test
  # path are the SAME seam.
  defp read_event_feed(run, tenant_id, actor, opts) do
    count_cap = clamp_limit(Keyword.get(opts, :limit))
    after_seq = non_neg_seq(Keyword.get(opts, :after_seq))

    case EventReader.for_run(run.id,
           query: feed_query(count_cap, after_seq),
           tenant: tenant_id,
           actor: actor
         ) do
      {:ok, rows} ->
        # feed_query fetched count_cap + 1; that sentinel row distinguishes
        # "exactly a full page" from "more beyond it" without the off-by-one bug.
        sentinel? = length(rows) > count_cap
        bounded = Enum.take(rows, count_cap)

        projected =
          Enum.map(bounded, fn event ->
            event
            |> event_to_map()
            |> fit_event(@event_feed_byte_budget)
          end)

        {page, cursor} = byte_fold(projected, @event_feed_byte_budget)
        has_more? = sentinel? or length(page) < length(projected)

        {:ok,
         %{
           run_id: run.id,
           run_status: run.status,
           count: length(page),
           events: page,
           # cursor is the last kept event's seq; only a real cursor when more remain.
           next_seq: if(has_more?, do: cursor, else: nil)
         }}

      {:error, _} ->
        {:error, :event_feed_unavailable}
    end
  end

  # +1 sentinel so "has more" is detectable; the after_seq filter ANDs with the
  # action's own `workflow_run_id ==` filter, and the action's `seq: :asc` sort
  # is preserved (query: opts are additive to the action, per the reader contract).
  defp feed_query(count_cap, nil), do: [limit: count_cap + 1]

  defp feed_query(count_cap, after_seq),
    do: [filter: [seq: [greater_than: after_seq]], limit: count_cap + 1]

  defp clamp_limit(limit) when is_integer(limit),
    do: min(max(limit, 1), @event_feed_max_limit)

  defp clamp_limit(_), do: @event_feed_default_limit

  defp validate_runs_sort(sort) when sort in @runs_sorts, do: sort
  defp validate_runs_sort(_sort), do: [started_at: :desc]

  defp clamp_runs_limit(limit) when is_integer(limit),
    do: min(max(limit, 1), @runs_max_limit)

  defp clamp_runs_limit(_), do: @runs_default_limit

  defp non_neg_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp non_neg_seq(_), do: nil

  # String-keyed, JsonSafe'd projection of one event — atoms/DateTimes become
  # strings, so no un-encodable leaf reaches the MCP boundary.
  defp event_to_map(event) do
    %{
      "seq" => event.seq,
      "kind" => to_string(event.kind),
      "occurred_at" => JsonSafe.encode(event.occurred_at),
      "payload" => JsonSafe.encode(event.payload),
      "metadata" => JsonSafe.encode(event.metadata)
    }
  end

  # Bound ONE event to the page byte budget minus the list-framing reserve (so a
  # lone fitted event's serialized page `[event]` still fits). Under budget ⇒
  # unchanged; oversized ⇒ its two large leaves (payload/metadata) collapse to
  # bounded, utf8-safe JSON-preview markers and the event is stamped
  # `"truncated" => true`. This makes the feed self-bounding for EVERY caller
  # (direct API included) and closes the multi-leaf case OutputLimit's per-leaf
  # 32 KB trim would miss.
  defp fit_event(event, budget) do
    target = max(budget - @list_frame_bytes, 0)

    if json_size(event) <= target do
      event
    else
      fitted = markerize_leaves(event, div(max(target - @event_marker_overhead, 0), 2))

      # Airtight backstop: if a pathological event (e.g. huge scalar fields) still
      # overflows, drop the previews — a preview-less marker skeleton is tiny and
      # unconditionally under target.
      if json_size(fitted) <= target, do: fitted, else: markerize_leaves(event, 0)
    end
  end

  defp markerize_leaves(event, per_leaf) do
    event
    |> Map.put("payload", fit_leaf(Map.get(event, "payload"), per_leaf))
    |> Map.put("metadata", fit_leaf(Map.get(event, "metadata"), per_leaf))
    |> Map.put("truncated", true)
  end

  # Keep a leaf whole when it already fits its share; otherwise collapse it to a
  # bounded marker carrying a utf8-safe JSON prefix + the original byte size.
  defp fit_leaf(leaf, per_leaf) do
    encoded = Jason.encode!(leaf)
    size = byte_size(encoded)

    if size <= per_leaf do
      leaf
    else
      preview =
        encoded
        |> binary_part(0, min(per_leaf, size))
        |> OutputLimit.valid_utf8_prefix()

      %{"truncated" => true, "preview" => preview, "bytes" => size}
    end
  end

  # Fold events into a page whose SERIALIZED size stays within budget: seed with
  # the "[]" framing and add a "," per extra element, so the accumulated total is
  # exactly `byte_size(Jason.encode!(page))`. Always keep ≥1 event — fit_event/2
  # guarantees a lone event fits under the frame reserve, so `[event]` ≤ budget.
  #
  # Returns `{page (seq-ascending), cursor}`. The reduce accumulates NEWEST-first,
  # so its head is the last kept event: the cursor (its seq) is read O(1) off that
  # head — avoiding an O(n) `List.last/1` on the reversed page.
  defp byte_fold(events, budget) do
    {acc, _total} =
      Enum.reduce_while(events, {[], @list_frame_bytes}, fn event, {acc, total} ->
        sep = if acc == [], do: 0, else: @element_sep_bytes
        next_total = total + sep + json_size(event)

        cond do
          acc == [] -> {:cont, {[event], next_total}}
          next_total > budget -> {:halt, {acc, total}}
          true -> {:cont, {[event | acc], next_total}}
        end
      end)

    {Enum.reverse(acc), cursor(acc)}
  end

  # acc is newest-first; its head is the last kept event (O(1)). Empty page (no
  # events at all) has no cursor.
  defp cursor([latest | _]), do: latest["seq"]
  defp cursor([]), do: nil

  defp json_size(term), do: byte_size(Jason.encode!(term))

  defp scope_keys, do: [:tenant_id, :actor]
end
