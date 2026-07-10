defmodule JidoClaw.MCP.Consumer do
  # Defensive-by-design: prep crashes and per-agent registration faults are
  # rescued/caught so a dead or slow agent never aborts a batch or the prep.
  # reach:disable-for-this-file bare_rescue
  @moduledoc """
  Boot prep + attach coordinator for external MCP tool consumption, with
  bounded crash-recovery re-prep and periodic re-discovery.

  ## Prep (off-process, crash-isolated)

  `init/1` returns immediately and `spawn_monitor`s a **separate** prep process
  so the GenServer mailbox stays free. Prep (best-effort, internally rescued —
  it always sends `{:prepared_staged, …}` unless hard-killed): read config →
  register endpoints → await ready → discover tools → build inert proxy
  descriptors. The Consumer allocates/publishes modules only after accepting
  that complete correlated aggregate, then publishes approval policy, caches
  the module list, and flips to `:ready`. A rejected or hard-killed prep cannot
  mutate live proxy routing/schema or consume proxy-identity capacity.

  ## Crash-recovery re-prep (bounded backoff)

  A hard, untrappable prep kill is the only way prep dies without sending
  `{:prepared}`. Rather than parking in `:failed` forever, the Consumer
  schedules a bounded exponential-backoff re-prep (`reprep_*` config): each
  retry refreshes stuck endpoints and mints a fresh `generation`, and while a
  retry is pending the Consumer stays `:preparing` (incoming `ensure_attached`
  defers and recovers on the eventual `{:prepared}`; deferred fire-and-forget
  attaches are retained in `pending`). Only after `reprep_max_attempts`
  consecutive hard kills does it fall to a terminal, tool-less `:failed`.

  ## Periodic re-discovery (steady-state sync)

  While `:ready`, a single-owner timer (`rediscovery_interval_ms`, `0` disables
  auto-arming) re-runs discovery off-process and reconciles **every** attached
  agent against its template reach-allowlist on **every** tick — registering
  added/changed tools and **unregistering** removed ones. Reconcile is
  query-based + idempotent (it compares each agent's *live* `mcp_*` modules to
  the target set), so an in-sync pid costs one `list_tools` + skipped registers.
  A schema/description digest change keeps the stable module atom but queues its
  name for a forced unregister/register on every affected pid until a correlated
  task confirms success. Reconciling every tick — not gating it on a
  tool-set diff — is what lets a prior tick's failed reconcile and a stale tool
  a late attach task left both self-heal. Picks up new servers, tool-set
  changes, and a server unreachable at boot coming online (via endpoint
  refresh). Changing an *existing* server's connection spec (URL/command/env)
  under the same name is rejected by `EndpointConfig` as restart-required;
  Jido.MCP cannot hot-replace an already-registered endpoint safely.

  ## Attach (two non-blocking paths)

    * `attach_to_agent/2` (via the facade) records the pid, replies instantly,
      and registers in a **fire-and-forget supervised task** — used at REPL boot
      and the `:prepared`/restart rehydrate fan-out. The Consumer never
      `Task.yield`s in a callback.
    * `ensure_attached/3` (via the facade) answers `:modules_when_ready`
      immediately when `:ready` (or `:already` for a confirmed pid), else
      **defers** the reply until `{:prepared}` — the *caller* waits, registers,
      and confirms; the Consumer stays free.

  ## Per-template reach (registration filtering)

  Each attach carries the target agent's **template** name, and every server
  declares a reach-allowlist (`ServerSpec.templates`, normalized here to
  `:all | [name]` per generated module). `modules_for_template/3` keeps only the
  modules a template may reach — `:all` (empty/absent allowlist ⇒ every
  template) or membership in the named list — so an un-allowlisted worker is
  withheld the tools at *registration* (the LLM never sees them), strictly
  stronger and simpler than gating the call. A nil/non-binary template resolves
  to unrestricted-only. `"main"` is just a nameable template: an allowlist must
  include it to keep tools on the interactive agent.

  Per-module registration is independent (`has_tool?`/`register_tool` wrapped in
  `try/catch :exit` + rescue), so one dead/slow agent call warn-logs and
  continues instead of silently partial-registering. A batch is `:ok` only when
  **all** expected modules are confirmed present, else `:partial` (left unmarked
  so the next turn retries).

  ## Known limitations

    * Reconcile is eventually-consistent: tasks run async and attached pids stay
      marked throughout, so a turn landing between a `{:rediscovered}` apply and
      its reconcile tasks finishing uses the prior tool set for that one turn (a
      removed tool then fails at the proxy — and is gated when global MCP
      approval is on; an added tool appears the next turn). Because reconcile
      runs on every tick, a transient `:skip`/`:partial` and a stale tool a late
      attach task left both self-heal within one `rediscovery_interval_ms`.
  """

  use GenServer

  require Logger

  import Bitwise, only: [bsl: 2]

  alias JidoClaw.Agent.Templates
  alias JidoClaw.MCP.EndpointConfig
  alias JidoClaw.MCP.ProxyGenerator

  @register_timeout 5_000

  # Bounded crash re-prep: base << (attempt-1), capped, then terminal :failed.
  @default_reprep_max_attempts 5
  @default_reprep_backoff_ms 1_000
  @default_reprep_backoff_max_ms 30_000

  # Steady-state re-discovery cadence (0 disables auto-arming).
  @default_rediscovery_interval_ms 300_000

  # -- Child gating (pure, so the serve-mode/test gate is testable) --

  @doc """
  Whether the Consumer should be supervised, given the runtime flags.

  Absent in MCP serve mode (stdio is reserved for JSON-RPC) and when explicitly
  disabled (the test gate). Present otherwise (`:cli`/`:gateway`/`:both`).
  """
  @spec start?(atom() | nil, boolean()) :: boolean()
  def start?(serve_mode, consumer_enabled?) do
    serve_mode != :mcp and consumer_enabled? != false
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    parent = self()
    servers = Keyword.get(opts, :servers)
    {pid, ref} = spawn_monitor(fn -> run_prep(parent, servers, false) end)

    {:ok,
     %{
       status: :preparing,
       # Per-incarnation token (a fresh `make_ref/0`). Registration tasks carry
       # the generation that spawned them; a mark is honored only when the token
       # still matches, fencing out marks from a crashed prior incarnation or
       # from a register task that captured a now-superseded module set.
       generation: make_ref(),
       # The configured server list (nil ⇒ read from config). Retained so the
       # crash re-prep and re-discovery paths can re-run prep.
       servers: servers,
       # Injectable only at process construction so reconciliation failures can
       # be exercised without replacing the production Jido.AI module.
       agent_api: Keyword.get(opts, :agent_api, Jido.AI),
       modules: [],
       # Snapshot of runtime proxy definitions. Proxy module atoms are stable
       # across description/schema changes, so this digest map is the change
       # signal that forces cached ReqLLM tool metadata to be re-registered.
       definition_digests: %{},
       # %{module() => :all | [template_name]} — the reach-allowlist per
       # generated proxy module, accumulated across servers at prep.
       module_templates: %{},
       pending: %{},
       waiters: [],
       # %{pid => template} — confirmed-attached pids and the template each
       # attached under (re-discovery reconciles each pid against its template).
       attached: %{},
       # Definition-name refreshes are retained per pid until a reconcile task
       # confirms unregister+register succeeded. Stable proxy module atoms mean
       # a failed unregister otherwise becomes invisible on the next no-op tick
       # even though the agent still caches old ReqLLM metadata.
       definition_refreshes: %{},
       # %{pid => %{ref: reference(), names: MapSet.t(String.t())}} fences late
       # task acknowledgements from clearing a newer retry's pending names.
       reconcile_attempts: %{},
       monitors: %{},
       prep_ref: ref,
       prep_pid: pid,
       # Consecutive hard-crash re-prep attempts; reset to 0 on every `:ready`.
       reprep_attempts: 0,
       # In-flight re-discovery prep: monitor ref (correlation + crash DOWN) and
       # pid (result correlation + the crash test/manual smoke seam). Both nil
       # between ticks.
       rediscover_ref: nil,
       rediscover_pid: nil
     }}
  end

  @impl GenServer
  def handle_call({:attach, pid, template}, _from, state) do
    state = ensure_monitored(state, pid)

    case state.status do
      :ready ->
        modules = modules_for_template(state.modules, state.module_templates, template)
        start_register_task(pid, modules, state.generation, template, state.agent_api)
        {:reply, :ok, state}

      :preparing ->
        {:reply, :ok, %{state | pending: Map.put(state.pending, pid, template)}}

      :failed ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:modules_when_ready, pid, template}, from, state) do
    cond do
      # `:failed` first (defense-in-depth): a crashed Consumer reports
      # unavailable even if a stale `attached` entry ever slipped in.
      state.status == :failed ->
        {:reply, {:error, :mcp_unavailable}, state}

      # `attached` is pid-keyed and a pid's template is immutable for its
      # lifetime, so the `:already` fast path stays correct without re-filtering.
      Map.has_key?(state.attached, pid) ->
        {:reply, :already, state}

      state.status == :ready ->
        modules = modules_for_template(state.modules, state.module_templates, template)
        {:reply, {:ok, modules, state.generation}, ensure_monitored(state, pid)}

      true ->
        {:noreply, %{state | waiters: [{from, pid, template} | state.waiters]}}
    end
  end

  @impl GenServer
  # Honor the mark only while `:ready` AND only when the task's generation token
  # still matches this incarnation's (pin-by-repetition: the message `generation`
  # must equal the state's). A fire-and-forget registration task (under
  # `JidoClaw.TaskSupervisor`, which survives a Consumer crash) can finish and
  # cast `{:mark_attached, …}` *by registered name* into a **restarted** Consumer
  # — or, within one incarnation, after a re-discovery bumped `generation` past
  # it. A stale-generation success immediately queues an exact reconcile against
  # current reach; otherwise an old attach can re-add a removed tool after the
  # rediscovery task's snapshot and strand it until the next periodic tick.
  def handle_cast(
        {:mark_attached, pid, generation, template},
        %{status: :ready, generation: generation} = state
      ) do
    {:noreply, %{state | attached: Map.put(state.attached, pid, template)}}
  end

  def handle_cast({:mark_attached, pid, _stale_generation, template}, %{status: :ready} = state) do
    modules = modules_for_template(state.modules, state.module_templates, template)
    start_register_task(pid, modules, state.generation, template, state.agent_api)
    {:noreply, ensure_monitored(state, pid)}
  end

  def handle_cast({:mark_attached, _pid, _generation, _template}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:prepared_staged, staged_servers}, state) do
    {modules, policy, module_templates, definition_digests} =
      finalize_staged(staged_servers)

    apply_prepared(modules, policy, module_templates, definition_digests, state)
  end

  def handle_info(
        {:prepared_snapshot, modules, policy, module_templates, definition_digests},
        state
      ) do
    apply_prepared(modules, policy, module_templates, definition_digests, state)
  end

  # A hard, untrappable prep kill is the only way prep dies without sending
  # a prepared message (graceful failures send an empty/fallback snapshot).
  # Preserve the exact last-known-good policy: replacing it with `%{}` would let
  # an explicitly gated stale proxy inherit a globally trusted posture. Flush
  # current waiters with `:mcp_unavailable`, null the prep handles, then hand the
  # fate (bounded retry vs terminal `:failed`) to `reschedule_or_fail/2`.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prep_ref: ref} = state) do
    Logger.warning("[MCP] prep process died before completing (#{inspect(reason)})")

    Enum.each(state.waiters, fn {from, _pid, _template} ->
      GenServer.reply(from, {:error, :mcp_unavailable})
    end)

    flushed = %{state | waiters: [], prep_ref: nil, prep_pid: nil}
    {:noreply, reschedule_or_fail(flushed, state.reprep_attempts + 1)}
  end

  # A re-discovery prep that hard-crashes must NOT disturb the healthy `:ready`
  # state (existing tools keep working) — log, clear the handles, and re-arm so
  # the cadence survives. Matches the monitor ref, distinct from `prep_ref`.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{rediscover_ref: ref} = state) do
    Logger.warning("[MCP] re-discovery prep died (#{inspect(reason)}); keeping current tools")
    {:noreply, arm_rediscovery(%{state | rediscover_ref: nil, rediscover_pid: nil})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | pending: Map.delete(state.pending, pid),
         attached: Map.delete(state.attached, pid),
         definition_refreshes: Map.delete(state.definition_refreshes, pid),
         reconcile_attempts: Map.delete(state.reconcile_attempts, pid),
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  # Re-spawn the prep with `refresh?: true` (refresh stuck endpoints) and a fresh
  # `generation` (fences stale marks from the killed incarnation). `:reprep`
  # arrives only while `:preparing` (the retry the DOWN handler scheduled).
  def handle_info(:reprep, %{status: :preparing} = state) do
    parent = self()

    fallback_snapshot =
      {state.modules, JidoClaw.MCP.approval_policy(), state.module_templates,
       state.definition_digests}

    {pid, ref} =
      spawn_monitor(fn -> run_prep(parent, state.servers, true, fallback_snapshot) end)

    {:noreply, %{state | generation: make_ref(), prep_ref: ref, prep_pid: pid}}
  end

  # A stale `:reprep` timer firing after the Consumer already recovered to
  # `:ready` — a delivered timer message can't be cancelled, so this guard is the
  # only total defense.
  def handle_info(:reprep, state), do: {:noreply, state}

  # Launch an off-process re-discovery prep (only while `:ready` and not already
  # in flight). Do NOT re-arm here — the attempt's completion (`:rediscovered`)
  # or crash (the rediscover DOWN clause) owns the next arm, so the cadence never
  # doubles up.
  def handle_info(:rediscover, %{status: :ready, rediscover_ref: nil} = state) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> run_rediscovery(parent, state.servers) end)
    {:noreply, %{state | rediscover_ref: ref, rediscover_pid: pid}}
  end

  # A tick that arrives while not-`:ready` or with an attempt already in flight
  # is dropped; the cadence resumes via `{:prepared}` (recovery) or the in-flight
  # attempt's re-arm.
  def handle_info(:rediscover, state), do: {:noreply, state}

  # Apply a re-discovery result, correlated by the in-flight pid (a superseded
  # tick's result carries a different pid and is dropped by the fallthrough).
  # `demonitor(_, [:flush])` drops the trailing normal-exit DOWN.
  def handle_info(
        {:rediscovered_staged, pid, staged_servers},
        %{rediscover_pid: pid} = state
      ) do
    Process.demonitor(state.rediscover_ref, [:flush])

    {new_modules, new_policy, new_templates, new_digests} =
      finalize_staged(staged_servers)

    changed_names = changed_definition_names(state.definition_digests, new_digests)

    tools_changed? =
      new_modules != state.modules or new_templates != state.module_templates or
        changed_names != MapSet.new()

    reconciled = bump_generation(state, tools_changed?)
    :ok = publish_transition_policy(new_policy)

    # Reconcile every attached pid on EVERY tick (query-based + idempotent).
    # Changed-definition names are first made durable in Consumer state, then
    # subtracted only by a correlated `:ok` task result. Thus a transient failed
    # unregister cannot strand stale ReqLLM metadata after the digest diff has
    # already been committed.
    reconciling =
      reconcile_attached(reconciled, new_modules, new_templates, changed_names)

    applied = %{
      reconciling
      | modules: new_modules,
        definition_digests: new_digests,
        module_templates: new_templates,
        rediscover_ref: nil,
        rediscover_pid: nil
    }

    {:noreply, arm_rediscovery(applied)}
  end

  def handle_info({:rediscovery_failed, pid, failures}, %{rediscover_pid: pid} = state) do
    Process.demonitor(state.rediscover_ref, [:flush])

    Logger.warning(
      "[MCP] re-discovery failed for #{inspect(failures)}; keeping last-known-good tools"
    )

    kept = %{state | rediscover_ref: nil, rediscover_pid: nil}
    {:noreply, arm_rediscovery(kept)}
  end

  def handle_info({:reconciled, pid, ref, result}, state) do
    {:noreply, apply_reconcile_result(state, pid, ref, result)}
  end

  def handle_info({:rediscovered_staged, _pid, _staged_servers}, state),
    do: {:noreply, state}

  # Compatibility drop for a stale pre-staging message (and the regression test
  # that proves an uncorrelated result cannot mutate state).
  def handle_info({:rediscovered, _pid, _modules, _policy, _templates, _digests}, state),
    do: {:noreply, state}

  def handle_info({:rediscovery_failed, _pid, _failures}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_prepared(modules, policy, module_templates, definition_digests, state) do
    publish_transition_policy(policy)

    replied =
      Enum.reduce(state.waiters, state, fn {from, pid, template}, acc ->
        filtered = modules_for_template(modules, module_templates, template)
        GenServer.reply(from, {:ok, filtered, state.generation})
        ensure_monitored(acc, pid)
      end)

    ready = %{
      replied
      | status: :ready,
        modules: modules,
        definition_digests: definition_digests,
        module_templates: module_templates,
        waiters: [],
        prep_ref: nil,
        prep_pid: nil,
        # `:ready` ⇒ counter clear (keeps the invariant honest after a recovery).
        reprep_attempts: 0
    }

    fanned =
      ready
      |> fan_out_to_attached()
      |> fan_out_to_pending()
      |> fan_out_to_tracked()

    # Entering `:ready` is the single arm point for the re-discovery timer; every
    # later re-arm rides on an attempt finishing (never on launch).
    {:noreply, arm_rediscovery(fanned)}
  end

  # -- Crash re-prep fate (bounded backoff, then terminal) --

  # No guard on the helper (a config-reading function is illegal in a guard), so
  # dispatch on the read max here and split the two outcomes into structurally
  # distinct bodies.
  defp reschedule_or_fail(state, attempts) do
    if attempts <= reprep_max_attempts() do
      retry_reprep(state, attempts)
    else
      fail_terminally(state, attempts)
    end
  end

  # Retry: stay `:preparing`, schedule a backed-off `:reprep`, and RETAIN
  # pending/modules/module_templates so deferred fire-and-forget attaches are
  # served on the eventual `{:prepared}` and in-flight turns recover.
  # `prep_ref`/`prep_pid` stay nil (the killed prep is gone) until `:reprep`
  # re-spawns — an honest `:sys.get_state`.
  defp retry_reprep(state, attempts) do
    delay = reprep_backoff(attempts)

    Logger.warning(
      "[MCP] re-prep attempt #{attempts}/#{reprep_max_attempts()} scheduled in #{delay}ms"
    )

    Process.send_after(self(), :reprep, delay)
    %{state | status: :preparing, reprep_attempts: attempts}
  end

  # Terminal: every retry exhausted. Go fully inert and tool-less — clear
  # pending/modules/module_templates (waiters already flushed by the DOWN
  # handler). Honest `:failed` semantics: tool-less until a Consumer/app restart.
  defp fail_terminally(state, attempts) do
    Logger.warning(
      "[MCP] re-prep exhausted after #{attempts - 1} attempts; tool-less until restart"
    )

    %{
      state
      | status: :failed,
        reprep_attempts: attempts,
        pending: %{},
        modules: [],
        definition_digests: %{},
        module_templates: %{},
        definition_refreshes: %{},
        reconcile_attempts: %{}
    }
  end

  # -- Re-discovery apply --

  # Reconcile EVERY attached pid against its current template reach — runs on
  # every tick (the caller no longer gates this on a tool-set change). Each task
  # is query-based + idempotent (see `reconcile_pid/2`), so a pid already in sync
  # costs one `list_tools` + skipped registers, while a pid left out of sync by a
  # prior tick's `:skip`/`:partial` or by a late attach task converges here —
  # neither of which a `tools_changed?` diff can see once `modules` is committed.
  # An empty `attached` is a no-op, so a tick with no live agents stays free.
  defp reconcile_attached(state, new_modules, new_templates, changed_names) do
    refreshes =
      Enum.reduce(state.attached, state.definition_refreshes, fn {pid, _template}, acc ->
        Map.update(acc, pid, changed_names, &MapSet.union(&1, changed_names))
      end)

    state = %{state | definition_refreshes: refreshes}
    owner = self()

    Enum.reduce(state.attached, state, fn {pid, template}, acc ->
      reach = modules_for_template(new_modules, new_templates, template)
      force_names = Map.get(acc.definition_refreshes, pid, MapSet.new())
      ref = make_ref()

      case start_reconcile_task(owner, pid, reach, force_names, ref, acc.agent_api) do
        {:ok, _task_pid} ->
          attempt = %{ref: ref, names: force_names}
          %{acc | reconcile_attempts: Map.put(acc.reconcile_attempts, pid, attempt)}

        {:error, reason} ->
          Logger.warning(
            "[MCP] failed to start reconcile task for #{inspect(pid)}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp apply_reconcile_result(state, pid, ref, result) do
    case Map.get(state.reconcile_attempts, pid) do
      %{ref: ^ref, names: attempted_names} ->
        refreshes =
          if result == :ok do
            remaining =
              state.definition_refreshes
              |> Map.get(pid, MapSet.new())
              |> MapSet.difference(attempted_names)

            if MapSet.size(remaining) == 0,
              do: Map.delete(state.definition_refreshes, pid),
              else: Map.put(state.definition_refreshes, pid, remaining)
          else
            state.definition_refreshes
          end

        %{
          state
          | definition_refreshes: refreshes,
            reconcile_attempts: Map.delete(state.reconcile_attempts, pid)
        }

      _stale_or_unknown ->
        state
    end
  end

  defp changed_definition_names(old_digests, new_digests) do
    Enum.reduce(new_digests, MapSet.new(), fn {module, digest}, changed ->
      case Map.fetch(old_digests, module) do
        {:ok, old_digest} when old_digest != digest ->
          Logger.warning(
            "[MCP.Consumer] tool #{module.name()} re-discovered with a changed definition (description/schema); verify the server has not been tampered with"
          )

          MapSet.put(changed, module.name())

        _new_or_unchanged ->
          changed
      end
    end)
  end

  # Mint a fresh `generation` ONLY on a real tool-set change (still gated): a
  # `start_register_task` spawned just before this tick captured the OLD module
  # set and carries the CURRENT generation, so without a bump its later mark
  # would falsely confirm that pid against stale tools. Bumping makes the
  # existing fence redirects that mark into an immediate exact reconcile against
  # current reach. Any stale tool the old task re-added is pruned without waiting
  # for the next turn or periodic tick.
  defp bump_generation(state, true), do: %{state | generation: make_ref()}
  defp bump_generation(state, false), do: state

  # Publish the accepted target exactly for live names, while force-gating every
  # previously-known name removed from that target. Reconciliation is async; a
  # tombstone prevents a stale gated (or formerly trusted) proxy from inheriting
  # `mcp_require_approval: false` before its unregister completes. Tombstones are
  # retained until a future accepted target overwrites the same exact name.
  # A `:persistent_term.put` triggers a global GC, so the final value comparison
  # suppresses no-op publications.
  defp publish_transition_policy(new_policy) do
    current = JidoClaw.MCP.approval_policy()

    tombstones =
      current
      |> Map.keys()
      |> Enum.filter(fn name ->
        is_binary(name) and String.starts_with?(name, "mcp_") and
          not Map.has_key?(new_policy, name)
      end)
      |> Map.new(&{&1, true})

    transitioned_with_tombstones = Map.merge(current, tombstones)
    transitioned = Map.merge(transitioned_with_tombstones, new_policy)

    if policy_changed?(transitioned, current) do
      :persistent_term.put(JidoClaw.MCP.policy_key(), transitioned)
    end

    :ok
  end

  @doc """
  Whether `new_policy` differs from `current_policy` (a plain value compare).

  Public + documented so the re-discovery no-churn guard is directly unit-testable
  without a `:persistent_term` seam: a `:persistent_term.put` triggers a global
  GC, so the apply path republishes only when this returns true.
  """
  @spec policy_changed?(map(), map()) :: boolean()
  def policy_changed?(new_policy, current_policy), do: new_policy != current_policy

  defp arm_rediscovery(state) do
    case rediscovery_interval_ms() do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :rediscover, interval)
        state

      _disabled ->
        state
    end
  end

  # -- Registration (public: shared by ensure_attached and the fan-out tasks) --

  @doc """
  Register every module in `modules` onto `pid`, independently and bounded.

  Returns `:ok` only when **all** expected modules are confirmed present
  (`has_tool?`), else `:partial`. Idempotent: already-present tools are skipped.
  """
  @spec register_modules(pid(), [module()], timeout()) :: :ok | :partial
  def register_modules(pid, modules, timeout \\ @register_timeout) do
    register_modules_with(Jido.AI, pid, modules, timeout)
  end

  @doc """
  Reconcile `pid`'s external MCP tools to exactly `modules`.

  Unlike `register_modules/3`, this prunes stale `mcp_*` names and forcibly
  refreshes target names so a Consumer restart cannot retain cached metadata.
  """
  @spec reconcile_modules(pid(), [module()]) :: :ok | :partial
  def reconcile_modules(pid, modules) do
    reconcile_modules_with(Jido.AI, pid, modules)
  end

  defp reconcile_modules_with(agent_api, pid, modules) do
    force_names = MapSet.new(modules, & &1.name())

    case reconcile_pid(agent_api, pid, modules, force_names) do
      :ok -> :ok
      _partial_or_skip -> :partial
    end
  end

  defp register_modules_with(agent_api, pid, modules, timeout) do
    Enum.each(modules, &register_one(agent_api, pid, &1, timeout))
    if all_registered?(agent_api, pid, modules), do: :ok, else: :partial
  end

  defp register_and_mark(pid, modules, generation, template, agent_api) do
    case reconcile_modules_with(agent_api, pid, modules) do
      :ok -> GenServer.cast(__MODULE__, {:mark_attached, pid, generation, template})
      :partial -> :ok
    end
  end

  defp register_one(agent_api, pid, module, timeout) do
    case has_tool_safe(agent_api, pid, module.name()) do
      {:ok, true} -> :ok
      _absent_or_error -> safe_register(agent_api, pid, module, timeout)
    end
  end

  defp safe_register(agent_api, pid, module, timeout) do
    case agent_api.register_tool(pid, module, timeout: timeout) do
      {:ok, _agent} -> :ok
      {:error, reason} -> warn_register(module, reason)
    end
  rescue
    exception -> warn_register(module, exception)
  catch
    :exit, reason -> warn_register(module, reason)
  end

  defp warn_register(module, reason) do
    Logger.warning("[MCP] failed to register #{inspect(module)}: #{inspect(reason)}")
    :error
  end

  defp all_registered?(agent_api, pid, modules) do
    Enum.all?(modules, fn module ->
      match?({:ok, true}, has_tool_safe(agent_api, pid, module.name()))
    end)
  end

  defp has_tool_safe(agent_api, pid, name) do
    agent_api.has_tool?(pid, name)
  rescue
    _exception -> {:error, :rescue}
  catch
    :exit, _reason -> {:error, :exit}
  end

  # -- Reconcile (the supervised-task body — query-based, runs off the Consumer) --

  # Converge `pid`'s live `mcp_*` tools to exactly `reach` (the pid's current
  # template-allowlisted module set). Query-based, not an old/new diff, so it
  # self-corrects to the pid's ACTUAL tools regardless of how it drifted (a
  # passed-in diff would be wrong on a retry — see `stale_names/2`). Every
  # `Jido.AI` call is safe-wrapped + bounded, so a slow/dead agent never blocks
  # (the GenServer already returned before spawning this).
  #
  # Failure semantics: a failed list ABORTS (`:skip`, retried next tick) — never
  # treat the current set as empty, which would falsely claim convergence and
  # skip pruning. A failed unregister/register yields `:partial` (retried next
  # tick). A forced changed-definition name remains in `definition_refreshes`
  # until a correlated task reports `:ok`, so register-by-name cannot make a
  # failed unregister falsely look healed after the digest diff is committed.
  # Reconcile runs every tick, so both `:skip` and `:partial` genuinely heal next
  # interval.
  @spec reconcile_pid(module(), pid(), [module()], MapSet.t(String.t())) ::
          :ok | :partial | :skip
  defp reconcile_pid(agent_api, pid, reach, force_names) do
    case list_mcp_modules(agent_api, pid) do
      {:ok, current} ->
        reach_by_name = Map.new(reach, &{&1.name(), &1})
        to_unregister = MapSet.union(stale_names(current, reach_by_name), force_names)
        unregistered? = unregister_names(agent_api, pid, to_unregister)
        registered = register_modules_with(agent_api, pid, reach, @register_timeout)
        if unregistered? and registered == :ok, do: :ok, else: :partial

      :error ->
        :skip
    end
  end

  # Live mcp_* modules to drop: a name absent from `reach` (removed / now out of
  # the template's reach) OR present under a different module atom than the
  # target (for example, a stale module from an older implementation). Stable-atom
  # schema/description refreshes are supplied separately through `force_names`.
  # This query-based half compares the pid's LIVE modules to the target, so it
  # converges regardless of how the pid got out of sync.
  defp stale_names(current_modules, reach_by_name) do
    current_modules
    |> Enum.filter(fn module ->
      case Map.get(reach_by_name, module.name()) do
        nil -> true
        target -> target != module
      end
    end)
    |> MapSet.new(fn module -> module.name() end)
  end

  defp start_reconcile_task(owner, pid, reach, force_names, ref, agent_api) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      result = reconcile_pid(agent_api, pid, reach, force_names)
      send(owner, {:reconciled, pid, ref, result})
    end)
  end

  defp list_mcp_modules(agent_api, pid) do
    case safe_list_tools(agent_api, pid) do
      {:ok, modules} -> {:ok, Enum.filter(modules, &mcp_name?(&1.name()))}
      :error -> :error
    end
  end

  defp mcp_name?(name), do: String.starts_with?(name, "mcp_")

  defp safe_list_tools(agent_api, pid) do
    case agent_api.list_tools(pid) do
      {:ok, modules} -> {:ok, modules}
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  # Unregister every name in `names`; true only when every call confirmed. A
  # failure returns false (the pid is retried next tick) and is warn-logged.
  defp unregister_names(agent_api, pid, names) do
    Enum.reduce(names, true, fn name, ok? ->
      safe_unregister(agent_api, pid, name) and ok?
    end)
  end

  defp safe_unregister(agent_api, pid, name) do
    case agent_api.unregister_tool(pid, name, timeout: @register_timeout) do
      {:ok, _agent} -> true
      {:error, reason} -> warn_unregister(name, reason)
    end
  rescue
    exception -> warn_unregister(name, exception)
  catch
    :exit, reason -> warn_unregister(name, reason)
  end

  defp warn_unregister(name, reason) do
    Logger.warning("[MCP] failed to unregister #{inspect(name)}: #{inspect(reason)}")
    false
  end

  # The reach-allowlist filter: keep `mod` where its server admits every
  # template (`:all`) or names this (binary) one. A nil/non-binary template
  # falls back to unrestricted-only — the `is_binary` guard lives here (not on
  # the facade) so the facade's `template` stays a required *position*, not a
  # required binary. An empty result registers vacuously (`:ok`), so an
  # un-allowlisted worker attaches with no tools rather than erroring.
  @spec modules_for_template([module()], %{module() => :all | [String.t()]}, term()) ::
          [module()]
  defp modules_for_template(modules, module_templates, template) do
    # AR-8b capability boundary: a sandboxed template (`sandbox: :prototype`)
    # gets ZERO external MCP tools — at attach AND on every reconcile tick, so
    # a tool can never be (re-)added behind the sketch jail. An empty result is
    # already in-contract (registers vacuously `:ok`). `external_tools?/1` is
    # `true` for a nil/non-binary/unknown template, so this only ever subtracts.
    if is_binary(template) and not Templates.external_tools?(template) do
      []
    else
      Enum.filter(modules, fn mod ->
        case Map.get(module_templates, mod) do
          :all -> true
          allowed when is_list(allowed) -> is_binary(template) and template in allowed
          _missing -> false
        end
      end)
    end
  end

  # -- Fan-out --

  defp fan_out_to_attached(state), do: fan_out_entries(state, state.attached)

  defp fan_out_to_pending(state) do
    state = fan_out_entries(state, state.pending)
    %{state | pending: %{}}
  end

  defp fan_out_entries(state, entries) do
    Enum.each(entries, fn {pid, template} ->
      modules = modules_for_template(state.modules, state.module_templates, template)
      start_register_task(pid, modules, state.generation, template, state.agent_api)
    end)

    state
  end

  defp fan_out_to_tracked(state) do
    tracked_live_pids()
    # `attached` is pid-keyed (the value is the tracked template), so reject on
    # the pid before registering each pid's filtered subset.
    |> Enum.reject(fn {pid, _template} -> Map.has_key?(state.attached, pid) end)
    |> Enum.reduce(state, fn {pid, template}, acc ->
      modules = modules_for_template(state.modules, state.module_templates, template)
      start_register_task(pid, modules, state.generation, template, state.agent_api)
      ensure_monitored(acc, pid)
    end)
  end

  # AgentTracker retains terminal entries (it does not drop `:done`/`:error`),
  # so filter to live `:running` pids — and tolerate the tracker not being up
  # yet (the Consumer starts right after it, but a restart can race). Returns
  # `[{pid, template}]`: main and skill-step workers aren't tracker-registered,
  # so every tracked template is a worker binary; a non-binary still falls back
  # to unrestricted-only downstream.
  defp tracked_live_pids do
    case Process.whereis(JidoClaw.AgentTracker) do
      nil ->
        []

      _tracker ->
        agents = Map.get(JidoClaw.AgentTracker.get_state(), :agents, %{})

        for {_id, entry} <- agents,
            entry.status == :running and is_pid(entry.pid) and Process.alive?(entry.pid),
            do: {entry.pid, entry.template}
    end
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp start_register_task(pid, modules, generation, template, agent_api) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      register_and_mark(pid, modules, generation, template, agent_api)
    end)
  end

  defp ensure_monitored(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  # -- Prep (off-process) --

  defp run_prep(parent, servers, refresh?, fallback_snapshot \\ nil) do
    case prepare(servers, refresh?) do
      {_staged_servers, [_ | _]} when not is_nil(fallback_snapshot) ->
        send_prepared_snapshot(parent, fallback_snapshot)

      {staged_servers, _failures} ->
        send(parent, {:prepared_staged, staged_servers})
    end
  rescue
    exception ->
      Logger.warning("[MCP] prep failed: #{inspect(exception)}")
      send_prepared_snapshot(parent, fallback_snapshot || {[], %{}, %{}, %{}})
  catch
    kind, reason ->
      Logger.warning("[MCP] prep crashed: #{inspect({kind, reason})}")
      send_prepared_snapshot(parent, fallback_snapshot || {[], %{}, %{}, %{}})
  end

  defp send_prepared_snapshot(
         parent,
         {modules, policy, module_templates, definition_digests}
       ) do
    send(
      parent,
      {:prepared_snapshot, modules, policy, module_templates, definition_digests}
    )
  end

  # Off-process re-discovery prep. Tags its result with `self()` so a superseded
  # tick's late result is dropped by the apply handler. `refresh?: true` so a
  # server that came online since boot is picked up.
  defp run_rediscovery(parent, servers) do
    case prepare(servers, true) do
      {_staged_servers, [_ | _] = failures} ->
        send(parent, {:rediscovery_failed, self(), failures})

      {staged_servers, []} ->
        send(parent, {:rediscovered_staged, self(), staged_servers})
    end
  rescue
    exception ->
      Logger.warning("[MCP] re-discovery prep failed: #{inspect(exception)}")
      send(parent, {:rediscovery_failed, self(), [{:exception, exception}]})
  catch
    kind, reason ->
      Logger.warning("[MCP] re-discovery prep crashed: #{inspect({kind, reason})}")
      send(parent, {:rediscovery_failed, self(), [{kind, reason}]})
  end

  # Config-shape warnings (parse + unknown-template) are logged once, on the
  # initial boot prep (`refresh? == false`); the re-prep and per-tick
  # re-discovery paths stay quiet about config they already reported.
  defp prepare(servers, refresh?) do
    {specs, warnings} = EndpointConfig.parse(servers || configured_servers())

    unless refresh? do
      Enum.each(warnings, fn warning -> Logger.warning("[MCP] #{warning}") end)
      warn_unknown_templates(specs)
    end

    results =
      specs
      |> Task.async_stream(&prepare_server(&1, refresh?),
        max_concurrency: max(length(specs), 1),
        timeout: server_prep_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:prep_exit, reason}}
      end)

    successes = for {:ok, result} <- results, do: result
    discovery_failures = for {:error, reason} <- results, do: reason
    config_failures = if refresh?, do: Enum.map(warnings, &{:config, &1}), else: []
    failures = config_failures ++ discovery_failures

    {successes, failures}
  end

  # Acceptance boundary: this runs only in the Consumer after a correlated
  # `:prepared_staged` / `:rediscovered_staged` message wins. `commit_stages/1`
  # allocates identities and publishes every definition in one registry write;
  # only then is it safe to call the stable modules' runtime metadata functions.
  defp finalize_staged(staged_servers) do
    module_lists =
      staged_servers
      |> Enum.map(fn {_spec, stage} -> stage end)
      |> ProxyGenerator.commit_stages()

    {module_groups, policy, module_templates} =
      staged_servers
      |> Enum.zip(module_lists)
      |> Enum.reduce({[], %{}, %{}}, fn {{spec, _stage}, server_modules},
                                        {all_modules, all_policy, all_templates} ->
        server_policy =
          Map.new(server_modules, fn module -> {module.name(), spec.require_approval} end)

        allowed = template_allowance(spec.templates)
        server_templates = Map.new(server_modules, fn module -> {module, allowed} end)

        {
          [server_modules | all_modules],
          Map.merge(all_policy, server_policy),
          Map.merge(all_templates, server_templates)
        }
      end)

    modules = List.flatten(Enum.reverse(module_groups))
    {modules, policy, module_templates, definition_digests(modules)}
  end

  # Operator hygiene: an allowlist naming a template that doesn't exist would
  # silently grant tools to no one. Warn (don't drop), mirroring the parse-time
  # warn-and-skip posture. `Templates.get/1` honors the `:agent_templates_
  # override` test/custom hook (unlike `names/0`/`exists?/1`); `"main"` is a
  # nameable pseudo-template absent from the registry, so never false-warn on it.
  defp warn_unknown_templates(specs) do
    for spec <- specs,
        name <- spec.templates,
        name != "main",
        match?({:error, _reason}, Templates.get(name)) do
      Logger.warning(
        "[MCP] server #{spec.name}: allowlist references unknown template #{inspect(name)}"
      )
    end

    :ok
  end

  # A healthy endpoint lists fine and is never refreshed. A failed one, when
  # `refresh?` is set (crash re-prep + re-discovery), is `refresh_endpoint`ed
  # (a real stop+restart — the cure for an alive-but-stuck client whose server
  # was unreachable at boot init, which a plain re-register can't fix) and
  # retried ONCE. Boot passes `refresh? == false` to stay fast when a server is
  # simply down.
  defp prepare_server(spec, refresh?) do
    client = JidoClaw.MCP.client()

    case discover(client, spec) do
      {:ok, tools} ->
        {:ok, build_server_result(spec, tools)}

      {:error, _reason} when refresh? ->
        _ = client.refresh_endpoint(spec.endpoint.id)

        case discover(client, spec) do
          {:ok, tools} -> {:ok, build_server_result(spec, tools)}
          error -> discovery_failed(spec, error)
        end

      error ->
        discovery_failed(spec, error)
    end
  end

  # The register→await→list chain, single-sourced so the boot path and the
  # refresh-retry path don't each carry the same `with`-block (clone check).
  defp discover(client, spec) do
    with :ok <- client.register_endpoint(spec.endpoint),
         :ok <- client.await_endpoint_ready(spec.endpoint.id, ready_timeout()) do
      client.list_tools(spec.endpoint.id, list_tools_timeout())
    end
  end

  defp build_server_result(spec, tools),
    do: {spec, ProxyGenerator.stage_modules(spec.name, spec.endpoint.id, tools)}

  defp discovery_failed(spec, error) do
    Logger.warning("[MCP] server #{spec.name}: discovery failed: #{inspect(error)}")
    {:error, {spec.name, error}}
  end

  defp definition_digests(modules) do
    Map.new(modules, fn module -> {module, ProxyGenerator.definition_digest(module)} end)
  end

  # `[]`/absent ⇒ `:all` (every template reaches these tools — back-compat);
  # a non-empty list ⇒ only those template names.
  defp template_allowance([]), do: :all
  defp template_allowance(list) when is_list(list), do: list

  defp configured_servers do
    case Application.get_env(:jido_claw, :mcp_servers) do
      list when is_list(list) -> list
      _other -> JidoClaw.Config.mcp_servers(JidoClaw.Config.load())
    end
  end

  defp ready_timeout, do: mcp_opt(:ready_timeout_ms, 10_000)
  defp list_tools_timeout, do: mcp_opt(:list_tools_timeout_ms, 10_000)
  defp server_prep_timeout, do: mcp_opt(:server_prep_timeout_ms, 30_000)
  defp reprep_max_attempts, do: mcp_opt(:reprep_max_attempts, @default_reprep_max_attempts)
  defp reprep_backoff_base, do: mcp_opt(:reprep_backoff_ms, @default_reprep_backoff_ms)
  defp reprep_backoff_max, do: mcp_opt(:reprep_backoff_max_ms, @default_reprep_backoff_max_ms)

  defp rediscovery_interval_ms,
    do: mcp_opt(:rediscovery_interval_ms, @default_rediscovery_interval_ms)

  # min(base << (attempt-1), cap) — deterministic, no jitter (a single Consumer,
  # so no thundering herd; determinism aids the test).
  defp reprep_backoff(attempt) do
    min(bsl(reprep_backoff_base(), attempt - 1), reprep_backoff_max())
  end

  defp mcp_opt(key, default) do
    Keyword.get(Application.get_env(:jido_claw, :mcp, []), key, default)
  end
end
