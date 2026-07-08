defmodule JidoClaw.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias JidoClaw.Tenant.Manager

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Session metrics
      counter("jido_claw.session.start.total"),
      counter("jido_claw.session.stop.total"),
      # The metric name's display segment (`duration`) diverges from the
      # emitted event (`[…, :stop]`, measurement `%{duration: …}`), so an
      # explicit `event_name:` is required or the tile never fires.
      summary("jido_claw.session.duration",
        unit: {:native, :millisecond},
        event_name: [:jido_claw, :session, :stop]
      ),
      counter("jido_claw.session.message.total", tags: [:role]),

      # Provider/LLM metrics
      counter("jido_claw.provider.request.start.total"),
      counter("jido_claw.provider.request.stop.total"),
      summary("jido_claw.provider.request.duration",
        unit: {:native, :millisecond},
        event_name: [:jido_claw, :provider, :request, :stop]
      ),
      counter("jido_claw.provider.request.exception.total"),
      sum("jido_claw.provider.tokens.total", tags: [:type]),

      # Tool execution metrics
      counter("jido_claw.tool.execute.start.total"),
      counter("jido_claw.tool.execute.stop.total"),
      summary("jido_claw.tool.execute.duration",
        unit: {:native, :millisecond},
        event_name: [:jido_claw, :tool, :execute, :stop]
      ),
      counter("jido_claw.tool.execute.exception.total"),

      # Output shaping metrics — both derive from the single
      # [:jido_claw, :tool, :shaping] event (the metric name's last
      # segment selects the measurement), so one execute serves both.
      counter("jido_claw.tool.shaping.total", tags: [:tool, :format]),
      sum("jido_claw.tool.shaping.bytes_saved", tags: [:tool]),

      # Doom-loop guard metrics (JidoClaw.Agent.LoopGuard) — the Trace
      # `:guardrail` events carry the per-key timeline; this is the rollup.
      counter("jido_claw.loop_guard.total", tags: [:event, :trigger]),

      # Lua code-mode evals (JidoClaw.Tools.Lua.Runner) — one count per
      # lua_query eval; `status` is completed/failed (plus the discrete
      # budget_refused emission), `trigger` the `:lua_*` failure code.
      counter("jido_claw.lua_eval.total", tags: [:status, :trigger]),

      # Composer verdict-infra events (camus C1-3) — one count per infra'd
      # stage; `lane` is :output (a judge's unusable verdict) or :wave_error
      # (a lens-only wave execution failure). The Trace `:composer` events
      # carry the per-run timeline; this is the rollup.
      counter("jido_claw.composer.infra.total", tags: [:lane, :stage]),

      # Deterministic verify runs (next-ten item 5, camus C1-2) — one count
      # per engine verify; `result` is :green/:red/:inconclusive/:tampered.
      # The Trace `:composer` verify_result events carry the per-run detail.
      counter("jido_claw.verify.total", tags: [:result]),

      # Forge-executor steps (item 7, camus C1-1 PR-1) — one count per
      # `{:forge, _}` step through the ForgeExecutor bridge; `kind` is
      # :fake/:shell, `outcome` :ok/:error. The in-process arm emits nothing;
      # the durable transcript envelope carries the per-step detail.
      counter("jido_claw.executor.total", tags: [:kind, :outcome]),

      # Review-independence resolutions (item 7, camus C1-1 PR-3) — one count
      # per launch-time `check_route/2` that found a same-vendor/indeterminate
      # review pairing; `outcome` is :held (strict refusal) or :degraded_pass
      # (the operator's `independence: degraded` opt-in). A clean check emits
      # nothing; the durable parent terminal carries the per-run detail.
      counter("jido_claw.review_independence.total", tags: [:outcome]),

      # Composer fix-loop stall stops (next-ten item 6, camus C1-5) — one
      # count per stopped lens; `kind` is :stuck/:oscillating/:rereview_exhausted.
      # The Trace `:composer` events carry the per-run detail (hex keys only).
      counter("jido_claw.composer.stall.total", tags: [:kind, :lens]),

      # Needs-input answer-loop (item 7 PR-4) — one count per producer action:
      # `event` is :raise/:claim, `outcome` :opened/:reused/:consumed/:error.
      # A claim that finds nothing emits nothing; the case row + its timeline
      # carry the per-question detail.
      counter("jido_claw.needs_input.total", tags: [:event, :outcome]),

      # Ambiguity clarify loop (item 8, OB1-1) — one count per lane event:
      # `event` is :open/:round/:hold/:compose/:scorer_failed/:persist_failed/
      # :new_ask/:expired/:one_shot_cleared; `outcome` qualifies it (:ok,
      # :clean/:degraded/:override/:one_shot_degraded/:launch_failed on
      # :compose, :scorer_failed/:persist_failed on :open, :clear_failed on
      # the lazy clears). The Trace `:guardrail` events carry the same pairs.
      counter("jido_claw.clarify.total", tags: [:event, :outcome]),

      # Cron metrics — tags resolve from the shared event metadata
      # Cron.Worker stamps on every tick (see emit_cron_* below).
      # `dispatch_target` is the *effective* path, so a :system_job whose
      # `target` defaults to :agent still tags `dispatch_target: :mfa`.
      counter("jido_claw.cron.job.start.total", tags: [:mode, :target, :dispatch_target]),
      counter("jido_claw.cron.job.stop.total", tags: [:mode, :target, :dispatch_target]),
      summary("jido_claw.cron.job.duration",
        unit: {:native, :millisecond},
        tags: [:mode, :target, :dispatch_target],
        event_name: [:jido_claw, :cron, :job, :stop]
      ),
      counter("jido_claw.cron.job.exception.total", tags: [:mode, :target, :dispatch_target]),

      # Workflow lease/reclaim lifecycle (WS6 Phase 4) — all five events emit
      # measurement `%{count: 1}`, so `measurement: :count` is explicit on each
      # (counter/2 would otherwise infer `:total` from the name's last segment
      # and the tiles would never fire). Node-local, like all telemetry — the
      # cluster proofs poll the DB instead. See docs/system/clustering.md.
      counter("jido_claw.orchestration.claimed.total", measurement: :count),
      counter("jido_claw.orchestration.renewed.total", measurement: :count),
      counter("jido_claw.orchestration.reclaimed.total", measurement: :count),
      counter("jido_claw.orchestration.fenced_out.total", measurement: :count, tags: [:reason]),
      counter("jido_claw.orchestration.recovered.total", measurement: :count, tags: [:branch]),

      # Memory consolidator metrics
      counter("jido_claw.memory.consolidator.run.total",
        tags: [:tenant_id, :scope_kind, :status, :harness]
      ),
      summary("jido_claw.memory.consolidator.run.duration_ms",
        tags: [:tenant_id, :scope_kind, :status]
      ),
      sum("jido_claw.memory.consolidator.run.facts_published",
        tags: [:tenant_id, :scope_kind]
      ),
      sum("jido_claw.memory.consolidator.run.blocks_written",
        tags: [:tenant_id, :scope_kind]
      ),
      counter("jido_claw.memory.consolidator.skipped.total",
        tags: [:tenant_id, :scope_kind, :reason]
      ),

      # Tenant metrics
      counter("jido_claw.tenant.create.total"),
      counter("jido_claw.tenant.destroy.total"),
      last_value("jido_claw.tenant.count",
        measurement: :count,
        event_name: [:jido_claw, :tenant, :count]
      ),

      # VM metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :emit_tenant_count, []}
    ]
  end

  # Periodic measurement: emit current tenant count
  @spec emit_tenant_count() :: :ok
  def emit_tenant_count do
    count =
      case Process.whereis(Manager) do
        nil -> 0
        _pid -> Manager.count()
      end

    :telemetry.execute([:jido_claw, :tenant, :count], %{count: count}, %{})
  end

  # -- Emit helpers --

  @spec emit_session_start(map()) :: :ok
  def emit_session_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :session, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @spec emit_session_stop(map(), number()) :: :ok
  def emit_session_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :session, :stop], %{duration: duration}, metadata)
  end

  @spec emit_session_message(map()) :: :ok
  def emit_session_message(metadata) do
    :telemetry.execute([:jido_claw, :session, :message], %{count: 1}, metadata)
  end

  @spec emit_provider_request_start(map()) :: :ok
  def emit_provider_request_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :provider, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @spec emit_provider_request_stop(map(), number()) :: :ok
  def emit_provider_request_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :provider, :request, :stop], %{duration: duration}, metadata)
  end

  @spec emit_provider_exception(map(), term()) :: :ok
  def emit_provider_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :provider, :request, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  @spec emit_provider_tokens(map(), number(), term()) :: :ok
  def emit_provider_tokens(metadata, count, type) do
    :telemetry.execute(
      [:jido_claw, :provider, :tokens],
      %{total: count},
      Map.put(metadata, :type, type)
    )
  end

  @spec emit_tool_start(map()) :: :ok
  def emit_tool_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :tool, :execute, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @spec emit_tool_stop(map(), number()) :: :ok
  def emit_tool_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :tool, :execute, :stop], %{duration: duration}, metadata)
  end

  @spec emit_tool_exception(map(), term()) :: :ok
  def emit_tool_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :tool, :execute, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  @spec emit_shaping(String.t(), atom(), non_neg_integer()) :: :ok
  def emit_shaping(tool, format, bytes_saved) do
    :telemetry.execute(
      [:jido_claw, :tool, :shaping],
      %{bytes_saved: bytes_saved, total: 1},
      %{tool: tool, format: format}
    )
  end

  @spec emit_loop_guard(String.t(), atom(), atom()) :: :ok
  def emit_loop_guard(tool, event, trigger) do
    :telemetry.execute(
      [:jido_claw, :loop_guard],
      %{total: 1},
      %{tool: tool, event: event, trigger: trigger}
    )
  end

  @spec emit_composer_infra(atom(), String.t()) :: :ok
  def emit_composer_infra(lane, stage) do
    :telemetry.execute(
      [:jido_claw, :composer, :infra],
      %{total: 1},
      %{lane: lane, stage: stage}
    )
  end

  @spec emit_composer_stall(atom(), String.t()) :: :ok
  def emit_composer_stall(kind, lens) do
    :telemetry.execute(
      [:jido_claw, :composer, :stall],
      %{total: 1},
      %{kind: kind, lens: lens}
    )
  end

  @spec emit_verify(atom()) :: :ok
  def emit_verify(result) do
    :telemetry.execute([:jido_claw, :verify], %{total: 1}, %{result: result})
  end

  @spec emit_executor(atom(), atom()) :: :ok
  def emit_executor(kind, outcome) do
    :telemetry.execute([:jido_claw, :executor], %{total: 1}, %{kind: kind, outcome: outcome})
  end

  @spec emit_needs_input(atom(), atom()) :: :ok
  def emit_needs_input(event, outcome) do
    :telemetry.execute(
      [:jido_claw, :needs_input],
      %{total: 1},
      %{event: event, outcome: outcome}
    )
  end

  @spec emit_clarify(atom(), atom()) :: :ok
  def emit_clarify(event, outcome) do
    :telemetry.execute(
      [:jido_claw, :clarify],
      %{total: 1},
      %{event: event, outcome: outcome}
    )
  end

  @spec emit_review_independence(atom()) :: :ok
  def emit_review_independence(outcome) do
    :telemetry.execute([:jido_claw, :review_independence], %{total: 1}, %{outcome: outcome})
  end

  @spec emit_lua_eval(atom(), atom(), map()) :: :ok
  def emit_lua_eval(status, trigger, metadata) do
    :telemetry.execute(
      [:jido_claw, :lua_eval],
      %{total: 1},
      Map.merge(metadata, %{status: status, trigger: trigger})
    )
  end

  # Cron emit helpers pass metadata through unchanged. Cron.Worker builds one
  # map per tick — `job_id`, `tenant_id`, `mode`, `target`, `dispatch_target` —
  # and reuses it for start/stop/exception, so the `tags:` on the cron metrics
  # above always resolve and exceptions carry `tenant_id` too.
  @spec emit_cron_start(map()) :: :ok
  def emit_cron_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :cron, :job, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @spec emit_cron_stop(map(), number()) :: :ok
  def emit_cron_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :cron, :job, :stop], %{duration: duration}, metadata)
  end

  @spec emit_cron_exception(map(), term()) :: :ok
  def emit_cron_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :cron, :job, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  @spec emit_tenant_create(map()) :: :ok
  def emit_tenant_create(metadata) do
    :telemetry.execute([:jido_claw, :tenant, :create], %{count: 1}, metadata)
  end

  @spec emit_tenant_destroy(map()) :: :ok
  def emit_tenant_destroy(metadata) do
    :telemetry.execute([:jido_claw, :tenant, :destroy], %{count: 1}, metadata)
  end
end
