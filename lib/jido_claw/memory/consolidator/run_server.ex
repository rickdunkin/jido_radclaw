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

  alias JidoClaw.Conversations.Message
  alias JidoClaw.Memory.{Block, ConsolidationRun, Fact, Link, Scope}

  alias JidoClaw.Memory.Consolidator.{
    Clusterer,
    LockOwner,
    MCPEndpoint,
    PolicyResolver,
    Staging
  }

  @registry JidoClaw.Memory.Consolidator.RunRegistry

  @link_relations ~w(supports contradicts supersedes duplicates depends_on related)
  @link_relations_atoms Enum.map(@link_relations, &String.to_atom/1)

  defstruct [
    :run_id,
    :scope,
    :opts,
    :lock_owner_pid,
    :mcp_endpoint,
    :temp_file_path,
    :forge_session_id,
    :harness_task_ref,
    :harness_task_pid,
    :inputs,
    :messages,
    :clusters,
    :result,
    awaiters: [],
    staging: nil,
    status: :idle,
    started_at: nil
  ]

  @doc "Start a per-run server idle. Pid is registered under the run_id."
  @spec start_link(Scope.scope_record()) :: GenServer.on_start()
  def start_link(scope) do
    run_id = Ecto.UUID.generate()
    name = {:via, Registry, {@registry, run_id}}
    GenServer.start_link(__MODULE__, {run_id, scope}, name: name)
  end

  @impl true
  def init({run_id, scope}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       run_id: run_id,
       scope: scope,
       opts: [],
       staging: Staging.new(),
       status: :idle,
       started_at: DateTime.utc_now()
     }}
  end

  # -- Public message handlers --------------------------------------------------

  @impl true
  def handle_call({:await_and_start, opts}, from, %{status: :idle} = state) do
    send(self(), :gate)
    {:noreply, %{state | status: :running, opts: opts, awaiters: [from]}}
  end

  def handle_call({:await_and_start, _opts}, _from, %{status: :terminal, result: result} = state) do
    {:reply, result, state, {:continue, :stop}}
  end

  def handle_call({:await_and_start, _opts}, from, state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  # MCP-tool envelopes — best-effort staging buffer mutations. All
  # `propose_*` tools land here; `commit_proposals` triggers publish.

  def handle_call({:propose_add, args}, _from, state) do
    {:ok, staging} = Staging.add(state.staging, :fact_add, args)
    {:reply, :ok, %{state | staging: staging}}
  end

  def handle_call({:propose_update, args}, _from, state) do
    {:ok, staging} = Staging.add(state.staging, :fact_update, args)
    {:reply, :ok, %{state | staging: staging}}
  end

  def handle_call({:propose_delete, args}, _from, state) do
    {:ok, staging} = Staging.add(state.staging, :fact_delete, args)
    {:reply, :ok, %{state | staging: staging}}
  end

  def handle_call({:propose_block_update, args}, _from, state) do
    case Staging.add_block_update(state.staging, args) do
      {:ok, staging} ->
        {:reply, :ok, %{state | staging: staging}}

      {:char_limit_exceeded, _, _} = soft ->
        {:reply, soft, state}
    end
  end

  def handle_call({:propose_link, args}, _from, state) do
    {:ok, staging} = Staging.add(state.staging, :link_create, args)
    {:reply, :ok, %{state | staging: staging}}
  end

  def handle_call({:defer_cluster, args}, _from, state) do
    {:ok, staging} = Staging.add(state.staging, :cluster_defer, args)
    {:reply, :ok, %{state | staging: staging}}
  end

  def handle_call(:commit_proposals, _from, state) do
    send(self(), :publish)
    {:reply, :ok, state}
  end

  def handle_call(:list_clusters, _from, state) do
    {:reply, {:ok, %{clusters: state.clusters || []}}, state}
  end

  def handle_call({:get_cluster, %{cluster_id: id}}, _from, state) do
    case Enum.find(state.clusters || [], &(&1.id == id)) do
      nil ->
        {:reply, {:error, "no_such_cluster"}, state}

      %{type: :messages} = cluster ->
        {:reply, {:ok, serialize_message_cluster(cluster, state.messages || [])}, state}

      cluster ->
        {:reply, {:ok, serialize_fact_cluster(cluster, state.inputs || [])}, state}
    end
  end

  def handle_call(:get_active_blocks, _from, state) do
    blocks =
      try do
        JidoClaw.Memory.list_blocks_for_scope_chain(state.scope)
      rescue
        _ -> []
      end

    {:reply, {:ok, %{blocks: Enum.map(blocks, &serialize_block/1)}}, state}
  end

  def handle_call({:find_similar_facts, %{query: q} = args}, _from, state) do
    limit = Map.get(args, :limit, 10)

    facts =
      try do
        JidoClaw.Memory.recall(q, tool_context: tool_context_from(state.scope), limit: limit)
      rescue
        _ -> []
      end

    {:reply, {:ok, %{facts: facts}}, state}
  end

  # -- async work ---------------------------------------------------------------

  @impl true
  def handle_info(:gate, state) do
    case PolicyResolver.gate(state.scope) do
      :ok -> {:noreply, state, {:continue, :acquire_lock}}
      {:skip, reason} -> finalise(state, :skipped, reason)
    end
  end

  def handle_info(:publish, state) do
    case do_publish(state) do
      {:ok, run} ->
        finalise_with_run(state, :succeeded, run)

      {:error, reason} ->
        finalise(state, :failed, to_string(reason))
    end
  end

  def handle_info({ref, result}, %{harness_task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | harness_task_ref: nil, harness_task_pid: nil}

    case result do
      {:ok, %{status: :error, error: err}} ->
        finalise(state, :failed, error_string_for(err))

      {:ok, _result_map} ->
        # The harness ran. The model is expected to have called
        # `commit_proposals` (which already triggered `:publish`).
        # If it didn't, treat the run as failed with the canonical
        # max-turns error.
        if Staging.total(state.staging) == 0 do
          finalise(state, :failed, "max_turns_reached")
        else
          send(self(), :publish)
          {:noreply, state}
        end

      {:error, reason} ->
        finalise(state, :failed, error_string_for(reason))
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{harness_task_ref: ref} = state) do
    finalise(state, :failed, "harness_error: #{inspect(reason)}")
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_continue(:acquire_lock, state) do
    key =
      Scope.lock_key(state.scope.tenant_id, state.scope.scope_kind, Scope.primary_fk(state.scope))

    case LockOwner.acquire(key) do
      {:ok, pid} ->
        {:noreply, %{state | lock_owner_pid: pid}, {:continue, :load_inputs}}

      :busy ->
        finalise(state, :skipped, "scope_busy")

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
    case resolved_harness() do
      {:ok, harness} ->
        spawn_harness_task(state, harness)

      {:error, reason} ->
        finalise(state, :failed, reason)
    end
  end

  def handle_continue(:stop, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  # -- internals ---------------------------------------------------------------

  defp resolved_harness do
    case Keyword.get(consolidator_config(), :harness, :claude_code) do
      :claude_code -> {:ok, :claude_code}
      :fake -> {:ok, :fake}
      :codex -> {:error, "no_runner_configured"}
      other -> {:error, "unknown_harness:#{inspect(other)}"}
    end
  end

  defp spawn_harness_task(state, harness) do
    forge_session_id = Ecto.UUID.generate()

    {:ok, endpoint} = MCPEndpoint.start_link(state.run_id)
    temp_path = write_mcp_config(state.run_id, endpoint.url)

    config = consolidator_config()
    harness_options = Keyword.get(config, :harness_options, [])
    timeout_ms = Keyword.get(harness_options, :timeout_ms, 600_000)
    sandbox_mode = Keyword.get(harness_options, :sandbox_mode, :local)

    runner_config =
      base_runner_config(harness, harness_options)
      |> Map.put(:mcp_config_path, temp_path)
      |> maybe_add_fake_proposals(harness, state.opts)

    spec = %{
      runner: harness,
      runner_config: runner_config,
      sandbox: sandbox_mode
    }

    parent = self()

    task =
      Task.Supervisor.async_nolink(
        JidoClaw.Memory.Consolidator.TaskSupervisor,
        fn ->
          drive_harness(parent, forge_session_id, spec, timeout_ms)
        end
      )

    {:noreply,
     %{
       state
       | mcp_endpoint: endpoint,
         temp_file_path: temp_path,
         forge_session_id: forge_session_id,
         harness_task_ref: task.ref,
         harness_task_pid: task.pid
     }}
  end

  defp drive_harness(_parent, forge_session_id, spec, timeout_ms) do
    # Subscribe before start_session so we can't miss the :ready broadcast
    # if bootstrap completes inside the same scheduler quantum.
    :ok = JidoClaw.Forge.PubSub.subscribe(forge_session_id)

    case JidoClaw.Forge.Manager.start_session(forge_session_id, spec) do
      {:ok, %{pid: pid}} ->
        try do
          with :ok <- await_ready(forge_session_id, pid, bootstrap_timeout(timeout_ms)),
               result <-
                 JidoClaw.Forge.Harness.run_iteration(forge_session_id, timeout: timeout_ms) do
            result
          else
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, inspect(reason)}
        after
          # Ready, timed-out, harness died, run_iteration crashed — every
          # exit path stops the Forge session. start_session succeeded so
          # the corresponding stop must always run.
          maybe_stop_forge_session(forge_session_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_ready(session_id, pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:ready, ^session_id} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, "harness_died_during_bootstrap: #{inspect(reason)}"}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, "harness_bootstrap_timeout"}
    end
  end

  defp bootstrap_timeout(run_timeout_ms), do: min(run_timeout_ms, 60_000)

  defp maybe_stop_forge_session(forge_session_id) do
    try do
      JidoClaw.Forge.Manager.stop_session(forge_session_id, :normal)
    catch
      _, _ -> :ok
    end
  end

  defp base_runner_config(:fake, _opts), do: %{fake_proposals: []}

  defp base_runner_config(:claude_code, opts) do
    %{
      model: Keyword.get(opts, :model, "claude-opus-4-7"),
      max_turns: Keyword.get(opts, :max_turns, 60),
      timeout_ms: Keyword.get(opts, :timeout_ms, 600_000),
      thinking_effort: Keyword.get(opts, :thinking_effort, "xhigh")
    }
  end

  defp base_runner_config(_, _), do: %{}

  defp maybe_add_fake_proposals(config, :fake, opts) do
    Map.put(config, :fake_proposals, Keyword.get(opts, :fake_proposals, []))
  end

  defp maybe_add_fake_proposals(config, _, _), do: config

  defp write_mcp_config(run_id, url) do
    path = Path.join(System.tmp_dir!(), "consolidator-#{run_id}.json")

    body =
      Jason.encode!(%{
        "mcpServers" => %{
          "consolidator" => %{
            "url" => url
          }
        }
      })

    File.write!(path, body)
    path
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
    case Fact.for_consolidator(%{
           tenant_id: tenant_id,
           scope_kind: scope_kind,
           scope_fk_id: fk,
           since_inserted_at: since_at,
           since_id: since_id,
           limit: limit
         }) do
      {:ok, facts} -> {:ok, facts}
      facts when is_list(facts) -> {:ok, facts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_messages(tenant_id, :session, fk, since_at, since_id, limit) do
    case Message.for_consolidator(%{
           tenant_id: tenant_id,
           scope_kind: :session,
           scope_fk_id: fk,
           since_inserted_at: since_at,
           since_id: since_id,
           limit: limit
         }) do
      {:ok, messages} -> {:ok, messages}
      messages when is_list(messages) -> {:ok, messages}
      {:error, reason} -> {:error, reason}
    end
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
    case ConsolidationRun.latest_for_scope(%{
           tenant_id: tenant_id,
           scope_kind: scope_kind,
           scope_fk_id: fk,
           status: :succeeded
         }) do
      {:ok, list} when is_list(list) -> list
      list when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
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
    case ConsolidationRun.history_for_scope(%{
           tenant_id: tenant_id,
           scope_kind: scope_kind,
           scope_fk_id: fk,
           limit: 20
         }) do
      {:ok, runs} -> first_non_null_watermark(runs, stream)
      runs when is_list(runs) -> first_non_null_watermark(runs, stream)
      _ -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
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
            tenant_id: state.scope.tenant_id,
            scope_kind: state.scope.scope_kind,
            user_id: state.scope[:user_id],
            workspace_id: state.scope[:workspace_id],
            project_id: state.scope[:project_id],
            session_id: state.scope[:session_id],
            started_at: started_at,
            finished_at: finished_at,
            status: :succeeded,
            forge_session_id: state.forge_session_id,
            harness: Keyword.get(consolidator_config(), :harness, :claude_code),
            harness_model: model_from_config()
          }
          |> Map.merge(counts)
          |> Map.merge(watermarks)

        case ConsolidationRun.record_run(run_attrs) do
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
    blocks_written = apply_block_updates(state)
    {facts_added_from_adds, ids_from_adds} = apply_fact_adds(state)

    {added_from_updates, invalidated_from_updates, supersede_links, ids_from_updates} =
      apply_fact_updates(state)

    invalidated_from_deletes = apply_fact_deletes(state)
    links_added = apply_link_creates(state) + supersede_links

    counts = %{
      messages_processed: length(state.messages || []),
      facts_processed: length(state.inputs || []),
      blocks_written: blocks_written,
      blocks_revised: 0,
      facts_added: facts_added_from_adds + added_from_updates,
      facts_invalidated: invalidated_from_deletes + invalidated_from_updates,
      links_added: links_added
    }

    {counts, ids_from_adds ++ ids_from_updates}
  end

  defp compute_watermarks(state) do
    deferred_cluster_ids =
      state.staging.cluster_defers
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
    Enum.reduce(state.staging.block_updates, 0, fn args, acc ->
      attrs = build_block_attrs(state, args)

      case maybe_revise_or_write_block(state, attrs) do
        {:ok, _} ->
          acc + 1

        err ->
          Logger.warning(
            "[Consolidator] block update skipped: " <>
              "label=#{inspect(Map.get(args, :label))} " <>
              "error=#{inspect(err)}"
          )

          acc
      end
    end)
  end

  defp build_block_attrs(state, args) do
    %{
      tenant_id: state.scope.tenant_id,
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
    case Block.history_for_label(
           state.scope.tenant_id,
           state.scope.scope_kind,
           Scope.primary_fk(state.scope),
           attrs.label
         ) do
      {:ok, [_ | _] = history} ->
        active = Enum.find(history, fn b -> is_nil(b.invalid_at) end)

        case active do
          nil -> Block.write(attrs)
          prior -> Block.revise(prior, attrs)
        end

      _ ->
        Block.write(attrs)
    end
  end

  defp apply_fact_adds(state) do
    Enum.reduce(state.staging.fact_adds, {0, []}, fn args, {count, ids} ->
      attrs = %{
        tenant_id: state.scope.tenant_id,
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

      case Fact.record(attrs) do
        {:ok, fact} ->
          {count + 1, [fact.id | ids]}

        err ->
          Logger.warning(
            "[Consolidator] fact add skipped: " <>
              "label=#{inspect(Map.get(args, :label))} " <>
              "error=#{inspect(err)}"
          )

          {count, ids}
      end
    end)
  end

  defp apply_fact_updates(state) do
    Enum.reduce(state.staging.fact_updates, {0, 0, 0, []}, fn args,
                                                              {added, invalidated, links, ids} ->
      case do_apply_fact_update(args) do
        {:ok, replacement, link_added?} ->
          link_inc = if link_added?, do: 1, else: 0
          {added + 1, invalidated + 1, links + link_inc, [replacement.id | ids]}

        err ->
          Logger.warning(
            "[Consolidator] fact update skipped: " <>
              "fact_id=#{inspect(Map.get(args, :fact_id))} " <>
              "error=#{inspect(err)}"
          )

          {added, invalidated, links, ids}
      end
    end)
  end

  defp do_apply_fact_update(args) do
    with {:ok, original} <-
           Ash.get(Fact, Map.get(args, :fact_id), domain: JidoClaw.Memory.Domain),
         :ok <- maybe_invalidate_unlabeled(original),
         {:ok, replacement} <- write_replacement(original, args) do
      {:ok, replacement, supersedes_link(replacement.id, original.id)}
    end
  end

  defp maybe_invalidate_unlabeled(%{label: nil} = fact) do
    case Fact.invalidate_by_id(fact, %{reason: "consolidator_update"}) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp maybe_invalidate_unlabeled(_), do: :ok

  defp write_replacement(original, args) do
    Fact.record(%{
      tenant_id: original.tenant_id,
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
    })
  end

  defp supersedes_link(new_id, old_id) do
    case Link.create_link(%{
           from_fact_id: new_id,
           to_fact_id: old_id,
           relation: :supersedes,
           reason: "consolidator_update",
           written_by: "consolidator"
         }) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp apply_fact_deletes(state) do
    Enum.reduce(state.staging.fact_deletes, 0, fn args, acc ->
      with {:ok, fact} <- Ash.get(Fact, Map.get(args, :fact_id), domain: JidoClaw.Memory.Domain),
           {:ok, _} <-
             Fact.invalidate_by_id(fact, %{reason: Map.get(args, :reason, "consolidator_delete")}) do
        acc + 1
      else
        err ->
          Logger.warning(
            "[Consolidator] fact delete skipped: " <>
              "fact_id=#{inspect(Map.get(args, :fact_id))} " <>
              "error=#{inspect(err)}"
          )

          acc
      end
    end)
  end

  defp apply_link_creates(state) do
    Enum.reduce(state.staging.link_creates, 0, fn args, acc ->
      with {:ok, relation} <- map_relation(Map.get(args, :relation)),
           attrs = link_attrs(args, relation),
           {:ok, _} <- Link.create_link(attrs) do
        acc + 1
      else
        err ->
          Logger.warning(
            "[Consolidator] link create skipped: " <>
              "from=#{inspect(Map.get(args, :from_fact_id))} " <>
              "to=#{inspect(Map.get(args, :to_fact_id))} " <>
              "relation=#{inspect(Map.get(args, :relation))} " <>
              "error=#{inspect(err)}"
          )

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

  defp finalise(state, status, error_string) do
    run_or_nil = maybe_write_run_row(state, status, error_string)

    reply =
      case {status, run_or_nil} do
        {:succeeded, {:ok, run}} -> {:ok, run}
        _ -> {:error, error_string}
      end

    do_finalise(state, reply)
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
      tenant_id: state.scope.tenant_id,
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
      harness: Keyword.get(consolidator_config(), :harness, :claude_code),
      harness_model: model_from_config()
    }

    case ConsolidationRun.record_run(attrs) do
      {:ok, run} ->
        if status == :failed, do: emit_run_telemetry(state, run, :failed, error_string)
        {:ok, run}

      {:error, err} ->
        Logger.warning("[Consolidator] failed to record run row: #{inspect(err)}")
        nil
    end
  end

  defp cleanup(state) do
    if state.lock_owner_pid, do: LockOwner.release(state.lock_owner_pid)
    if state.mcp_endpoint, do: MCPEndpoint.stop(state.mcp_endpoint)
    if state.temp_file_path, do: File.rm(state.temp_file_path)
    :ok
  end

  defp emit_run_telemetry(state, run, status, error) do
    duration_ms =
      DateTime.diff(run.finished_at || DateTime.utc_now(), run.started_at, :millisecond)

    measurements =
      %{
        duration_ms: duration_ms,
        harness_turns: 0,
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

  defp model_from_config do
    consolidator_config()
    |> Keyword.get(:harness_options, [])
    |> Keyword.get(:model)
  end

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
