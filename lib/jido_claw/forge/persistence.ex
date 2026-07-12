defmodule JidoClaw.Forge.Persistence do
  @moduledoc false
  require Logger
  require Ash.Query

  # Ash CRUD + Postgrex faults this best-effort persistence layer can hit;
  # rescues narrow to these so an unexpected error (a real bug) surfaces
  # instead of being logged-and-swallowed.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  alias Ash.Query
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Forge.Resources.Checkpoint
  alias JidoClaw.Forge.Resources.Event
  alias JidoClaw.Forge.Resources.Session
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Security.Redaction.Patterns

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(Application.get_env(:jido_claw, __MODULE__, []), :enabled, true)
  end

  @spec record_session_started(String.t(), map()) :: Session.t() | nil
  def record_session_started(session_id, spec) do
    if enabled?() do
      case scope_from_spec(spec) do
        {:ok, scope} ->
          attrs = Map.put(session_attrs(session_id, spec), :workspace_id, scope.workspace_id)
          create_session_record(attrs, scope)

        {:error, reason} ->
          Logger.warning("[Forge.Persistence] Missing Forge session scope: #{inspect(reason)}")
          nil
      end
    end
  end

  defp create_session_record(attrs, scope) do
    case Ash.create(Session, attrs,
           action: :start,
           tenant: scope.tenant_id,
           actor: scope.actor
         ) do
      {:ok, session} ->
        session

      {:error, e} ->
        Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
        nil
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] Failed to record session: #{inspect(e)}")
  end

  @terminal_phases [:completed, :cancelled, :failed]
  # Phases left by a crashed process — reclaimable during recovery.
  # Excludes :created (means another node just claimed it in this cycle).
  @recoverable_phases [:running, :ready, :needs_input, :provisioning, :bootstrapping, :resuming]

  @doc """
  Atomically claim ownership of a session_id across the cluster.

  Uses a PostgreSQL advisory lock (`pg_advisory_xact_lock`) inside a
  transaction to serialize all claim attempts for the same session_id.
  This makes every path — new names, terminal reuse, and recovery —
  fully atomic across nodes.

  Options:
    - `recovery: true` — allows claiming a session whose DB row is in
      an active phase (the process crashed, leaving stale state).
      Without this flag, active-phase rows are rejected as a safety net.

  Returns `:ok`, `{:error, :already_claimed}`, or `{:error, :scope_required}`
  when the spec carries no tenant/workspace scope (callers must handle the
  latter — see `JidoClaw.Forge.Harness.stop_unclaimed_session/2`).
  When persistence is disabled (tests), returns `:ok` unconditionally.
  """
  @spec claim_session(String.t(), map(), keyword()) ::
          :ok | {:error, :already_claimed} | {:error, :scope_required}
  def claim_session(session_id, spec, opts \\ []) do
    if enabled?(), do: do_claim_session(session_id, spec, opts), else: :ok
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] claim_session failed: #{inspect(e)}")
      {:error, :already_claimed}
  end

  defp do_claim_session(session_id, spec, opts) do
    with {:ok, scope} <- scope_from_spec(spec) do
      recovery? = Keyword.get(opts, :recovery, false)

      attrs = Map.put(session_attrs(session_id, spec), :workspace_id, scope.workspace_id)

      session_id
      |> claim_transaction(attrs, scope, recovery?)
      |> normalize_claim_result()
    end
  end

  defp claim_transaction(session_id, attrs, scope, recovery?) do
    Ash.transaction(Session, fn ->
      JidoClaw.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [session_id])
      claim_after_lock(find_session(session_id, scope), attrs, scope, recovery?)
    end)
  end

  defp normalize_claim_result({:ok, :ok}), do: :ok
  defp normalize_claim_result({:error, _}), do: {:error, :already_claimed}

  # No existing row — create fresh. Upsert just inserts when no matching row
  # exists, so :start is safe for both paths.
  defp claim_after_lock(nil, attrs, scope, _recovery?), do: claim_via_start(attrs, scope)

  # Terminal session — reuse the name via upsert, preserving the row ID so FK
  # relationships to events/checkpoints are maintained.
  defp claim_after_lock(%{phase: phase}, attrs, scope, _recovery?)
       when phase in @terminal_phases do
    claim_via_start(attrs, scope)
  end

  # Recovery: stale active phase from a crashed process. :created is excluded
  # from @recoverable_phases because it means another node just claimed.
  defp claim_after_lock(%{phase: phase}, attrs, scope, true)
       when phase in @recoverable_phases do
    claim_via_start(attrs, scope)
  end

  # Either a fresh start seeing an active row, or recovery seeing :created.
  defp claim_after_lock(%{}, _attrs, _scope, _recovery?) do
    Ash.DataLayer.rollback(Session, :already_claimed)
  end

  defp claim_via_start(attrs, scope) do
    case Ash.create(Session, attrs,
           action: :start,
           tenant: scope.tenant_id,
           actor: scope.actor
         ) do
      {:ok, _} -> :ok
      {:error, e} -> Ash.DataLayer.rollback(Session, {:start_failed, e})
    end
  end

  defp session_attrs(session_id, spec) do
    %{
      name: session_id,
      runner_type: to_string(Map.get(spec, :runner, :shell)),
      runner_config: Map.get(spec, :runner_config, %{}),
      spec: redact_map(spec),
      started_at: DateTime.utc_now()
    }
  end

  @spec record_execution_complete(
          String.t(),
          String.t() | nil,
          integer() | nil,
          non_neg_integer(),
          atom() | nil,
          DateTime.t() | nil
        ) :: map() | nil
  def record_execution_complete(
        session_id,
        output,
        exit_code,
        sequence,
        runner_status \\ nil,
        started_at \\ nil
      ) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          base_attrs = %{
            session_id: session.id,
            sequence: sequence,
            command: "iteration"
          }

          start_attrs =
            if started_at,
              do: Map.put(base_attrs, :started_at, started_at),
              else: base_attrs

          case Ash.create(JidoClaw.Forge.Resources.ExecSession, start_attrs) do
            {:ok, exec_session} ->
              finish_execution(exec_session, output, exit_code, runner_status)

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to start exec session: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to record execution: #{inspect(e)}")
      end
    end
  end

  defp finish_execution(exec_session, output, exit_code, runner_status) do
    result_status =
      case runner_status do
        :error -> :failed
        _ -> if exit_code == 0, do: :completed, else: :failed
      end

    raw_output_bytes = byte_size(output || "")

    exec_session
    |> Ash.Changeset.for_update(:complete, %{
      result_status: result_status,
      output: truncate(Patterns.redact(output || ""), 10_000),
      exit_code: exit_code,
      raw_output_bytes: raw_output_bytes
    })
    |> Ash.update()
    |> case do
      {:ok, exec} ->
        exec

      {:error, e} ->
        Logger.warning("[Forge.Persistence] Failed to complete exec session: #{inspect(e)}")
        nil
    end
  end

  @spec log_event(String.t(), atom() | String.t(), map(), non_neg_integer() | nil) ::
          Event.t() | nil
  def log_event(session_id, event_type, data \\ %{}, exec_session_sequence \\ nil) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          base_attrs = %{
            session_id: session.id,
            event_type: to_string(event_type),
            data: redact_map(data)
          }

          attrs =
            if exec_session_sequence,
              do: Map.put(base_attrs, :exec_session_sequence, exec_session_sequence),
              else: base_attrs

          case Ash.create(JidoClaw.Forge.Resources.Event, attrs) do
            {:ok, event} ->
              event

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to log event: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to log event: #{inspect(e)}")
      end
    end
  end

  @spec update_session_phase(String.t(), atom()) :: Session.t() | nil
  def update_session_phase(session_id, phase) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          session
          |> Ash.Changeset.for_update(:update_phase, %{phase: phase})
          |> Ash.update(session_action_opts(session))
          |> case do
            {:ok, updated} ->
              updated

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to update session phase: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to update session phase: #{inspect(e)}")
      end
    end
  end

  # AR-8b-2 F2 (1.3): mirror `update_session_phase/2` but call the `:complete`
  # action (`session.ex` — sets `phase: :completed` AND stamps `completed_at`; the
  # generic `:update_phase` does not). Best-effort (log + nil on error), so the
  # `:complete` Harness handler can swallow a failed stamp and let `terminate/2`'s
  # `:normal`-fallback finalize `:completed` anyway.
  @spec complete_session(String.t()) :: Session.t() | nil
  def complete_session(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          session
          |> Ash.Changeset.for_update(:complete, %{})
          |> Ash.update(session_action_opts(session))
          |> case do
            {:ok, updated} ->
              updated

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to complete session: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to complete session: #{inspect(e)}")
      end
    end
  end

  @spec record_sandbox_id(String.t(), String.t()) :: Session.t() | nil
  def record_sandbox_id(session_id, sandbox_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          session
          |> Ash.Changeset.for_update(:set_sandbox_id, %{sandbox_id: sandbox_id})
          |> Ash.update(session_action_opts(session))
          |> case do
            {:ok, updated} ->
              updated

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to record sandbox_id: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to record sandbox_id: #{inspect(e)}")
      end
    end
  end

  @spec save_checkpoint(String.t(), non_neg_integer(), map(), map()) :: Checkpoint.t() | nil
  def save_checkpoint(session_id, sequence, runner_state_snapshot, metadata \\ %{}) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          attrs = %{
            session_id: session.id,
            exec_session_sequence: sequence,
            runner_state_snapshot: runner_state_snapshot,
            metadata: metadata
          }

          case Ash.create(JidoClaw.Forge.Resources.Checkpoint, attrs) do
            {:ok, checkpoint} ->
              checkpoint

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to save checkpoint: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to save checkpoint: #{inspect(e)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Resume/recovery fence (docs/system/forge-session-resume.md)
  #
  # The incarnation fence lives at metadata["forge_recovery"] = {epoch, token,
  # current_checkpoint_id, recovery_degraded}. The token authorizes WRITES
  # only (reads compare epoch stamps); it is minted here and never stored in
  # any state copy.
  # ---------------------------------------------------------------------------

  @typedoc "The stored incarnation pair used as the mint's CAS expectation."
  @type recovery_pair :: %{epoch: non_neg_integer(), token: String.t()}

  @typedoc """
  What the mint installs at `metadata["resume"]`: `nil`/blank for fresh
  starts and terminal reuse, a `ResumeState` for a pre-selected transplant,
  or a selector fun invoked on the LOCKED session row (recovery — selection
  and mint must share one critical section).
  """
  @type transplant ::
          ResumeState.t() | nil | (Session.t() -> ResumeState.t() | nil)

  @doc """
  Reads the stored `{epoch, token}` pair (the mint's CAS expectation).
  `nil` when no pair has ever been minted — the only case where
  `mint_resume_epoch/3` accepts `expected: nil`.
  """
  @spec stored_recovery_pair(String.t()) :: recovery_pair() | nil
  def stored_recovery_pair(session_id) do
    if enabled?() do
      case find_session(session_id) do
        nil -> nil
        session -> recovery_pair_of(session)
      end
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] stored_recovery_pair failed: #{inspect(e)}")
      nil
  end

  @doc """
  Mint a new incarnation: CAS from `expected` (the prior stored pair; `nil`
  ONLY when no pair exists at all), increment the epoch, rotate the token,
  install the transplant at `{new epoch, revision 0}`, and clear the
  checkpoint pointer + degraded marker — one locked critical section
  (Session row FOR UPDATE across read-select-mint, so an outliving old
  task cannot move state between selection and install).

  A stale holder gets `{:error, :stale_mint}` and can never rotate the
  legitimate incarnation's token.
  """
  @spec mint_resume_epoch(String.t(), recovery_pair() | nil, transplant()) ::
          {:ok, %{epoch: pos_integer(), token: String.t()}}
          | {:error, :stale_mint | :no_session | :mint_failed | :persistence_disabled}
  def mint_resume_epoch(session_id, expected, transplant) do
    if enabled?() do
      Session
      |> Ash.transaction(fn -> locked_mint(session_id, expected, transplant) end)
      |> normalize_mint_result()
    else
      {:error, :persistence_disabled}
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] mint_resume_epoch failed: #{inspect(e)}")
      {:error, :mint_failed}
  end

  # Refusals are TAGGED SUCCESS values (nothing written yet) — an in-txn
  # {:error, _} return would be wrapped opaque by Ash.transaction and the
  # classification lost (the GateDisposition-documented behavior). Only a
  # genuine write failure rolls back.
  defp locked_mint(session_id, expected, transplant) do
    case lock_session_row(session_id) do
      nil ->
        {:refused, :no_session}

      session ->
        if pair_matches?(recovery_pair_of(session), expected) do
          install_mint(session, expected, transplant)
        else
          {:refused, :stale_mint}
        end
    end
  end

  # FOR-UPDATE via manual `Ash.Query.lock/2` composition on the interface's
  # query builder: a DSL `prepare(build(lock: "FOR UPDATE"))` read action
  # silently returns zero rows on this Ash version (probe-verified), while
  # the composed lock emits the expected `SELECT ... FOR UPDATE`.
  defp lock_session_row(session_id) do
    session_id
    |> Session.query_to_by_name_global()
    |> Query.lock("FOR UPDATE")
    |> Ash.read_one()
    |> case do
      {:ok, %Session{} = session} -> session
      _ -> nil
    end
  end

  defp recovery_pair_of(%Session{metadata: %{"forge_recovery" => %{} = recovery}}) do
    case {recovery["epoch"], recovery["token"]} do
      {epoch, token} when is_integer(epoch) and epoch > 0 and is_binary(token) ->
        %{epoch: epoch, token: token}

      _ ->
        nil
    end
  end

  defp recovery_pair_of(%Session{}), do: nil

  defp pair_matches?(nil, nil), do: true

  defp pair_matches?(%{epoch: epoch, token: token}, %{epoch: epoch, token: token}), do: true

  defp pair_matches?(_stored, _expected), do: false

  defp install_mint(session, expected, transplant) do
    new_epoch = ((expected && expected.epoch) || 0) + 1
    token = Ecto.UUID.generate()

    resume_object =
      case resolve_transplant(transplant, session) do
        nil ->
          %{}

        %ResumeState{} = rs ->
          stamped = ResumeState.stamp(rs, new_epoch, 0)

          put_present(
            %{"state" => ResumeState.encode_state(stamped)},
            "guidance",
            ResumeState.encode_guidance_marker(stamped)
          )
      end

    forge_recovery = %{
      "epoch" => new_epoch,
      "token" => token,
      "current_checkpoint_id" => nil,
      "recovery_degraded" => false
    }

    session
    |> Ash.Changeset.for_update(:mint_forge_recovery, %{
      forge_recovery: forge_recovery,
      resume: resume_object
    })
    |> Ash.update(session_action_opts(session))
    |> case do
      {:ok, _} -> {:minted, %{epoch: new_epoch, token: token}}
      {:error, e} -> Ash.DataLayer.rollback(Session, {:mint_write_failed, e})
    end
  end

  defp resolve_transplant(fun, session) when is_function(fun, 1), do: fun.(session)
  defp resolve_transplant(transplant, _session), do: transplant

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_mint_result({:ok, {:minted, pair}}), do: {:ok, pair}
  defp normalize_mint_result({:ok, {:refused, reason}}), do: {:error, reason}

  defp normalize_mint_result({:error, e}) do
    Logger.warning("[Forge.Persistence] mint_resume_epoch rolled back: #{inspect(e)}")
    {:error, :mint_failed}
  end

  @doc """
  Best-effort FENCED mirror of the sanitized anchor state to
  `metadata["resume"]["state"]` after an iteration. Infrastructure
  failures log + `nil` (the mirror is best-effort); a fence miss is a
  real `{:error, :stale_resume_write}` — the caller logs and DROPS the
  write, never treats it as success.
  """
  @spec anchor_session(String.t(), ResumeState.t(), String.t()) ::
          :ok | {:error, :stale_resume_write} | nil
  def anchor_session(session_id, %ResumeState{} = resume, incarnation_token)
      when is_binary(incarnation_token) do
    if enabled?() do
      case find_session(session_id) do
        nil ->
          nil

        session ->
          encoded = ResumeState.encode_state(resume)

          case Session.anchor_resume(
                 session,
                 encoded,
                 incarnation_token,
                 session_action_opts(session)
               ) do
            {:ok, _} ->
              :ok

            {:error, e} ->
              classify_fenced_write_error(e, "anchor_session")
          end
      end
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] anchor_session failed: #{inspect(e)}")
      nil
  end

  @doc """
  The CHECKED checkpoint save: fenced pointer move (sets
  `current_checkpoint_id`, clears `recovery_degraded`, mirrors the
  guidance marker) THEN the Checkpoint row under a pre-minted id — one
  transaction, pointer-first so a stale refusal writes nothing. Unlike
  `save_checkpoint/4` this is NOT best-effort: every failure is a real
  error the caller must handle (`apply_input` ack, `recovery_degraded`).
  """
  @spec save_recovery_checkpoint(
          String.t(),
          non_neg_integer(),
          map(),
          map(),
          map() | nil,
          String.t()
        ) ::
          {:ok, Checkpoint.t()}
          | {:error, :stale_resume_write | :no_session | :not_persisted | :persistence_disabled}
  def save_recovery_checkpoint(
        session_id,
        sequence,
        runner_state_snapshot,
        metadata,
        guidance_marker,
        incarnation_token
      )
      when is_binary(incarnation_token) do
    if enabled?() do
      [Session, Checkpoint]
      |> Ash.transaction(fn ->
        checked_checkpoint_txn(
          session_id,
          sequence,
          runner_state_snapshot,
          metadata,
          guidance_marker,
          incarnation_token
        )
      end)
      |> normalize_checked_save_result()
    else
      {:error, :persistence_disabled}
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] save_recovery_checkpoint failed: #{inspect(e)}")
      {:error, :not_persisted}
  end

  defp checked_checkpoint_txn(
         session_id,
         sequence,
         runner_state_snapshot,
         metadata,
         guidance_marker,
         incarnation_token
       ) do
    case find_session(session_id) do
      nil ->
        {:refused, :no_session}

      session ->
        checkpoint_id = Ecto.UUID.generate()

        case Session.point_recovery_checkpoint(
               session,
               checkpoint_id,
               guidance_marker,
               incarnation_token,
               session_action_opts(session)
             ) do
          {:ok, _} ->
            create_pointed_checkpoint(
              session,
              checkpoint_id,
              sequence,
              runner_state_snapshot,
              metadata
            )

          {:error, e} ->
            if AshErrors.stale_write?(e) or AshErrors.not_found?(e) do
              {:refused, :stale_resume_write}
            else
              Ash.DataLayer.rollback(Session, {:pointer_write_failed, e})
            end
        end
    end
  end

  defp create_pointed_checkpoint(session, checkpoint_id, sequence, snapshot, metadata) do
    case Ash.create(
           Checkpoint,
           %{
             checkpoint_id: checkpoint_id,
             session_id: session.id,
             exec_session_sequence: sequence,
             runner_state_snapshot: snapshot,
             metadata: metadata
           },
           action: :create_recovery
         ) do
      {:ok, checkpoint} -> {:saved, checkpoint}
      {:error, e} -> Ash.DataLayer.rollback(Checkpoint, {:checkpoint_write_failed, e})
    end
  end

  defp normalize_checked_save_result({:ok, {:saved, checkpoint}}), do: {:ok, checkpoint}
  defp normalize_checked_save_result({:ok, {:refused, reason}}), do: {:error, reason}

  defp normalize_checked_save_result({:error, e}) do
    Logger.warning("[Forge.Persistence] save_recovery_checkpoint rolled back: #{inspect(e)}")
    {:error, :not_persisted}
  end

  @doc """
  Token-fenced `recovery_degraded: true` marker (a failed initial checked
  checkpoint). A stale incarnation's attempt surfaces
  `{:error, :stale_resume_write}` and can never degrade a newer one.
  """
  @spec mark_recovery_degraded(String.t(), String.t()) ::
          :ok | {:error, :stale_resume_write} | nil
  def mark_recovery_degraded(session_id, incarnation_token)
      when is_binary(incarnation_token) do
    if enabled?() do
      case find_session(session_id) do
        nil ->
          nil

        session ->
          case Session.mark_recovery_degraded(
                 session,
                 incarnation_token,
                 session_action_opts(session)
               ) do
            {:ok, _} -> :ok
            {:error, e} -> classify_fenced_write_error(e, "mark_recovery_degraded")
          end
      end
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] mark_recovery_degraded failed: #{inspect(e)}")
      nil
  end

  defp classify_fenced_write_error(e, label) do
    if AshErrors.stale_write?(e) or AshErrors.not_found?(e) do
      {:error, :stale_resume_write}
    else
      Logger.warning("[Forge.Persistence] #{label} failed: #{inspect(e)}")
      nil
    end
  end

  @doc """
  The pointer-selected checkpoint — the ONLY checkpoint-selection authority
  for recovery (`Manager.recoverable?/1`, `Forge.wake/2`,
  `context_for_resume/1`): reads
  `metadata["forge_recovery"]["current_checkpoint_id"]`, loads the row, and
  REQUIRES `checkpoint.session_id == session.id` (a foreign or dangling
  pointer is corruption — logged, and recovery refuses). Only the checked
  `save_recovery_checkpoint/6` moves the pointer, so wall-clock
  `latest_checkpoint/1` ordering never decides what a session resumes from.
  """
  @spec current_checkpoint(String.t()) :: Checkpoint.t() | nil
  def current_checkpoint(session_id) do
    if enabled?() do
      case find_session(session_id) do
        nil -> nil
        session -> pointed_checkpoint(session)
      end
    end
  rescue
    e in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      Logger.warning("[Forge.Persistence] current_checkpoint failed: #{inspect(e)}")
      nil
  end

  # Public (@doc false) for the Harness's recovery transplant selector, which
  # runs inside the mint's locked critical section and must read the pointer
  # from the LOCKED row it was handed — not through a second `find_session`
  # read that could see a different row version.
  @doc false
  @spec pointed_checkpoint(Session.t()) :: Checkpoint.t() | nil
  def pointed_checkpoint(%Session{} = session) do
    case get_in(session.metadata, ["forge_recovery", "current_checkpoint_id"]) do
      pointer when is_binary(pointer) -> load_pointed_checkpoint(session, pointer)
      _absent -> nil
    end
  end

  defp load_pointed_checkpoint(session, pointer) do
    case Checkpoint.get_by_id(pointer) do
      {:ok, %Checkpoint{session_id: owner_id} = checkpoint} when owner_id == session.id ->
        checkpoint

      {:ok, %Checkpoint{}} ->
        Logger.warning(
          "[Forge.Persistence] recovery pointer for #{session.name} names a foreign checkpoint — refusing"
        )

        nil

      {:error, _not_found_or_invalid} ->
        Logger.warning(
          "[Forge.Persistence] recovery pointer for #{session.name} is dangling — refusing"
        )

        nil
    end
  end

  # Wall-clock newest row — a query helper for inspection surfaces, NOT a
  # recovery-selection authority (recovery selects via `current_checkpoint/1`).
  @spec latest_checkpoint(String.t()) :: Checkpoint.t() | nil
  def latest_checkpoint(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          Checkpoint.query_to_latest_for_session(%{session_id: session.id})
          |> Ash.read()
          |> case do
            {:ok, checkpoints} ->
              List.first(checkpoints)

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to get latest checkpoint: #{inspect(e)}")
              nil
          end
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to get latest checkpoint: #{inspect(e)}")
          nil
      end
    end
  end

  @spec get_events(String.t(), keyword()) :: [Event.t()]
  def get_events(session_id, opts \\ []) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          args = %{session_id: session.id}

          args =
            if opts[:after_timestamp],
              do: Map.put(args, :after, opts[:after_timestamp]),
              else: args

          args =
            if opts[:after_sequence],
              do: Map.put(args, :after_sequence, opts[:after_sequence]),
              else: args

          args =
            if opts[:event_types], do: Map.put(args, :event_types, opts[:event_types]), else: args

          args = if opts[:limit], do: Map.put(args, :limit, opts[:limit]), else: args

          Event.query_to_list_for_session(args)
          |> Ash.read()
          |> case do
            {:ok, events} ->
              events

            {:error, e} ->
              Logger.warning("[Forge.Persistence] Failed to get events: #{inspect(e)}")
              []
          end
        else
          []
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to get events: #{inspect(e)}")
          []
      end
    else
      []
    end
  end

  @spec context_for_resume(String.t()) :: map() | nil
  def context_for_resume(session_id) do
    if enabled?() do
      try do
        session = find_session(session_id)

        if session do
          # Pointer-selected: "events since" keys off the checkpoint recovery
          # would actually restore, not whatever row is wall-clock newest.
          checkpoint = pointed_checkpoint(session)

          events_since =
            case checkpoint do
              %{created_at: ts} ->
                get_events(session_id, after_timestamp: ts)

              _ ->
                get_events(session_id)
            end

          all_events = get_events(session_id)

          last_output = latest_exec_output(session)

          error_events =
            Enum.filter(all_events, fn e ->
              String.contains?(e.event_type, "failed") or
                iteration_error?(e)
            end)

          iteration_count =
            Enum.count(all_events, &(&1.event_type == "iteration.completed"))

          %{
            session: session,
            last_checkpoint: checkpoint,
            events_since_checkpoint: events_since,
            iteration_count: iteration_count,
            last_output: last_output,
            error_history: error_events
          }
        end
      rescue
        e in @db_errors ->
          # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
          Logger.warning("[Forge.Persistence] Failed to build context_for_resume: #{inspect(e)}")
          nil
      end
    end
  end

  @spec find_session(String.t()) :: Session.t() | nil
  def find_session(session_id) do
    find_session_global(session_id)
  end

  @spec find_session(String.t(), map() | keyword()) :: Session.t() | nil
  def find_session(session_id, %{tenant_id: tenant_id, actor: actor})
      when is_binary(tenant_id) do
    Session
    |> Query.filter(name == ^session_id)
    |> Query.sort(inserted_at: :desc)
    |> Query.limit(1)
    |> Ash.read(tenant: tenant_id, actor: actor)
    |> case do
      {:ok, sessions} -> List.first(sessions)
      {:error, _} -> nil
    end
  rescue
    _ in @db_errors ->
      nil
  end

  def find_session(session_id, opts) when is_list(opts) do
    case scope_from_opts(opts) do
      {:ok, scope} -> find_session(session_id, scope)
      _ -> nil
    end
  end

  defp find_session_global(session_id) do
    case Session.by_name_global(session_id) do
      {:ok, session} -> session
      {:error, _} -> nil
    end
  rescue
    _ in @db_errors ->
      nil
  end

  defp scope_from_spec(spec) when is_map(spec) do
    tenant_id = Map.get(spec, :tenant_id) || get_in(spec, [:tool_context, :tenant_id])

    workspace_id =
      Map.get(spec, :workspace_id) ||
        Map.get(spec, :workspace_uuid) ||
        get_in(spec, [:tool_context, :workspace_uuid])

    scope_from_values(tenant_id, workspace_id)
  end

  defp scope_from_spec(_), do: {:error, :scope_required}

  defp scope_from_opts(opts) when is_list(opts) do
    scope_from_values(Keyword.get(opts, :tenant_id), Keyword.get(opts, :workspace_id))
  end

  defp scope_from_values(tenant_id, workspace_id)
       when is_binary(tenant_id) and tenant_id != "" and is_binary(workspace_id) and
              workspace_id != "" do
    {:ok, %{tenant_id: tenant_id, workspace_id: workspace_id, actor: Actor.system(tenant_id)}}
  end

  defp scope_from_values(_tenant_id, _workspace_id), do: {:error, :scope_required}

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) -> {k, Patterns.redact(v)}
      {k, v} when is_map(v) -> {k, redact_map(v)}
      {k, v} when is_list(v) -> {k, redact_list(v)}
      pair -> pair
    end)
  end

  defp redact_map(other), do: other

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> redact_map(v)
      v when is_binary(v) -> Patterns.redact(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end

  defp truncate(str, max) when byte_size(str) > max do
    binary_part(str, byte_size(str) - max, max)
  end

  defp truncate(str, _max), do: str

  defp latest_exec_output(session) do
    JidoClaw.Forge.Resources.ExecSession
    |> Query.filter(session_id == ^session.id)
    |> Query.sort(sequence: :desc)
    |> Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [exec]} ->
        %{
          output: exec.output,
          exit_code: exec.exit_code,
          status: exec.status,
          sequence: exec.sequence
        }

      {:ok, []} ->
        nil

      {:error, _} ->
        nil
    end
  rescue
    _ in @db_errors -> nil
  end

  defp iteration_error?(%{event_type: "iteration.completed", data: data}) do
    status = MapKeys.coalesce_field(data, "status")
    status in [:error, "error"]
  end

  defp iteration_error?(_), do: false

  defp session_action_opts(%Session{tenant_id: tenant_id}) when is_binary(tenant_id) do
    [tenant: tenant_id, actor: Actor.system(tenant_id)]
  end
end
