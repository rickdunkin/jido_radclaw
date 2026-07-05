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
  it always sends `{:prepared, …}` unless hard-killed): read config → register
  endpoints → await ready → discover tools → compile safe proxy modules. The
  Consumer then publishes the per-server approval policy to `:persistent_term`,
  caches the module list, and flips to `:ready`.

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
  the target set), so an in-sync pid costs one `list_tools` + skipped registers;
  a tool whose schema/description changed (same `.name()`, new content-addressed
  module atom) is caught by the live-atom-vs-target mismatch and
  unregistered-then-registered. Reconciling every tick — not gating it on a
  tool-set diff — is what lets a prior tick's failed reconcile and a stale tool
  a late attach task left both self-heal. Picks up new servers, tool-set
  changes, and a server unreachable at boot coming online (via endpoint
  refresh). Changing an *existing* server's connection spec (URL/command/env) is
  out of scope (config hot-reload — `unregister_endpoint` + re-register).

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

    * The per-pid reconcile keys on `module.name()`; a same-name redefinition is
      handled by comparing the live module atom to the target
      (unregister-then-register), but the orphaned old module atom lingers in the
      code server (BEAM does not unload it) — harmless.
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
       modules: [],
       # %{module() => :all | [template_name]} — the reach-allowlist per
       # generated proxy module, accumulated across servers at prep.
       module_templates: %{},
       pending: %{},
       waiters: [],
       # %{pid => template} — confirmed-attached pids and the template each
       # attached under (re-discovery reconciles each pid against its template).
       attached: %{},
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
        start_register_task(pid, modules, state.generation, template)
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
  # it. Either way the generation mismatch drops it, the pid stays unmarked, and
  # a later `ensure_attached/3` idempotently re-registers + re-marks the *current*
  # reach (self-healing). Within an unchanged incarnation the token always
  # matches, so nothing legitimate is dropped.
  def handle_cast(
        {:mark_attached, pid, generation, template},
        %{status: :ready, generation: generation} = state
      ) do
    {:noreply, %{state | attached: Map.put(state.attached, pid, template)}}
  end

  def handle_cast({:mark_attached, _pid, _generation, _template}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:prepared, modules, policy, module_templates}, state) do
    :persistent_term.put(JidoClaw.MCP.policy_key(), policy)

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
        module_templates: module_templates,
        waiters: [],
        prep_ref: nil,
        prep_pid: nil,
        # `:ready` ⇒ counter clear (keeps the invariant honest after a recovery).
        reprep_attempts: 0
    }

    fanned =
      ready
      |> fan_out_to_pending()
      |> fan_out_to_tracked()

    # Entering `:ready` is the single arm point for the re-discovery timer; every
    # later re-arm rides on an attempt finishing (never on launch).
    {:noreply, arm_rediscovery(fanned)}
  end

  # A hard, untrappable prep kill is the only way prep dies without sending
  # `{:prepared}` (graceful failures are rescued into `{:prepared, [], %{}, %{}}`).
  # Republish an empty (fail-closed: gated) policy so a restart can't retain
  # stale trust decisions, flush current waiters with `:mcp_unavailable`, null
  # the prep handles, then hand the fate (bounded retry vs terminal `:failed`)
  # to `reschedule_or_fail/2`.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prep_ref: ref} = state) do
    Logger.warning("[MCP] prep process died before completing (#{inspect(reason)})")

    :persistent_term.put(JidoClaw.MCP.policy_key(), %{})

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
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  # Re-spawn the prep with `refresh?: true` (refresh stuck endpoints) and a fresh
  # `generation` (fences stale marks from the killed incarnation). `:reprep`
  # arrives only while `:preparing` (the retry the DOWN handler scheduled).
  def handle_info(:reprep, %{status: :preparing} = state) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> run_prep(parent, state.servers, true) end)
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
        {:rediscovered, pid, new_modules, new_policy, new_templates},
        %{rediscover_pid: pid} = state
      ) do
    Process.demonitor(state.rediscover_ref, [:flush])

    tools_changed? =
      new_modules != state.modules or new_templates != state.module_templates

    # Reconcile every attached pid on EVERY tick (query-based + idempotent): a
    # prior tick's failed reconcile (`:skip`/`:partial`) and a stale tool a late
    # attach task left both heal here — neither is visible to a `tools_changed?`
    # gate once `modules` is committed. Cheap when in sync (one `list_tools` +
    # skipped registers); only an out-of-sync pid is written. Empty `attached`
    # ⇒ a no-op, so a tick with no agents stays free.
    reconcile_attached(state.attached, new_modules, new_templates)

    reconciled =
      state
      |> bump_generation(tools_changed?)
      |> maybe_republish_policy(new_policy)

    applied = %{
      reconciled
      | modules: new_modules,
        module_templates: new_templates,
        rediscover_ref: nil,
        rediscover_pid: nil
    }

    {:noreply, arm_rediscovery(applied)}
  end

  def handle_info({:rediscovered, _pid, _modules, _policy, _templates}, state),
    do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

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
        module_templates: %{}
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
  defp reconcile_attached(attached, new_modules, new_templates) do
    Enum.each(attached, fn {pid, template} ->
      reach = modules_for_template(new_modules, new_templates, template)
      start_reconcile_task(pid, reach)
    end)
  end

  # Mint a fresh `generation` ONLY on a real tool-set change (still gated): a
  # `start_register_task` spawned just before this tick captured the OLD module
  # set and carries the CURRENT generation, so without a bump its later mark
  # would falsely confirm that pid against stale tools. Bumping makes the
  # existing fence DROP that mark (the pid stays unmarked and self-heals its mark
  # on the next `ensure_attached`; any stale tool it left is pruned by the
  # every-tick `reconcile_attached`, no longer only at the next *changed* tick).
  defp bump_generation(state, true), do: %{state | generation: make_ref()}
  defp bump_generation(state, false), do: state

  # A `:persistent_term.put` triggers a global GC, so only republish when the
  # value actually changed (compared against the live published map).
  defp maybe_republish_policy(state, new_policy) do
    if policy_changed?(new_policy, JidoClaw.MCP.approval_policy()) do
      :persistent_term.put(JidoClaw.MCP.policy_key(), new_policy)
    end

    state
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
    Enum.each(modules, &register_one(pid, &1, timeout))
    if all_registered?(pid, modules), do: :ok, else: :partial
  end

  defp register_and_mark(pid, modules, generation, template) do
    case register_modules(pid, modules) do
      :ok -> GenServer.cast(__MODULE__, {:mark_attached, pid, generation, template})
      :partial -> :ok
    end
  end

  defp register_one(pid, module, timeout) do
    case has_tool_safe(pid, module.name()) do
      {:ok, true} -> :ok
      _absent_or_error -> safe_register(pid, module, timeout)
    end
  end

  defp safe_register(pid, module, timeout) do
    case Jido.AI.register_tool(pid, module, timeout: timeout) do
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

  defp all_registered?(pid, modules) do
    Enum.all?(modules, fn module -> match?({:ok, true}, has_tool_safe(pid, module.name())) end)
  end

  defp has_tool_safe(pid, name) do
    Jido.AI.has_tool?(pid, name)
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
  # tick); safe because register-by-name skips an already-present tool, so a
  # failed prune of an atom-swapped name just leaves the old module until the
  # retry re-detects the swap (no duplication, no half-update). Reconcile runs
  # every tick, so both `:skip` and `:partial` genuinely heal next interval.
  @spec reconcile_pid(pid(), [module()]) :: :ok | :partial | :skip
  defp reconcile_pid(pid, reach) do
    case list_mcp_modules(pid) do
      {:ok, current} ->
        reach_by_name = Map.new(reach, &{&1.name(), &1})
        to_unregister = stale_names(current, reach_by_name)
        unregistered? = unregister_names(pid, to_unregister)
        registered = register_modules(pid, reach)
        if unregistered? and registered == :ok, do: :ok, else: :partial

      :error ->
        :skip
    end
  end

  # Live mcp_* modules to drop: a name absent from `reach` (removed / now out of
  # the template's reach) OR present under a DIFFERENT module atom than the target
  # (a same-name content-addressed redefinition — register-by-name alone would
  # skip the new atom, so the stale one must be unregistered first). Query-based:
  # compares the pid's LIVE modules to the target, so it converges regardless of
  # how the pid got out of sync (no remembered diff needed for a retry).
  defp stale_names(current_modules, reach_by_name) do
    warn_changed_definitions(current_modules, reach_by_name)

    current_modules
    |> Enum.filter(fn module ->
      case Map.get(reach_by_name, module.name()) do
        nil -> true
        target -> target != module
      end
    end)
    |> MapSet.new(fn module -> module.name() end)
  end

  # S-L1: warn when a tool's NAME persists across re-discovery but its generated
  # module atom changed — the remote re-advertised a changed description/schema
  # (`ProxyGenerator.definition_hash/5` is baked into the module atom, so a
  # different atom for the same name IS the changed-definition signal; there is no
  # retained per-tool digest to diff). Tool names/descriptions are prompt-trusted
  # before any call, so post-vetting drift is a (low) injection surface with no
  # operator signal otherwise. `Logger.warning` only — `JidoClaw.Display` has no
  # generic notice API (a visible banner would need a new Display surface, a
  # follow-up out of scope for this hardening batch).
  defp warn_changed_definitions(current_modules, reach_by_name) do
    Enum.each(current_modules, fn module ->
      case Map.get(reach_by_name, module.name()) do
        target when not is_nil(target) and target != module ->
          Logger.warning(
            "[MCP.Consumer] tool #{module.name()} re-discovered with a changed definition " <>
              "(description/schema); verify the server has not been tampered with"
          )

        _unchanged_or_removed ->
          :ok
      end
    end)
  end

  defp start_reconcile_task(pid, reach) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      reconcile_pid(pid, reach)
    end)
  end

  defp list_mcp_modules(pid) do
    case safe_list_tools(pid) do
      {:ok, modules} -> {:ok, Enum.filter(modules, &mcp_name?(&1.name()))}
      :error -> :error
    end
  end

  defp mcp_name?(name), do: String.starts_with?(name, "mcp_")

  defp safe_list_tools(pid) do
    case Jido.AI.list_tools(pid) do
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
  defp unregister_names(pid, names) do
    Enum.reduce(names, true, fn name, ok? -> safe_unregister(pid, name) and ok? end)
  end

  defp safe_unregister(pid, name) do
    case Jido.AI.unregister_tool(pid, name, timeout: @register_timeout) do
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

  defp fan_out_to_pending(state) do
    Enum.each(state.pending, fn {pid, template} ->
      modules = modules_for_template(state.modules, state.module_templates, template)
      start_register_task(pid, modules, state.generation, template)
    end)

    %{state | pending: %{}}
  end

  defp fan_out_to_tracked(state) do
    tracked_live_pids()
    # `attached` is pid-keyed (the value is the tracked template), so reject on
    # the pid before registering each pid's filtered subset.
    |> Enum.reject(fn {pid, _template} -> Map.has_key?(state.attached, pid) end)
    |> Enum.reduce(state, fn {pid, template}, acc ->
      modules = modules_for_template(state.modules, state.module_templates, template)
      start_register_task(pid, modules, state.generation, template)
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

  defp start_register_task(pid, modules, generation, template) do
    Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn ->
      register_and_mark(pid, modules, generation, template)
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

  defp run_prep(parent, servers, refresh?) do
    {modules, policy, module_templates} = prepare(servers, refresh?)
    send(parent, {:prepared, modules, policy, module_templates})
  rescue
    exception ->
      Logger.warning("[MCP] prep failed: #{inspect(exception)}")
      send(parent, {:prepared, [], %{}, %{}})
  catch
    kind, reason ->
      Logger.warning("[MCP] prep crashed: #{inspect({kind, reason})}")
      send(parent, {:prepared, [], %{}, %{}})
  end

  # Off-process re-discovery prep. Tags its result with `self()` so a superseded
  # tick's late result is dropped by the apply handler. `refresh?: true` so a
  # server that came online since boot is picked up.
  defp run_rediscovery(parent, servers) do
    {modules, policy, module_templates} = prepare(servers, true)
    send(parent, {:rediscovered, self(), modules, policy, module_templates})
  rescue
    exception ->
      Logger.warning("[MCP] re-discovery prep failed: #{inspect(exception)}")
      send(parent, {:rediscovered, self(), [], %{}, %{}})
  catch
    kind, reason ->
      Logger.warning("[MCP] re-discovery prep crashed: #{inspect({kind, reason})}")
      send(parent, {:rediscovered, self(), [], %{}, %{}})
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
        {:exit, _reason} -> {[], %{}, %{}}
      end)

    modules = Enum.flat_map(results, fn {mods, _policy, _module_templates} -> mods end)
    policy = Enum.reduce(results, %{}, fn {_mods, pol, _mt}, acc -> Map.merge(acc, pol) end)

    module_templates =
      Enum.reduce(results, %{}, fn {_mods, _pol, mt}, acc -> Map.merge(acc, mt) end)

    {modules, policy, module_templates}
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
        build_server_result(spec, tools)

      {:error, _reason} when refresh? ->
        _ = client.refresh_endpoint(spec.endpoint.id)

        case discover(client, spec) do
          {:ok, tools} -> build_server_result(spec, tools)
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

  defp build_server_result(spec, tools) do
    modules = ProxyGenerator.build_modules(spec.name, spec.endpoint.id, tools)
    policy = Map.new(modules, fn module -> {module.name(), spec.require_approval} end)
    allowed = template_allowance(spec.templates)
    module_templates = Map.new(modules, fn module -> {module, allowed} end)
    {modules, policy, module_templates}
  end

  defp discovery_failed(spec, error) do
    Logger.warning("[MCP] server #{spec.name}: discovery failed: #{inspect(error)}")
    {[], %{}, %{}}
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
