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
      summary("jido_claw.session.duration", unit: {:native, :millisecond}),
      counter("jido_claw.session.message.total", tags: [:role]),

      # Provider/LLM metrics
      counter("jido_claw.provider.request.start.total"),
      counter("jido_claw.provider.request.stop.total"),
      summary("jido_claw.provider.request.duration", unit: {:native, :millisecond}),
      counter("jido_claw.provider.request.exception.total"),
      sum("jido_claw.provider.tokens.total", tags: [:type]),

      # Tool execution metrics
      counter("jido_claw.tool.execute.start.total"),
      counter("jido_claw.tool.execute.stop.total"),
      summary("jido_claw.tool.execute.duration", unit: {:native, :millisecond}),
      counter("jido_claw.tool.execute.exception.total"),

      # Output shaping metrics — both derive from the single
      # [:jido_claw, :tool, :shaping] event (the metric name's last
      # segment selects the measurement), so one execute serves both.
      counter("jido_claw.tool.shaping.total", tags: [:tool, :format]),
      sum("jido_claw.tool.shaping.bytes_saved", tags: [:tool]),

      # Cron metrics — tags resolve from the shared event metadata
      # Cron.Worker stamps on every tick (see emit_cron_* below).
      # `dispatch_target` is the *effective* path, so a :system_job whose
      # `target` defaults to :agent still tags `dispatch_target: :mfa`.
      counter("jido_claw.cron.job.start.total", tags: [:mode, :target, :dispatch_target]),
      counter("jido_claw.cron.job.stop.total", tags: [:mode, :target, :dispatch_target]),
      summary("jido_claw.cron.job.duration",
        unit: {:native, :millisecond},
        tags: [:mode, :target, :dispatch_target]
      ),
      counter("jido_claw.cron.job.exception.total", tags: [:mode, :target, :dispatch_target]),

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
      last_value("jido_claw.tenant.count", measurement: :count),

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
