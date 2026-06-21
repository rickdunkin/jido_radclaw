defmodule JidoClaw.RouteComposer.Commit do
  @moduledoc """
  The one place a composer wave's durable effects are welded together (AR-2
  Phase 2c): the `wave_completed` marker, the wave's content deltas
  (`signals_published`/`signals_retracted`/`artifacts_produced`), and the
  `ComposerArtifact` `:pending → :active` ref state-flip — all in a single
  `Ash.transact([WorkflowEvent, WorkflowRun, ComposerArtifact])`. **Any leg
  failing rolls back the whole wave commit**, so the `:active` set is always a
  pure function of the durable log: no orphaned `:active` row, no half-written
  delta log.

  ## Parent-status guard (load-bearing)

  `wave_completed` and the content events are deliberately **non-status-authority**
  (the parent stays `:running` across a wave), so `WorkflowEvent.Changes.Allocate`
  does **not** status-check them (`allocate.ex` guards authority kinds only) — it
  would happily append them, and `activate_for_wave` would promote refs, onto an
  **already-terminal** parent (e.g. an operator cancel landing while a child wave
  returns). So `guarded_wave_txn/4` **reloads the parent `FOR UPDATE`** (the
  `Allocate.lock_run` precedent) inside the txn and returns `{:error,
  :parent_terminal}` **before any append/activate** when the reloaded status is
  terminal. The loop treats `:parent_terminal` as "the run already ended" → stop
  cleanly, don't re-terminalize.

  `start_wave/3` shares that exact fence for the **pre-launch** markers
  (`route_composed` + `wave_started`), which are likewise non-status-authority and
  would otherwise land on an already-terminal parent. Routing them through the same
  FOR-UPDATE guard closes the marker-append TOCTOU a best-effort reload would leave:
  the cancel path also locks the run row FOR UPDATE (to append `run_cancelled`), so
  the two serialize — markers never land on an already-terminal parent.

  Scope: this fences the parent's *durable state* (these markers here; the wave
  commit in `commit_wave/4`), **not** the composer's child-run launch.
  `ReactorRunner` creates the wave's child run *after* `start_wave/3` releases the
  lock, with no parent-terminal check, so a cancel landing in that narrow window
  still spawns an in-flight child — whose fold is then fenced at `commit_wave/4`
  (same as the already-accepted `async_nolink` "wave survives a kill"). Closing that
  child-create window (composer cancellation / coupling the terminal check to child
  creation) is deferred Phase 4 work.

  ## Why not `WorkflowLog.append_all/3`

  `append_all/3` transacts `WorkflowEvent` only (`workflow_log.ex`); the ref
  state-flip needs `ComposerArtifact` in the same transaction.

  ## Return unwrap

  Both `commit_wave/4` and `start_wave/3` share one `guarded_wave_txn/4` skeleton,
  unwrapped by `unwrap_transact/1`. `Ash.transact/2` **wraps** a successful fn
  result, so the `:ok`-returning fn yields `{:ok, :ok}` → `:ok`. The
  terminal-parent guard returns the bare atom `:parent_terminal` from the fn (an
  empty read-only txn that commits harmlessly), yielding `{:ok, :parent_terminal}`
  → remapped to `{:error, :parent_terminal}` there; this keeps the atom visible to
  callers (routing it through the txn's error channel lets Ash.transact's
  polymorphic-return type erase it). A fn returning `{:error, _}` rolls the txn
  back and stays `{:error, _}`.
  """

  require Ash.Query, as: Query

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowEvent.Projection
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun

  @type deltas :: %{
          optional(:stages) => [String.t()],
          optional(:signals_published) => [String.t()],
          optional(:signals_retracted) => [String.t()],
          optional(:artifacts_produced) => [%{optional(atom()) => String.t()}]
        }

  @doc """
  Commit one wave's durable effects atomically. `deltas` is the JSON-safe delta
  map the loop derives by diffing pre/post `Fold` state. Returns `:ok`,
  `{:error, :parent_terminal}` (the run ended externally — stop, do not
  re-terminalize), or `{:error, reason}` (a leg failed — terminalize the parent).
  """
  @spec commit_wave(WorkflowRun.t(), non_neg_integer(), deltas(), keyword()) ::
          :ok | {:error, term()}
  def commit_wave(%WorkflowRun{} = parent, wave_index, deltas, opts) do
    guarded_wave_txn(
      [WorkflowEvent, WorkflowRun, ComposerArtifact],
      parent,
      opts,
      fn locked -> do_commit(locked, wave_index, deltas, opts) end
    )
  end

  @doc """
  Atomically append a wave's pre-launch markers (`route_composed` + `wave_started`)
  under the SAME FOR-UPDATE parent-terminal guard as `commit_wave/4`. `markers` is
  an ordered `[{kind, payload}]`. Returns `:ok`, `{:error, :parent_terminal}` (the
  run ended externally — stop, do not re-terminalize), or `{:error, reason}` (a leg
  failed). Closes the **marker-append** TOCTOU a best-effort reload would leave: the
  cancel path also locks the run row FOR UPDATE (to append `run_cancelled` via
  `Allocate.lock_run`), so markers never land on an already-terminal parent. (Does
  NOT fence the later child-run launch — see the moduledoc Scope note.)
  """
  @spec start_wave(WorkflowRun.t(), [{atom(), map()}], keyword()) :: :ok | {:error, term()}
  def start_wave(%WorkflowRun{} = parent, markers, opts) do
    guarded_wave_txn(
      [WorkflowEvent, WorkflowRun],
      parent,
      opts,
      fn locked -> append_each(locked, markers, opts) end
    )
  end

  # `commit_wave/4` and `start_wave/3` differ only in the resources touched and the
  # work run under the lock. A terminal parent → `:parent_terminal` BEFORE any write
  # (the read-only txn commits harmlessly); else `proceed_fun` runs under the held
  # FOR UPDATE lock.
  defp guarded_wave_txn(resources, parent, opts, proceed_fun) do
    resources
    |> Ash.transact(fn ->
      with {:ok, locked} <- reload_for_update(parent, opts) do
        if Projection.terminal_status?(locked.status),
          do: :parent_terminal,
          else: proceed_fun.(locked)
      end
    end)
    |> unwrap_transact()
  end

  # `Ash.transact` wraps the fn's non-error return as `{:ok, _}`. The terminal guard
  # deliberately travels the SUCCESS channel as the bare atom `:parent_terminal` (an
  # empty read-only txn — only the FOR UPDATE SELECT ran, so committing it is
  # harmless), remapped to a distinct `{:error, :parent_terminal}` HERE: routing it
  # through the txn's error channel would let Ash.transact's polymorphic-return
  # analysis erase the atom from callers' view. A real leg failure stays
  # `{:error, reason}` (the fn returned `{:error, _}`, rolling the txn back).
  defp unwrap_transact({:ok, :ok}), do: :ok
  defp unwrap_transact({:ok, :parent_terminal}), do: {:error, :parent_terminal}
  defp unwrap_transact({:error, reason}), do: {:error, reason}

  defp do_commit(locked, wave_index, deltas, opts) do
    with {:ok, _marker} <-
           WorkflowLog.append(
             locked,
             :wave_completed,
             wave_completed_payload(wave_index, deltas),
             opts
           ),
         :ok <- append_each(locked, content_events(deltas), opts),
         {:ok, _promoted} <- ComposerArtifact.activate_for_wave(locked.id, wave_index, opts) do
      :ok
    end
  end

  # FOR UPDATE on the parent row — the same per-run serialization point Allocate
  # uses (`allocate.ex`). Re-locking the same row within this txn is fine
  # (Postgres FOR UPDATE is re-entrant per transaction).
  defp reload_for_update(%WorkflowRun{id: id}, opts) do
    WorkflowRun
    |> Query.filter(id == ^id)
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one(tenant: opts[:tenant], actor: opts[:actor])
    |> case do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :parent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wave_completed_payload(wave_index, deltas) do
    %{wave_index: wave_index, stages: list(deltas, :stages)}
  end

  # Only the non-empty deltas become events (an empty-emission wave still writes
  # `wave_completed`, but no content). Deterministic order: published → retracted
  # → produced.
  defp content_events(deltas) do
    Enum.reject(
      [
        signals_event(:signals_published, list(deltas, :signals_published)),
        signals_event(:signals_retracted, list(deltas, :signals_retracted)),
        artifacts_event(list(deltas, :artifacts_produced))
      ],
      &is_nil/1
    )
  end

  defp signals_event(_kind, []), do: nil
  defp signals_event(kind, signals), do: {kind, %{signals: signals}}

  defp artifacts_event([]), do: nil
  defp artifacts_event(entries), do: {:artifacts_produced, %{artifacts: entries}}

  # Sequential appends inside the caller's transaction; `[]` is success (empty
  # content list — empty-emission waves are explicitly supported).
  defp append_each(_run, [], _opts), do: :ok

  defp append_each(run, events, opts) do
    Enum.reduce_while(events, :ok, fn {kind, payload}, :ok ->
      case WorkflowLog.append(run, kind, payload, opts) do
        {:ok, _event} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list(deltas, key), do: Map.get(deltas, key, [])
end
