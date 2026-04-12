defmodule JidoClaw.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

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

      # Cron metrics
      counter("jido_claw.cron.job.start.total"),
      counter("jido_claw.cron.job.stop.total"),
      summary("jido_claw.cron.job.duration", unit: {:native, :millisecond}),
      counter("jido_claw.cron.job.exception.total"),

      # Tenant metrics
      counter("jido_claw.tenant.create.total"),
      counter("jido_claw.tenant.destroy.total"),
      last_value("jido_claw.tenant.count", measurement: :count),

      # Channel metrics
      counter("jido_claw.channel.message.inbound.total", tags: [:adapter]),
      counter("jido_claw.channel.message.outbound.total", tags: [:adapter]),

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
  def emit_tenant_count do
    count =
      case Process.whereis(JidoClaw.Tenant.Manager) do
        nil -> 0
        _pid -> JidoClaw.Tenant.Manager.count()
      end

    :telemetry.execute([:jido_claw, :tenant, :count], %{count: count}, %{})
  end

  # -- Emit helpers --

  def emit_session_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :session, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  def emit_session_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :session, :stop], %{duration: duration}, metadata)
  end

  def emit_session_message(metadata) do
    :telemetry.execute([:jido_claw, :session, :message], %{count: 1}, metadata)
  end

  def emit_provider_request_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :provider, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  def emit_provider_request_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :provider, :request, :stop], %{duration: duration}, metadata)
  end

  def emit_provider_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :provider, :request, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  def emit_provider_tokens(metadata, count, type) do
    :telemetry.execute(
      [:jido_claw, :provider, :tokens],
      %{total: count},
      Map.put(metadata, :type, type)
    )
  end

  def emit_tool_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :tool, :execute, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  def emit_tool_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :tool, :execute, :stop], %{duration: duration}, metadata)
  end

  def emit_tool_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :tool, :execute, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  def emit_cron_start(metadata) do
    :telemetry.execute(
      [:jido_claw, :cron, :job, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  def emit_cron_stop(metadata, duration) do
    :telemetry.execute([:jido_claw, :cron, :job, :stop], %{duration: duration}, metadata)
  end

  def emit_cron_exception(metadata, kind) do
    :telemetry.execute(
      [:jido_claw, :cron, :job, :exception],
      %{count: 1},
      Map.put(metadata, :kind, kind)
    )
  end

  def emit_tenant_create(metadata) do
    :telemetry.execute([:jido_claw, :tenant, :create], %{count: 1}, metadata)
  end

  def emit_tenant_destroy(metadata) do
    :telemetry.execute([:jido_claw, :tenant, :destroy], %{count: 1}, metadata)
  end

  def emit_channel_inbound(metadata) do
    :telemetry.execute([:jido_claw, :channel, :message, :inbound], %{count: 1}, metadata)
  end

  def emit_channel_outbound(metadata) do
    :telemetry.execute([:jido_claw, :channel, :message, :outbound], %{count: 1}, metadata)
  end
end
