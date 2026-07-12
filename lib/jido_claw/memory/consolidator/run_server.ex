defmodule JidoClaw.Memory.Consolidator.RunServer do
  @moduledoc """
  Per-run GenServer that drives a single consolidator pass for one
  scope.

  Lifecycle:
    1. `init/1` returns idle — pid registered, no work triggered.
    2. `run_now/2` issues `:await_and_start` which both registers
       the awaiter and triggers the first `:gate` message.
    3. `:gate` runs the policy resolver. Skip → finalise. Otherwise
       continue to `:acquire_lock`.
    4. `:acquire_lock` spawns a `LockOwner` Task. Busy → finalise.
    5. `:load_inputs` → `:cluster` → `:invoke_harness` (Forge
       session driven by a supervised Task).
    6. Harness Task replies via `{ref, result}` / `{:DOWN, ...}`.
    7. `:publish` writes Block/Fact/etc. mutations transactionally
       and writes the `ConsolidationRun` audit row.
    8. `finalise/3` cleans up (lock, MCP endpoint, temp file),
       replies to awaiters, stops the GenServer.

  Late awaiters arriving after `:terminal` get the cached
  `state.result`.
  """

  use GenServer
  require Logger

  # Ash CRUD + Postgrex faults the watermark/history Ash reads can hit;
  # narrowing keeps unexpected bugs surfacing instead of silently swallowed.
  @db_errors JidoClaw.Core.AshErrors.db_errors()

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Forge.ChildTracker
  alias JidoClaw.Forge.Harness
  alias JidoClaw.Forge.Manager, as: ForgeManager
  alias JidoClaw.Forge.Persistence, as: ForgePersistence
  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Memory.{Block, ConsolidationRun, Fact, Link, Scope}

  alias JidoClaw.MCP.ScopedEndpoint

  alias JidoClaw.Memory.Consolidator.{
    AttemptLedger,
    Clusterer,
    LockOwner,
    PolicyResolver,
    Staging
  }

  alias JidoClaw.Memory.Consolidator.Prompt

  @registry JidoClaw.Memory.Consolidator.RunRegistry

  @link_relations ~w(related supports contradicts supersedes elaborates)
  @link_relations_atoms Enum.map(@link_relations, &String.to_atom/1)

  # The whole-run budget default: today's facade posture (600s runner +
  # up to 60s bootstrap) — a whole-run ceiling, not a per-turn one.
  @default_max_run_ms 660_000
  # Below this remaining budget the loop stops opening attempts and a
  # retry/replay is never authorized.
  @deadline_floor_ms 5_000
  @default_max_iterations 8
  # Waiting for Manager recovery after an effect-free harness crash is
  # bounded by the remaining deadline AND this cap.
  @recovery_await_cap_ms 60_000
  @certificate_read_retry_ms 500

  defstruct [
    :run_id,
    :scope,
    :opts,
    :lock_owner_pid,
    :mcp_endpoint,
    :forge_session_id,
    :harness_task_ref,
    :harness_task_pid,
    :inputs,
    :messages,
    :clusters,
    :result,
    :effective_harness,
    :effective_harness_model,
    :run_forge_home,
    :deadline_at,
    :publish_task,
    awaiters: [],
    staging: nil,
    ledger: nil,
    attempt_config_paths: %{},
    max_run_ms: @default_max_run_ms,
    status: :idle,
    started_at: nil,
    harness_turns: 0
  ]

  @doc "Start a per-run server idle. Pid is registered under the run_id."
  @spec start_link(Scope.scope_record()) :: GenServer.on_start()
  def start_link(scope) do
    run_id = Ecto.UUID.generate()
    name = {:via, Registry, {@registry, run_id}}
    GenServer.start_link(__MODULE__, {run_id, scope}, name: name)
  end

  @impl GenServer
  def init({run_id, scope}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       run_id: run_id,
       scope: scope,
       opts: [],
       staging: Staging.new(),
       ledger: AttemptLedger.new(),
       status: :idle,
       started_at: DateTime.utc_now()
     }}
  end

  # -- Public message handlers --------------------------------------------------

  @impl GenServer
  def handle_call({:await_and_start, opts}, from, %{status: :idle} = state) do
    case resolve_effective_harness(opts) do
      {:ok, harness} ->
        send(self(), :gate)

        # `harness_options` is app-env only — there is no per-call
        # override beyond the harness selector itself. Shared keys
        # (`:sandbox_mode`, `:timeout_ms`, `:max_turns`) live at the top
        # level; harness-specific keys (e.g. `:model`,
        # `:thinking_effort`) live under `:claude_code` / `:codex` /
        # `:fake`. The cross-harness regression test uses
        # `Application.put_env` between runs to vary the nested model.
        harness_options = Keyword.get(consolidator_config(), :harness_options, [])

        effective_harness_model =
          harness_options
          |> harness_specific_options(harness)
          |> Keyword.get(:model)

        # The whole-run budget: minted from MONOTONIC time here, enforced by
        # the :run_deadline watchdog. Cancellation authority is the watchdog
        # alone — a caller's await_ms is a wait timeout, never cancellation.
        max_run_ms = Keyword.get(harness_options, :max_run_ms, @default_max_run_ms)
        deadline_at = System.monotonic_time(:millisecond) + max_run_ms
        Process.send_after(self(), :run_deadline, max_run_ms)

        {:noreply,
         %{
           state
           | status: :running,
             opts: opts,
             awaiters: [from],
             effective_harness: harness,
             effective_harness_model: effective_harness_model,
             max_run_ms: max_run_ms,
             deadline_at: deadline_at
         }}

      {:error, reason} ->
        # Fail fast — no `ConsolidationRun` row is written. The Ash
        # resource constraint only accepts known harness atoms, so
        # writing a row with `:unresolved` would fail validation.
        # Surface the configuration mistake directly to the caller.
        {:reply, {:error, reason}, state, {:continue, :stop}}
    end
  end

  def handle_call({:await_and_start, _opts}, _from, %{status: :terminal, result: result} = state) do
    {:reply, result, state, {:continue, :stop}}
  end

  def handle_call({:await_and_start, _opts}, from, state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  # MCP-tool envelopes, wrapped by `Tools.Helpers.call_run_server/2` with the
  # caller's attempt token from the tokenized endpoint path. Enforcement is
  # centralized HERE for every tool — readers included — so a stale CLI
  # holding a closed attempt's URL cannot even read retry state. Mutators
  # reserve on the ledger BEFORE the staging mutation executes; the whole
  # sequence is one GenServer message, so a close observes every
  # reservation (reserve-then-execute, serialized).
  def handle_call({:mcp_tool, attempt_token, msg}, _from, state) do
    case AttemptLedger.validate(state.ledger, attempt_token) do
      :ok ->
        tool_call(msg, attempt_token, state)

      {:error, :attempt_closed} ->
        {:reply, {:error, "attempt_closed"}, state}
    end
  end

  # The driver's per-turn capability mint: one open attempt at a time; the
  # tokenized URL + per-attempt 0600 config file ride `run_iteration` opts
  # only — never spec or checkpoint.
  def handle_call(:open_attempt, _from, state) do
    case AttemptLedger.open(state.ledger) do
      {:ok, token, ledger} ->
        case write_attempt_config(state, token) do
          {:ok, config_path, url} ->
            {:reply, {:ok, %{token: token, config_path: config_path, url: url}},
             %{
               state
               | ledger: ledger,
                 attempt_config_paths: Map.put(state.attempt_config_paths, token, config_path)
             }}

          {:error, reason} ->
            {:reply, {:error, {:attempt_config_failed, reason}}, state}
        end

      {:error, :attempt_already_open} ->
        {:reply, {:error, :attempt_already_open}, state}
    end
  end

  # Close-then-evaluate, serialized: the token is closed FIRST (later calls
  # bearing it are refused with the typed error), THEN the ledger decides
  # the directive. The attempt's config file is deleted here — its CLI has
  # exited by the time the driver closes.
  def handle_call({:close_attempt, token, outcome}, _from, state) do
    ctx = %{
      remaining_ms: remaining_ms(state),
      floor_ms: @deadline_floor_ms,
      recoverable?: recovery_possible?(state)
    }

    {directive, ledger} = AttemptLedger.close_and_evaluate(state.ledger, token, outcome, ctx)

    state =
      state
      |> Map.put(:ledger, ledger)
      |> delete_attempt_config(token)

    {:reply, directive, state}
  end

  defp tool_call({:propose_add, args}, token, state),
    do: stage_mutation(state, token, :fact_add, args)

  defp tool_call({:propose_update, args}, token, state),
    do: stage_mutation(state, token, :fact_update, args)

  defp tool_call({:propose_delete, args}, token, state),
    do: stage_mutation(state, token, :fact_delete, args)

  defp tool_call({:propose_link, args}, token, state),
    do: stage_mutation(state, token, :link_create, args)

  defp tool_call({:defer_cluster, args}, token, state),
    do: stage_mutation(state, token, :cluster_defer, args)

  defp tool_call({:propose_block_update, args}, token, state) do
    case AttemptLedger.reserve_mutation(state.ledger, token) do
      {:ok, ledger} ->
        case Staging.add_block_update(state.staging, args) do
          {:ok, staging} ->
            {:reply, :ok, %{state | ledger: ledger, staging: staging}}

          {:char_limit_exceeded, _, _} = soft ->
            # The reservation stands even though the proposal was soft-
            # rejected — over-counting is the safe direction for retry and
            # crash decisions.
            {:reply, soft, %{state | ledger: ledger}}
        end

      {:error, reason} ->
        {:reply, {:error, Atom.to_string(reason)}, state}
    end
  end

  # The commit marker: closes staging to further writes and records which
  # attempt carried it. It NEVER publishes — only the driver does, and only
  # after this attempt's clean exit (the publish gate).
  defp tool_call(:commit_proposals, token, state) do
    case AttemptLedger.record_commit(state.ledger, token) do
      {:ok, ledger} -> {:reply, :ok, %{state | ledger: ledger}}
      {:error, reason} -> {:reply, {:error, Atom.to_string(reason)}, state}
    end
  end

  defp tool_call(:list_clusters, _token, state) do
    {:reply, {:ok, %{clusters: state.clusters || []}}, state}
  end

  defp tool_call({:get_cluster, %{cluster_id: id}}, _token, state) do
    case Enum.find(state.clusters || [], &(&1.id == id)) do
      nil ->
        {:reply, {:error, "no_such_cluster"}, state}

      %{type: :messages} = cluster ->
        {:reply, {:ok, serialize_message_cluster(cluster, state.messages || [])}, state}

      cluster ->
        {:reply, {:ok, serialize_fact_cluster(cluster, state.inputs || [])}, state}
    end
  end

  defp tool_call(:get_active_blocks, _token, state) do
    blocks =
      try do
        JidoClaw.Memory.list_blocks_for_scope_chain(state.scope)
        # MCP tool handler — must never crash the per-run GenServer mid-pass.
      rescue
        # reach:disable-next-line bare_rescue
        _ -> []
      end

    {:reply, {:ok, %{blocks: Enum.map(blocks, &serialize_block/1)}}, state}
  end

  defp tool_call({:find_similar_facts, %{query: q} = args}, _token, state) do
    limit = Map.get(args, :limit, 10)

    facts =
      try do
        JidoClaw.Memory.recall(q, tool_context: tool_context_from(state.scope), limit: limit)
        # MCP tool handler — must never crash the per-run GenServer mid-pass.
      rescue
        # reach:disable-next-line bare_rescue
        _ -> []
      end

    {:reply, {:ok, %{facts: facts}}, state}
  end

  defp tool_call(other, _token, state) do
    {:reply, {:error, "unknown_tool_envelope: #{inspect(other)}"}, state}
  end

  defp stage_mutation(state, token, kind, args) do
    case AttemptLedger.reserve_mutation(state.ledger, token) do
      {:ok, ledger} ->
        {:ok, staging} = Staging.add(state.staging, kind, args)
        {:reply, :ok, %{state | ledger: ledger, staging: staging}}

      {:error, reason} ->
        {:reply, {:error, Atom.to_string(reason)}, state}
    end
  end

  # -- async work ---------------------------------------------------------------

  @impl GenServer
  def handle_info(:gate, state) do
    case PolicyResolver.gate(state.scope) do
      :ok -> {:noreply, state, {:continue, :acquire_lock}}
      {:skip, reason} -> finalise(state, :skipped, reason)
    end
  end

  # The harness driver task's terminal. `:committed` is the ONLY path to a
  # publish, and the publish runs in a monitored task so this server stays
  # responsive and the deadline watchdog can cancel + await + reconcile a
  # blocked publish phase.
  def handle_info({ref, result}, %{harness_task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | harness_task_ref: nil, harness_task_pid: nil}

    case result do
      {:committed, %{turns: turns}} ->
        {:noreply, start_publish_task(%{state | harness_turns: turns})}

      {:iteration_limit, %{turns: turns}} ->
        finalise(%{state | harness_turns: turns}, :failed, "iteration_limit_reached")

      {:deadline_exhausted, %{turns: turns}} ->
        finalise(%{state | harness_turns: turns}, :failed, "run_deadline_exceeded")

      {:failed, reason, %{turns: turns}} ->
        finalise(%{state | harness_turns: turns}, :failed, error_string_for(reason))
    end
  end

  # The publish task's result: the certificate row (`:run_id`-pinned,
  # status :succeeded) was written in the SAME transaction as the mutations.
  def handle_info({ref, result}, %{publish_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | publish_task: nil}

    case result do
      {:ok, run} -> finalise_with_run(state, :succeeded, run)
      {:error, reason} -> finalise(state, :failed, to_string(reason))
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{harness_task_ref: ref} = state) do
    finalise(state, :failed, "harness_error: #{inspect(reason)}")
  end

  # The publish task DIED mid-transaction: whether the commit landed is
  # unknown until the certificate says so — reconcile, never republish.
  def handle_info({:DOWN, ref, :process, _, reason}, %{publish_task: %Task{ref: ref}} = state) do
    Logger.warning("[Consolidator] publish task crashed: #{inspect(reason)}")
    reconcile_publish(%{state | publish_task: nil}, "publish_task_crashed")
  end

  # The whole-run deadline watchdog — the ONLY cancellation authority
  # (a caller's await_ms is a wait timeout, never cancellation). Close the
  # active attempt, stop the harness session, cancel + await any publish
  # task, then reconcile the certificate with three honest outcomes.
  def handle_info(:run_deadline, %{status: :running} = state) do
    if state.forge_session_id, do: maybe_stop_forge_session(state.forge_session_id)

    watchdog_state =
      state
      |> close_open_attempt_for_deadline()
      |> shutdown_publish_task()

    reconcile_publish(watchdog_state, "run_deadline_exceeded")
  end

  def handle_info(:run_deadline, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def handle_continue(:acquire_lock, state) do
    key =
      Scope.lock_key(state.scope.tenant_id, state.scope.scope_kind, Scope.primary_fk(state.scope))

    case LockOwner.acquire(key) do
      {:ok, pid} ->
        {:noreply, %{state | lock_owner_pid: pid}, {:continue, :load_inputs}}

      :busy ->
        finalise(state, :skipped, :scope_busy)

      {:error, reason} ->
        finalise(state, :failed, to_string(reason))
    end
  end

  def handle_continue(:load_inputs, state) do
    case load_inputs(state) do
      {:ok, inputs, messages} ->
        config = consolidator_config()
        min_count = Keyword.get(config, :min_input_count, 10)
        override = Keyword.get(state.opts, :override_min_input_count, false)
        total = length(inputs) + length(messages)

        if not override and total < min_count do
          finalise(state, :skipped, "below_min_input_count")
        else
          {:noreply, %{state | inputs: inputs, messages: messages}, {:continue, :cluster}}
        end

      {:error, reason} ->
        finalise(state, :failed, to_string(reason))
    end
  end

  def handle_continue(:cluster, state) do
    config = consolidator_config()
    max_clusters = Keyword.get(config, :max_clusters_per_run, 20)
    fact_clusters = Clusterer.cluster(state.inputs || [], max_clusters)
    message_clusters = Clusterer.cluster_messages(state.messages || [], max_clusters)

    {:noreply, %{state | clusters: fact_clusters ++ message_clusters},
     {:continue, :invoke_harness}}
  end

  def handle_continue(:invoke_harness, state) do
    # Harness was resolved at `:await_and_start` time and persisted on
    # state, so any caller-side configuration mistake is surfaced before
    # the run holds a lock.
    spawn_harness_task(state, state.effective_harness)
  end

  def handle_continue(:stop, state), do: {:stop, :normal, state}

  @impl GenServer
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  # -- internals ---------------------------------------------------------------

  defp resolve_effective_harness(opts) do
    override = Keyword.get(opts, :harness)
    global = Keyword.get(consolidator_config(), :harness, :claude_code)

    case override || global do
      h when h in [:claude_code, :codex, :fake] -> {:ok, h}
      other -> {:error, "unknown_harness:#{inspect(other)}"}
    end
  end

  defp spawn_harness_task(state, harness) do
    forge_session_id = Ecto.UUID.generate()

    {:ok, endpoint} =
      ScopedEndpoint.start_link(
        plug: JidoClaw.Memory.Consolidator.Plug,
        scope_id: state.run_id,
        path_prefix: "/run"
      )

    config = consolidator_config()
    harness_options = Keyword.get(config, :harness_options, [])
    timeout_ms = Keyword.get(harness_options, :timeout_ms, 600_000)
    sandbox_mode = Keyword.get(harness_options, :sandbox_mode, :local)

    base_forge = Application.get_env(:jido_claw, :forge_home, "/var/local/forge")
    run_forge_home = Path.join(base_forge, forge_session_id)
    codex_home = Path.join(run_forge_home, ".codex")

    # Pre-create the per-run dir for `:local` mode — mode 0700 explicitly:
    # it retains credentials + session data for the run's WHOLE life now
    # (crash-native resume keeps codex session files under CODEX_HOME
    # across a harness recovery; deletion happens only at final teardown).
    # Docker mode handles cleanup via container destruction, so we skip
    # the host mkdir there.
    if sandbox_mode == :local do
      File.mkdir_p!(run_forge_home)
      File.chmod!(run_forge_home, 0o700)
    end

    # The MCP endpoint capability is ATTEMPT-scoped: the tokenized URL and
    # per-attempt 0600 config file are minted by `:open_attempt` per CLI
    # invocation and ride `run_iteration` opts only — never the spec (and
    # therefore never the persisted session row or a checkpoint).
    runner_config =
      base_runner_config(harness, harness_options)
      |> Map.put(:forge_home, run_forge_home)
      |> Map.put(:codex_home, codex_home)
      |> Map.put(:prompt, Prompt.build(state))
      |> maybe_add_fake_proposals(harness, state.opts)

    # Refine effective_harness_model with whatever runner_config landed
    # (e.g., harness defaults via `base_runner_config/2`). `:fake`'s
    # config has no `:model` key, so the fallback to the value already
    # captured at `:await_and_start` time is what pins the cross-harness
    # regression test.
    effective_model =
      Map.get(runner_config, :model) || state.effective_harness_model

    runner_module = Keyword.get(state.opts, :runner_module)
    spec_runner = runner_module || harness

    base_spec = %{
      runner: spec_runner,
      runner_config: runner_config,
      sandbox: sandbox_mode,
      tenant_id: state.scope.tenant_id,
      workspace_id: state.scope.workspace_id
    }

    spec = maybe_run_without_claim(base_spec, state.scope.workspace_id)

    parent = self()

    budget = %{
      deadline_at: state.deadline_at,
      per_turn_ms: timeout_ms,
      floor_ms: @deadline_floor_ms,
      max_iterations: Keyword.get(harness_options, :max_iterations, @default_max_iterations),
      recovery_await_cap_ms: @recovery_await_cap_ms
    }

    task =
      Task.Supervisor.async_nolink(
        JidoClaw.Memory.Consolidator.TaskSupervisor,
        fn ->
          drive_harness(parent, forge_session_id, spec, budget)
        end
      )

    {:noreply,
     %{
       state
       | mcp_endpoint: endpoint,
         forge_session_id: forge_session_id,
         harness_task_ref: task.ref,
         harness_task_pid: task.pid,
         run_forge_home: run_forge_home,
         effective_harness_model: effective_model
     }}
  end

  # The multi-iteration driver: turn 1 sends the full prompt (already in
  # runner_config); continuation turns send GUIDANCE only (SY3-3 — never
  # restate the task; an armed runner continues its anchored conversation,
  # a resume-off runner just runs again). Per attempt: mint the capability
  # (`:open_attempt`), run, close-then-evaluate (`:close_attempt`), act on
  # the directive. Terminal resources (lock, endpoint, run_forge_home) are
  # NOT touched here — they belong to the RunServer's final teardown, so a
  # harness crash + Manager recovery finds them intact.
  defp drive_harness(parent, forge_session_id, spec, budget) do
    # Subscribe before start_session so we can't miss the :ready broadcast
    # if bootstrap completes inside the same scheduler quantum — the same
    # subscription later carries the recovered session's :ready.
    :ok = ForgePubSub.subscribe(forge_session_id)

    case ForgeManager.start_session(forge_session_id, spec) do
      {:ok, %{pid: pid}} ->
        try do
          case await_ready(forge_session_id, pid, bootstrap_timeout(budget.per_turn_ms)) do
            :ok ->
              harness_loop(parent, forge_session_id, budget, 1, 0)

            {:error, reason} ->
              {:failed, reason, %{turns: 0}}
          end

          # Forge harness wrapper — every external runner failure path must
          # normalize to a driver terminal so the per-run server can finalise.
        rescue
          # reach:disable-next-line bare_rescue
          e -> {:failed, Exception.message(e), %{turns: 0}}
        catch
          :exit, reason -> {:failed, inspect(reason), %{turns: 0}}
        after
          # Ready, timed-out, harness died, loop crashed — every exit path
          # stops the Forge session (idempotent; the watchdog also stops it
          # on the deadline path).
          maybe_stop_forge_session(forge_session_id)
        end

      {:error, reason} ->
        {:failed, reason, %{turns: 0}}
    end
  end

  defp harness_loop(parent, forge_session_id, budget, iteration, turns_acc, source \\ :live) do
    remaining = budget.deadline_at - System.monotonic_time(:millisecond)

    if remaining < budget.floor_ms do
      {:deadline_exhausted, %{turns: turns_acc}}
    else
      case GenServer.call(parent, :open_attempt, 30_000) do
        {:ok, %{token: token, config_path: config_path, url: url}} ->
          opts =
            [
              timeout: min(budget.per_turn_ms, remaining),
              mcp_config_path: config_path,
              mcp_server_url: url,
              source: source
            ] ++ turn_prompt_opts(iteration)

          outcome = run_one_attempt(forge_session_id, opts)
          maybe_warn_fresh_start(outcome, iteration)
          turns = turns_acc + turns_of(outcome)
          directive = GenServer.call(parent, {:close_attempt, token, outcome}, 30_000)

          act_on_directive(directive, parent, forge_session_id, budget, iteration, turns)

        {:error, reason} ->
          {:failed, "attempt_open_failed: #{inspect(reason)}", %{turns: turns_acc}}
      end
    end
  end

  defp act_on_directive(directive, parent, forge_session_id, budget, iteration, turns) do
    case directive do
      :publish ->
        {:committed, %{turns: turns}}

      :continue ->
        if iteration >= budget.max_iterations do
          {:iteration_limit, %{turns: turns}}
        else
          harness_loop(parent, forge_session_id, budget, iteration + 1, turns)
        end

      :retry_fresh ->
        # The ONE authorized fresh retry: the anchor was poisoned by the
        # rejected resume, so the runner starts a fresh conversation — the
        # turn must carry the FULL prompt (state.prompt), never continuation
        # guidance, hence iteration resets to 1 for prompt purposes while
        # the turn budget keeps counting via the deadline. The re-send is
        # marked `source: :replay` (EM3-3).
        harness_loop(parent, forge_session_id, budget, 1, turns, :replay)

      :await_recovery ->
        await_recovery_then_replay(parent, forge_session_id, budget, iteration, turns)

      {:halt, reason} ->
        {:failed, reason, %{turns: turns}}
    end
  end

  # Effect-free harness crash: Manager recovery restores process + state
  # (never re-issues work) — the driver awaits the recovered session's
  # :ready on the run-long subscription, then REPLAYS the interrupted
  # logical turn exactly once (the ledger latched it; marked
  # `source: :replay`, EM3-3).
  defp await_recovery_then_replay(parent, forge_session_id, budget, iteration, turns) do
    remaining = budget.deadline_at - System.monotonic_time(:millisecond)
    await = min(max(remaining, 0), budget.recovery_await_cap_ms)

    receive do
      {:ready, ^forge_session_id} ->
        harness_loop(parent, forge_session_id, budget, iteration, turns, :replay)
    after
      await ->
        {:failed, "harness_recovery_timeout", %{turns: turns}}
    end
  end

  # Turn 1 sends no prompt opts — the runner uses its full config prompt.
  # Later turns send `:guidance` — the semantically-tagged opt only armed
  # CONTINUATION turns read: an anchored continuation rides `--resume` with
  # it, and a fresh-armed turn structurally ignores it in favor of
  # `state.prompt` (the persisted full task), so a task-free turn cannot
  # exist (CM2-3/SY3-3). Replay turns need no special-casing — a live-anchor
  # replay continues with meaningful guidance; a dropped-anchor replay
  # resolves fresh and gets the task. `source: :replay` stays for EM3-3
  # event marking only.
  defp turn_prompt_opts(1), do: []
  defp turn_prompt_opts(iteration), do: [guidance: Prompt.continuation(iteration)]

  # Observability only (F2's detection half): a fresh conversation on a
  # turn ≥ 2 means the anchor didn't survive — mid-run context was lost and
  # the turn redid the task from scratch (safely: a fresh-armed turn always
  # carries the full prompt now). No directive change, no extra turn.
  # Silent when the runner attached no armed state (resume :off, fake and
  # scripted runners).
  defp maybe_warn_fresh_start(
         {:result, %{metadata: %{state: %{resume: %ResumeState{} = rs}}}},
         iteration
       )
       when iteration > 1 do
    if ResumeState.fresh_start?(rs) do
      Logger.warning(
        "[Consolidator] turn #{iteration} started a FRESH conversation — mid-run " <>
          "context was lost; the turn redid the task with the full prompt"
      )
    end

    :ok
  end

  defp maybe_warn_fresh_start(_outcome, _iteration), do: :ok

  defp run_one_attempt(forge_session_id, opts) do
    case Harness.run_iteration(forge_session_id, opts) do
      {:ok, result} ->
        {:result, result}

      {:error, :not_found} ->
        # The session process is GONE (crash), not an iteration error —
        # the ledger's crash table decides replay vs terminal.
        {:crashed, :session_not_found}

      {:error, reason} ->
        {:result, %{status: :error, error: reason, metadata: %{}}}
    end
  catch
    :exit, reason -> {:crashed, reason}
  end

  defp turns_of({:result, %{metadata: %{turns: turns}}}) when is_integer(turns), do: turns
  defp turns_of(_outcome), do: 0

  defp await_ready(session_id, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:ready, ^session_id} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, {:runner_init_failed, init_reason}} ->
        {:error, runner_init_error_string(init_reason)}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, "harness_died_during_bootstrap: #{inspect(reason)}"}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "harness_bootstrap_timeout"}
    end
  end

  defp runner_init_error_string(:no_credentials), do: "no_credentials"
  defp runner_init_error_string(:runner_unavailable), do: "runner_unavailable"

  defp runner_init_error_string(other),
    do: "runner_init_failed: #{inspect(other)}"

  defp bootstrap_timeout(run_timeout_ms), do: min(run_timeout_ms, 60_000)

  defp maybe_stop_forge_session(forge_session_id) do
    ForgeManager.stop_session(forge_session_id, :normal)
  catch
    _, _ -> :ok
  end

  defp base_runner_config(:fake, _opts), do: %{fake_proposals: []}

  # Both vendor lanes arm native session resume (F1): without it every turn
  # ≥ 2 is a FRESH conversation whose entire prompt is the task-free
  # continuation nudge. Accepted side effects: armed claude adds one `pwd`
  # exec at init; armed codex drops `--ephemeral`, so session files persist
  # under CODEX_HOME (= run_forge_home, cleaned at final teardown). The
  # :fake lane stays unarmed.
  defp base_runner_config(:claude_code, opts) do
    merged = harness_specific_options(opts, :claude_code)

    %{
      model: Keyword.get(merged, :model, "claude-opus-4-7"),
      max_turns: Keyword.get(merged, :max_turns, 60),
      timeout_ms: Keyword.get(merged, :timeout_ms, 600_000),
      thinking_effort: Keyword.get(merged, :thinking_effort, "xhigh"),
      resume: :armed
    }
  end

  defp base_runner_config(:codex, opts) do
    merged = harness_specific_options(opts, :codex)

    %{
      model: Keyword.get(merged, :model, "gpt-5-codex"),
      max_turns: Keyword.get(merged, :max_turns, 60),
      timeout_ms: Keyword.get(merged, :timeout_ms, 600_000),
      resume: :armed
    }
  end

  defp base_runner_config(_, _), do: %{}

  # Merge shared `harness_options` keys with the per-harness nested
  # keyword block. The shared keys (`:sandbox_mode`, `:timeout_ms`,
  # `:max_turns`) stay at the top level of `:harness_options`;
  # harness-specific keys live under `:claude_code` / `:codex` / `:fake`
  # so a per-call `harness:` override picks the right model instead of
  # leaking the global default's model into the wrong CLI.
  defp harness_specific_options(harness_options, harness) do
    shared = Keyword.drop(harness_options, [:claude_code, :codex, :fake])
    specific = Keyword.get(harness_options, harness, [])
    Keyword.merge(shared, specific)
  end

  defp maybe_add_fake_proposals(config, :fake, opts) do
    Map.put(config, :fake_proposals, Keyword.get(opts, :fake_proposals, []))
  end

  defp maybe_add_fake_proposals(config, _, _), do: config

  # `:user`/`:project` scopes have no workspace_id to satisfy the Forge
  # session scope, so the run goes through the Harness ephemerally: `claim:
  # false` skips the DB claim, history row, recovery, and :pg ownership. The
  # trade-off (no DB-backed recovery/history/ForgeView entry) is acceptable
  # for the random-UUID consolidator session. Keeping the flag explicit means
  # a genuinely-missing scope on a *normal* spec still fails loudly via the
  # Harness `:scope_required` path.
  defp maybe_run_without_claim(spec, nil), do: Map.put(spec, :claim, false)
  defp maybe_run_without_claim(spec, _workspace_id), do: spec

  # Crash-native resume is only reachable for CLAIMED, persisted sessions —
  # a `claim: false` run (user/project scope) or disabled persistence has no
  # Manager recovery, so an effect-free crash is terminal, never awaited.
  defp recovery_possible?(state) do
    state.scope[:workspace_id] != nil and ForgePersistence.enabled?()
  end

  defp close_open_attempt_for_deadline(%{ledger: %AttemptLedger{open_token: token}} = state)
       when is_binary(token) do
    {_directive, ledger} =
      AttemptLedger.close_and_evaluate(
        state.ledger,
        token,
        {:crashed, :run_deadline},
        %{remaining_ms: 0, floor_ms: @deadline_floor_ms, recoverable?: false}
      )

    %{state | ledger: ledger}
  end

  defp close_open_attempt_for_deadline(state), do: state

  defp shutdown_publish_task(%{publish_task: %Task{} = task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | publish_task: nil}
  end

  defp shutdown_publish_task(state), do: state

  defp remaining_ms(%{deadline_at: nil}), do: 0
  defp remaining_ms(state), do: state.deadline_at - System.monotonic_time(:millisecond)

  # Per-attempt endpoint capability: a UNIQUE immutable 0600 config file per
  # CLI invocation (never rewriting a shared file — an old process must not
  # be able to reload a new attempt's capability) naming the tokenized URL.
  defp write_attempt_config(state, token) do
    url = "#{state.mcp_endpoint.url}/a/#{token}"
    path = Path.join(System.tmp_dir!(), "consolidator-#{state.run_id}-#{token}.json")

    with :ok <- File.write(path, ScopedEndpoint.client_config_json("consolidator", url)),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path, url}
    end
  end

  defp delete_attempt_config(state, token) do
    case Map.pop(state.attempt_config_paths, token) do
      {nil, _paths} ->
        state

      {path, paths} ->
        _ = File.rm(path)
        %{state | attempt_config_paths: paths}
    end
  end

  defp start_publish_task(state) do
    task =
      Task.Supervisor.async_nolink(
        JidoClaw.Memory.Consolidator.TaskSupervisor,
        fn -> do_publish(state) end
      )

    %{state | publish_task: task}
  end

  # Three-outcome publish reconciliation against the durable certificate
  # (the `:run_id`-pinned ConsolidationRun row): (a) row + :succeeded ⇒ the
  # commit won; (b) genuine not-found, or a present row with a non-success
  # status (terminal audit rows share the deterministic id) ⇒ nothing
  # published; (c) a DB/framework error reading the certificate — after
  # bounded retries — ⇒ publish_outcome_unknown: never republish, never
  # claim nothing-published.
  defp reconcile_publish(state, base_reason) do
    deadline = System.monotonic_time(:millisecond) + reconciliation_allowance_ms()

    case read_certificate(state, deadline) do
      {:ok, %{status: :succeeded} = run} ->
        finalise_with_run(state, :succeeded, run)

      {:ok, _non_success_row} ->
        finalise(state, :failed, base_reason)

      :not_found ->
        finalise(state, :failed, base_reason)

      :unknown ->
        finalise(state, :failed, "publish_outcome_unknown")
    end
  end

  defp read_certificate(state, retry_deadline) do
    case ConsolidationRun.by_id(state.run_id,
           tenant: state.scope.tenant_id,
           actor: Actor.system(state.scope.tenant_id)
         ) do
      {:ok, run} ->
        {:ok, run}

      {:error, err} ->
        if AshErrors.not_found?(err) do
          :not_found
        else
          retry_certificate_read(state, retry_deadline)
        end
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      retry_certificate_read(state, retry_deadline)
  end

  defp retry_certificate_read(state, retry_deadline) do
    if System.monotonic_time(:millisecond) < retry_deadline do
      Process.sleep(@certificate_read_retry_ms)
      read_certificate(state, retry_deadline)
    else
      :unknown
    end
  end

  defp reconciliation_allowance_ms do
    Application.get_env(:jido_claw, :consolidator_reconciliation_allowance_ms, 10_000)
  end

  defp load_inputs(state) do
    config = consolidator_config()
    max_facts = Keyword.get(config, :max_facts_per_run, 500)
    max_messages = Keyword.get(config, :max_messages_per_run, 500)
    fk = Scope.primary_fk(state.scope)
    scope_kind = state.scope.scope_kind
    tenant_id = state.scope.tenant_id

    %{
      facts_at: facts_at,
      facts_id: facts_id,
      messages_at: messages_at,
      messages_id: messages_id
    } = load_prior_watermarks(tenant_id, scope_kind, fk)

    with {:ok, facts} <- load_facts(tenant_id, scope_kind, fk, facts_at, facts_id, max_facts),
         {:ok, messages} <-
           load_messages(tenant_id, scope_kind, fk, messages_at, messages_id, max_messages) do
      {:ok, facts, messages}
    end
  end

  defp load_facts(tenant_id, scope_kind, fk, since_at, since_id, limit) do
    Fact.for_consolidator(
      %{
        scope_kind: scope_kind,
        scope_fk_id: fk,
        since_inserted_at: since_at,
        since_id: since_id,
        limit: limit
      },
      tenant: tenant_id,
      actor: Actor.system(tenant_id)
    )
  end

  defp load_messages(tenant_id, :session, fk, since_at, since_id, limit) do
    Message.for_consolidator(
      %{
        scope_kind: :session,
        scope_fk_id: fk,
        since_inserted_at: since_at,
        since_id: since_id,
        limit: limit
      },
      tenant: tenant_id,
      actor: Actor.system(tenant_id)
    )
  end

  defp load_messages(_tenant_id, _scope_kind, _fk, _since_at, _since_id, _limit), do: {:ok, []}

  defp load_prior_watermarks(tenant_id, scope_kind, fk) do
    runs = read_latest_succeeded_runs(tenant_id, scope_kind, fk)

    {facts_at, facts_id} = pick_or_walk_history(runs, :facts, tenant_id, scope_kind, fk)
    {messages_at, messages_id} = pick_or_walk_history(runs, :messages, tenant_id, scope_kind, fk)

    %{
      facts_at: facts_at,
      facts_id: facts_id,
      messages_at: messages_at,
      messages_id: messages_id
    }
  end

  defp read_latest_succeeded_runs(tenant_id, scope_kind, fk) do
    case ConsolidationRun.latest_for_scope(
           %{
             scope_kind: scope_kind,
             scope_fk_id: fk,
             status: :succeeded
           },
           tenant: tenant_id,
           actor: Actor.system(tenant_id)
         ) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      []
  end

  defp pick_or_walk_history([latest | _] = _runs, stream, tenant_id, scope_kind, fk) do
    case watermark_pair(latest, stream) do
      {nil, nil} -> walk_history_for_watermark(stream, tenant_id, scope_kind, fk)
      pair -> pair
    end
  end

  defp pick_or_walk_history([], _stream, _tenant_id, _scope_kind, _fk), do: {nil, nil}

  defp watermark_pair(run, :facts),
    do: {run.facts_processed_until_at, run.facts_processed_until_id}

  defp watermark_pair(run, :messages),
    do: {run.messages_processed_until_at, run.messages_processed_until_id}

  defp walk_history_for_watermark(stream, tenant_id, scope_kind, fk) do
    case ConsolidationRun.history_for_scope(
           %{
             scope_kind: scope_kind,
             scope_fk_id: fk,
             limit: 20
           },
           tenant: tenant_id,
           actor: Actor.system(tenant_id)
         ) do
      {:ok, runs} -> first_non_null_watermark(runs, stream)
      _ -> {nil, nil}
    end
  rescue
    _ in @db_errors ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      {nil, nil}
  end

  defp first_non_null_watermark(runs, stream) do
    Enum.find_value(runs, {nil, nil}, fn run ->
      case watermark_pair(run, stream) do
        {nil, nil} -> nil
        pair -> pair
      end
    end)
  end

  defp do_publish(state) do
    started_at = state.started_at || DateTime.utc_now()
    finished_at = DateTime.utc_now()

    result =
      Ash.transact(ConsolidationRun, fn ->
        {counts, hint_ids} = apply_proposals(state)
        watermarks = compute_watermarks(state)

        run_attrs =
          %{
            # The commit certificate: the row id IS the run id, written in
            # the same transaction as the mutations, so reconciliation can
            # decide "did the publish commit?" by one keyed read.
            run_id: state.run_id,
            scope_kind: state.scope.scope_kind,
            user_id: state.scope[:user_id],
            workspace_id: state.scope[:workspace_id],
            project_id: state.scope[:project_id],
            session_id: state.scope[:session_id],
            started_at: started_at,
            finished_at: finished_at,
            status: :succeeded,
            forge_session_id: state.forge_session_id,
            harness: state.effective_harness,
            harness_model: state.effective_harness_model
          }
          |> Map.merge(counts)
          |> Map.merge(watermarks)

        case ConsolidationRun.record_run(run_attrs,
               tenant: state.scope.tenant_id,
               actor: Actor.system(state.scope.tenant_id)
             ) do
          {:ok, run} -> {run, hint_ids}
          {:error, err} -> Ash.DataLayer.rollback(ConsolidationRun, err)
        end
      end)

    case result do
      # Hints are dispatched only after the outer transaction commits so
      # `BackfillWorker.claim_by_id/3` finds visible rows. Inside the
      # transaction, `Fact.record` is called with `skip_backfill_hint?:
      # true` to suppress the per-row `after_transaction` hook (whose
      # nesting under `Ash.transact(ConsolidationRun, ...)` would both
      # log a warning and fire the hint pre-commit).
      {:ok, {run, hint_ids}} ->
        Enum.each(hint_ids, &Fact.hint_backfill/1)
        {:ok, run}

      other ->
        other
    end
  end

  defp apply_proposals(state) do
    %{written: blocks_written, revised: blocks_revised} = apply_block_updates(state)
    {facts_added_from_adds, ids_from_adds} = apply_fact_adds(state)

    {added_from_updates, invalidated_from_updates, supersede_links, ids_from_updates} =
      apply_fact_updates(state)

    invalidated_from_deletes = apply_fact_deletes(state)
    links_added = apply_link_creates(state) + supersede_links

    counts = %{
      messages_processed: length(state.messages || []),
      facts_processed: length(state.inputs || []),
      # `blocks_written` is writes-only; a revise of an existing active block
      # increments `blocks_revised` instead (both were previously conflated
      # into `blocks_written`, and `blocks_revised` was hardcoded 0).
      blocks_written: blocks_written,
      blocks_revised: blocks_revised,
      facts_added: facts_added_from_adds + added_from_updates,
      facts_invalidated: invalidated_from_deletes + invalidated_from_updates,
      links_added: links_added
    }

    {counts, ids_from_adds ++ ids_from_updates}
  end

  defp compute_watermarks(state) do
    deferred_cluster_ids =
      state.staging
      |> Staging.entries(:cluster_defers)
      |> Enum.map(&Map.get(&1, :cluster_id))
      |> MapSet.new()

    deferred_clusters =
      Enum.filter(state.clusters || [], fn c ->
        MapSet.member?(deferred_cluster_ids, c.id)
      end)

    deferred_fact_ids =
      deferred_clusters
      |> Enum.flat_map(fn c -> Map.get(c, :fact_ids, []) end)
      |> MapSet.new()

    deferred_message_ids =
      deferred_clusters
      |> Enum.flat_map(fn c -> Map.get(c, :message_ids, []) end)
      |> MapSet.new()

    {facts_at, facts_id} = contiguous_prefix(state.inputs || [], deferred_fact_ids)
    {messages_at, messages_id} = contiguous_prefix(state.messages || [], deferred_message_ids)

    %{
      facts_processed_until_at: facts_at,
      facts_processed_until_id: facts_id,
      messages_processed_until_at: messages_at,
      messages_processed_until_id: messages_id
    }
  end

  defp contiguous_prefix([], _), do: {nil, nil}

  defp contiguous_prefix(rows, deferred_ids) do
    rows
    |> Enum.sort_by(fn r -> {r.inserted_at, r.id} end)
    |> Enum.take_while(fn r -> not MapSet.member?(deferred_ids, r.id) end)
    |> List.last()
    |> case do
      nil -> {nil, nil}
      last -> {last.inserted_at, last.id}
    end
  end

  defp apply_block_updates(state) do
    Enum.reduce(
      Staging.entries(state.staging, :block_updates),
      %{written: 0, revised: 0},
      fn args, acc ->
        attrs = build_block_attrs(state, args)

        case maybe_revise_or_write_block(state, attrs) do
          {:ok, :written, _block} ->
            %{acc | written: acc.written + 1}

          {:ok, :revised, _block} ->
            %{acc | revised: acc.revised + 1}

          err ->
            Logger.warning([
              "[Consolidator] block update skipped: ",
              "label=#{inspect(Map.get(args, :label))} ",
              "error=#{inspect(err)}"
            ])

            acc
        end
      end
    )
  end

  defp build_block_attrs(state, args) do
    %{
      scope_kind: state.scope.scope_kind,
      user_id: state.scope[:user_id],
      workspace_id: state.scope[:workspace_id],
      project_id: state.scope[:project_id],
      session_id: state.scope[:session_id],
      label: Map.get(args, :label),
      description: Map.get(args, :description),
      value: Map.get(args, :new_content),
      char_limit: Map.get(args, :char_limit, 2000),
      pinned: Map.get(args, :pinned, true),
      position: Map.get(args, :position, 0),
      source: :consolidator,
      written_by: "consolidator"
    }
  end

  defp maybe_revise_or_write_block(state, attrs) do
    tenant_id = state.scope.tenant_id

    actor = Actor.system(tenant_id)

    case Block.history_for_label(
           state.scope.scope_kind,
           Scope.primary_fk(state.scope),
           attrs.label,
           tenant: tenant_id,
           actor: actor
         ) do
      {:ok, [_ | _] = history} ->
        active = Enum.find(history, fn b -> is_nil(b.invalid_at) end)

        case active do
          nil -> tag_write(Block.write(attrs, tenant: tenant_id, actor: actor))
          prior -> tag_revise(Block.revise(prior, attrs, actor: actor))
        end

      _ ->
        tag_write(Block.write(attrs, tenant: tenant_id, actor: actor))
    end
  end

  # Tag a block persistence result with which kind of write it was, so the
  # caller can split the writes-vs-revises counts. Errors pass through
  # untagged for the caller's `err ->` branch.
  defp tag_write({:ok, block}), do: {:ok, :written, block}
  defp tag_write(other), do: other

  defp tag_revise({:ok, block}), do: {:ok, :revised, block}
  defp tag_revise(other), do: other

  defp apply_fact_adds(state) do
    tenant_id = state.scope.tenant_id

    Enum.reduce(Staging.entries(state.staging, :fact_adds), {0, []}, fn args, {count, ids} ->
      attrs = %{
        scope_kind: state.scope.scope_kind,
        user_id: state.scope[:user_id],
        workspace_id: state.scope[:workspace_id],
        project_id: state.scope[:project_id],
        session_id: state.scope[:session_id],
        label: Map.get(args, :label),
        content: Map.get(args, :content),
        tags: Map.get(args, :tags, []),
        source: :consolidator_promoted,
        trust_score: 0.85,
        written_by: "consolidator",
        skip_backfill_hint?: true
      }

      case Fact.record(attrs, tenant: tenant_id, actor: Actor.system(tenant_id)) do
        {:ok, fact} ->
          {count + 1, [fact.id | ids]}

        err ->
          Logger.warning([
            "[Consolidator] fact add skipped: ",
            "label=#{inspect(Map.get(args, :label))} ",
            "error=#{inspect(err)}"
          ])

          {count, ids}
      end
    end)
  end

  defp apply_fact_updates(state) do
    Enum.reduce(Staging.entries(state.staging, :fact_updates), {0, 0, 0, []}, fn args,
                                                                                 {added,
                                                                                  invalidated,
                                                                                  links, ids} ->
      case do_apply_fact_update(state.scope.tenant_id, args) do
        {:ok, replacement, link_added?} ->
          link_inc = if link_added?, do: 1, else: 0
          {added + 1, invalidated + 1, links + link_inc, [replacement.id | ids]}

        err ->
          Logger.warning([
            "[Consolidator] fact update skipped: ",
            "fact_id=#{inspect(Map.get(args, :fact_id))} ",
            "error=#{inspect(err)}"
          ])

          {added, invalidated, links, ids}
      end
    end)
  end

  defp do_apply_fact_update(tenant_id, args) do
    actor = Actor.system(tenant_id)

    with {:ok, original} <-
           Fact.by_id(Map.get(args, :fact_id), tenant: tenant_id, actor: actor),
         :ok <- maybe_invalidate_unlabeled(original),
         {:ok, replacement} <- write_replacement(original, args) do
      {:ok, replacement, supersedes_link(replacement.id, original.id, tenant_id)}
    end
  end

  defp maybe_invalidate_unlabeled(%{label: nil, tenant_id: tenant_id} = fact) do
    case Fact.invalidate_by_id(fact, %{reason: "consolidator_update"},
           tenant: tenant_id,
           actor: Actor.system(tenant_id)
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp maybe_invalidate_unlabeled(_), do: :ok

  defp write_replacement(original, args) do
    Fact.record(
      %{
        scope_kind: original.scope_kind,
        user_id: original.user_id,
        workspace_id: original.workspace_id,
        project_id: original.project_id,
        session_id: original.session_id,
        label: original.label,
        content: Map.get(args, :new_content),
        tags: Map.get(args, :tags, original.tags),
        source: :consolidator_promoted,
        trust_score: 0.85,
        written_by: "consolidator",
        skip_backfill_hint?: true
      },
      tenant: original.tenant_id,
      actor: Actor.system(original.tenant_id)
    )
  end

  defp supersedes_link(new_id, old_id, tenant_id) do
    match?(
      {:ok, _},
      Link.create_link(
        %{
          from_fact_id: new_id,
          to_fact_id: old_id,
          relation: :supersedes,
          reason: "consolidator_update",
          written_by: "consolidator"
        },
        tenant: tenant_id,
        actor: Actor.system(tenant_id)
      )
    )
  end

  defp apply_fact_deletes(state) do
    tenant_id = state.scope.tenant_id
    actor = Actor.system(tenant_id)

    Enum.reduce(Staging.entries(state.staging, :fact_deletes), 0, fn args, acc ->
      with {:ok, fact} <- Fact.by_id(Map.get(args, :fact_id), tenant: tenant_id, actor: actor),
           {:ok, _} <-
             Fact.invalidate_by_id(fact, %{reason: Map.get(args, :reason, "consolidator_delete")},
               tenant: tenant_id,
               actor: actor
             ) do
        acc + 1
      else
        err ->
          Logger.warning([
            "[Consolidator] fact delete skipped: ",
            "fact_id=#{inspect(Map.get(args, :fact_id))} ",
            "error=#{inspect(err)}"
          ])

          acc
      end
    end)
  end

  defp apply_link_creates(state) do
    tenant_id = state.scope.tenant_id
    actor = Actor.system(tenant_id)

    Enum.reduce(Staging.entries(state.staging, :link_creates), 0, fn args, acc ->
      with {:ok, relation} <- map_relation(Map.get(args, :relation)),
           attrs = link_attrs(args, relation),
           {:ok, _} <- Link.create_link(attrs, tenant: tenant_id, actor: actor) do
        acc + 1
      else
        err ->
          Logger.warning([
            "[Consolidator] link create skipped: ",
            "from=#{inspect(Map.get(args, :from_fact_id))} ",
            "to=#{inspect(Map.get(args, :to_fact_id))} ",
            "relation=#{inspect(Map.get(args, :relation))} ",
            "error=#{inspect(err)}"
          ])

          acc
      end
    end)
  end

  defp link_attrs(args, relation) do
    %{
      from_fact_id: Map.get(args, :from_fact_id),
      to_fact_id: Map.get(args, :to_fact_id),
      relation: relation,
      reason: Map.get(args, :reason),
      confidence: Map.get(args, :confidence),
      written_by: "consolidator"
    }
  end

  defp map_relation(rel) when is_binary(rel) and rel in @link_relations,
    do: {:ok, String.to_existing_atom(rel)}

  defp map_relation(rel) when is_atom(rel) and rel in @link_relations_atoms,
    do: {:ok, rel}

  defp map_relation(_), do: {:error, :unknown_relation}

  # -- finalisation -----------------------------------------------------------

  defp finalise(state, status, reason) do
    persisted_reason =
      cond do
        is_atom(reason) -> Atom.to_string(reason)
        is_binary(reason) -> reason
        true -> inspect(reason)
      end

    _ = maybe_write_run_row(state, status, persisted_reason)

    do_finalise(state, {:error, reason})
  end

  defp finalise_with_run(state, :succeeded, run) do
    reply = {:ok, run}
    emit_run_telemetry(state, run, :succeeded, nil)
    do_finalise(state, reply)
  end

  defp do_finalise(state, reply) do
    cleanup(state)
    Enum.each(state.awaiters, &GenServer.reply(&1, reply))

    {:stop, :normal, %{state | status: :terminal, result: reply, awaiters: []}}
  end

  defp maybe_write_run_row(state, :skipped, reason) do
    if write_skip_rows?() do
      result = write_run_row(state, :skipped, reason)
      emit_skipped_telemetry(state, reason)
      result
    else
      emit_skipped_telemetry(state, reason)
      nil
    end
  end

  defp maybe_write_run_row(state, status, error_or_nil) do
    write_run_row(state, status, error_or_nil)
  end

  defp write_run_row(state, status, error_string) do
    started_at = state.started_at || DateTime.utc_now()
    finished_at = DateTime.utc_now()

    attrs = %{
      # Terminal audit rows share the run's deterministic id, so publish
      # reconciliation requires `status == :succeeded`, never row presence.
      run_id: state.run_id,
      scope_kind: state.scope.scope_kind,
      user_id: state.scope[:user_id],
      workspace_id: state.scope[:workspace_id],
      project_id: state.scope[:project_id],
      session_id: state.scope[:session_id],
      started_at: started_at,
      finished_at: finished_at,
      status: status,
      error: error_string,
      forge_session_id: state.forge_session_id,
      harness: state.effective_harness,
      harness_model: state.effective_harness_model
    }

    case ConsolidationRun.record_run(attrs,
           tenant: state.scope.tenant_id,
           actor: Actor.system(state.scope.tenant_id)
         ) do
      {:ok, run} ->
        if status == :failed, do: emit_run_telemetry(state, run, :failed, error_string)
        {:ok, run}

      {:error, err} ->
        Logger.warning("[Consolidator] failed to record run row: #{inspect(err)}")
        nil
    end
  end

  # FINAL teardown only (clean terminal, watchdog, or recovery-wait
  # exhaustion): the lock, endpoint, per-attempt config files, and the
  # per-run forge home are retained across a harness crash so Manager
  # recovery finds them intact — codex session files under
  # CODEX_HOME=run_forge_home survive recovery. The cross-owner handshake:
  # the Harness's own teardown runs DETACHED from its terminate/2, and a
  # recovered run can have an OLD epoch's detached teardown still running
  # while a newer epoch finishes — so the session-wide ChildTracker
  # barrier (marks the session closing, sweeps every live epoch, joins
  # in-flight epoch teardowns) runs synchronously BEFORE the home
  # directory — the LAST filesystem resource — is removed. No CLI from
  # any epoch can still be inside its graceful window when the rm runs.
  defp cleanup(state) do
    if state.forge_session_id do
      maybe_stop_forge_session(state.forge_session_id)
      ChildTracker.graceful_teardown_session(state.forge_session_id)
    end

    if state.lock_owner_pid, do: LockOwner.release(state.lock_owner_pid)
    if state.mcp_endpoint, do: ScopedEndpoint.stop(state.mcp_endpoint)
    Enum.each(state.attempt_config_paths, fn {_token, path} -> File.rm(path) end)
    if state.run_forge_home, do: File.rm_rf(state.run_forge_home)
    :ok
  end

  defp emit_run_telemetry(state, run, status, error) do
    duration_ms =
      DateTime.diff(run.finished_at || DateTime.utc_now(), run.started_at, :millisecond)

    measurements =
      %{
        duration_ms: duration_ms,
        harness_turns: state.harness_turns,
        messages_loaded: run.messages_processed || 0,
        messages_published: run.messages_processed || 0,
        facts_loaded: run.facts_processed || 0,
        facts_published: (run.facts_added || 0) + (run.facts_invalidated || 0),
        blocks_written: run.blocks_written || 0,
        blocks_revised: run.blocks_revised || 0,
        links_added: run.links_added || 0
      }

    metadata = %{
      tenant_id: state.scope.tenant_id,
      scope_kind: state.scope.scope_kind,
      scope_fk_id: Scope.primary_fk(state.scope),
      status: status,
      harness: run.harness,
      model: run.harness_model,
      run_id: state.run_id,
      forge_session_id: state.forge_session_id,
      error: error
    }

    :telemetry.execute(
      [:jido_claw, :memory, :consolidator, :run],
      measurements,
      metadata
    )
  end

  defp emit_skipped_telemetry(state, reason) do
    :telemetry.execute(
      [:jido_claw, :memory, :consolidator, :skipped],
      %{count: 1},
      %{
        tenant_id: state.scope.tenant_id,
        scope_kind: state.scope.scope_kind,
        scope_fk_id: Scope.primary_fk(state.scope),
        reason: reason
      }
    )
  end

  # -- helpers -----------------------------------------------------------------

  defp consolidator_config,
    do: Application.get_env(:jido_claw, JidoClaw.Memory.Consolidator, [])

  defp write_skip_rows?, do: Keyword.get(consolidator_config(), :write_skip_rows, true)

  defp tool_context_from(scope) do
    %{
      tenant_id: scope.tenant_id,
      user_id: scope[:user_id],
      workspace_uuid: scope[:workspace_id],
      session_uuid: scope[:session_id],
      project_id: scope[:project_id]
    }
  end

  defp serialize_block(b) do
    %{
      id: b.id,
      label: b.label,
      description: b.description,
      value: b.value,
      char_limit: b.char_limit,
      scope_kind: b.scope_kind
    }
  end

  defp serialize_fact_cluster(cluster, inputs) do
    facts =
      inputs
      |> Enum.filter(fn f -> f.id in cluster.fact_ids end)
      |> Enum.map(&serialize_fact/1)

    Map.put(cluster, :facts, facts)
  end

  defp serialize_message_cluster(cluster, messages) do
    msgs =
      messages
      |> Enum.filter(fn m -> m.id in cluster.message_ids end)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(&serialize_message/1)

    Map.put(cluster, :messages, msgs)
  end

  defp serialize_fact(f) do
    %{
      id: f.id,
      label: f.label,
      content: f.content,
      tags: f.tags,
      source: f.source,
      trust_score: f.trust_score,
      inserted_at: f.inserted_at
    }
  end

  defp serialize_message(m) do
    %{
      id: m.id,
      role: m.role,
      sequence: m.sequence,
      content: m.content,
      inserted_at: m.inserted_at
    }
  end

  defp error_string_for(reason) when is_binary(reason), do: reason
  defp error_string_for(reason), do: inspect(reason)
end
