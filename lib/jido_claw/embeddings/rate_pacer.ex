defmodule JidoClaw.Embeddings.RatePacer do
  @moduledoc """
  Per-node token-bucket rate pacer for Voyage requests, plus a
  cluster-global admit gate via the
  `JidoClaw.Embeddings.DispatchWindow` resource.

  Two tiers:

    * **Per-node bucket** (`acquire/2`) — blocks up to
      `:acquire_timeout_ms` (default 30_000) waiting for the local
      node's RPM/TPM bucket to refill. Refilled via
      `System.monotonic_time/1` so the clock can be controlled in
      tests; queued waiters are released on a periodic
      `:refill_tick` while the queue is non-empty.
    * **Cluster-global window** — `try_admit/2` runs a conditional
      UPSERT against `embedding_dispatch_window`; zero rows means
      cluster budget exhausted, the caller backs off.

  ## Single bucket today

  v0.6.1 uses a single Voyage-wide bucket: the `model` argument on
  `acquire/2` and `try_admit/2` is accepted for forward-compat with
  multi-provider growth but is **not** used to partition state. If a
  separate Local provider needs metering later, re-shape the state
  map to `%{voyage: bucket(), local: bucket()}` keyed on the
  argument.

  ## Effective window derivation

  The configured `:rpm` (and `:tpm`) define a per-minute ceiling, but
  the cluster-global SQL counts inside a window of
  `:cluster_window_seconds`. If `rpm * cluster_window_seconds / 60 <
  1` the budget rounds to zero and nothing ever admits. To keep the
  configured RPM expressible, we widen the effective window:

      effective_window = max(cluster_window_seconds, ceil(60 / rpm), ceil(60 / tpm))

  `:rpm: 1, :cluster_window_seconds: 10` upgrades to a 60-second
  window; `:rpm: 30, :cluster_window_seconds: 60` stays at 60. The
  upgrade is logged at info on first boot.

  When `VOYAGE_API_KEY` is set but `:rate_limits` is not configured,
  the GenServer logs a one-time warning at boot pointing at the docs
  URL and the config key.
  """

  use GenServer
  require Logger

  @default_rpm 300
  @default_tpm 1_000_000
  @default_cluster_window_seconds 1
  @default_acquire_timeout_ms 30_000
  @default_gc_after_seconds 60
  @default_refill_interval_ms 100

  defstruct [
    :rpm,
    :tpm,
    :cluster_window_seconds,
    :effective_window_seconds,
    :acquire_timeout_ms,
    :gc_after_seconds,
    :refill_interval_ms,
    :refill_tick_ref,
    requests_remaining: 0,
    tokens_remaining: 0,
    last_refill_monotonic_ms: 0,
    waiters: :queue.new()
  ]

  # ---------------------------------------------------------------------------
  # Client
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Block until the per-node bucket has at least 1 request and `tokens`
  tokens available, or until `:acquire_timeout_ms` expires. Returns
  `:ok` on admit, `{:error, :timeout}` on timeout.
  """
  @spec acquire(term(), non_neg_integer()) :: :ok | {:error, :timeout}
  def acquire(model, tokens \\ 1) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        # Use :infinity at the GenServer.call layer; the server
        # enforces the timeout itself by replying {:error, :timeout}.
        GenServer.call(__MODULE__, {:acquire, model, tokens}, :infinity)
    end
  end

  @doc """
  Conditional UPSERT against the dispatch_window table. Returns
  `:ok` on admit (counter incremented), `{:error, :budget_exhausted}`
  when the cluster-global per-window cap would be exceeded.
  """
  @spec try_admit(String.t(), non_neg_integer()) :: :ok | {:error, :budget_exhausted}
  def try_admit(model, tokens \\ 1) when is_binary(model) do
    config = Application.get_env(:jido_claw, __MODULE__, [])
    rpm = Keyword.get(config, :rpm, @default_rpm)
    tpm = Keyword.get(config, :tpm, @default_tpm)

    cluster_window_seconds =
      Keyword.get(config, :cluster_window_seconds, @default_cluster_window_seconds)

    {effective_window, _which} = derive_effective_window(rpm, tpm, cluster_window_seconds)

    request_cap = div(rpm * effective_window, 60)
    token_cap = div(tpm * effective_window, 60)

    sql = """
    INSERT INTO embedding_dispatch_window
      (model, window_started_at, request_count, token_count, inserted_at, updated_at)
    VALUES
      ($1,
       to_timestamp(floor(extract(epoch from now()) / $5) * $5),
       1, $2,
       now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
    ON CONFLICT (model, window_started_at) DO UPDATE
      SET request_count = embedding_dispatch_window.request_count + 1,
          token_count   = embedding_dispatch_window.token_count + EXCLUDED.token_count,
          updated_at    = now() AT TIME ZONE 'utc'
      WHERE embedding_dispatch_window.request_count + 1 <= $3
        AND embedding_dispatch_window.token_count + EXCLUDED.token_count <= $4
    RETURNING request_count, token_count
    """

    case JidoClaw.Repo.query(sql, [model, tokens, request_cap, token_cap, effective_window]) do
      {:ok, %Postgrex.Result{rows: [_ | _]}} -> :ok
      _ -> {:error, :budget_exhausted}
    end
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    config = Application.get_env(:jido_claw, __MODULE__, [])

    rpm = Keyword.get(config, :rpm, @default_rpm)
    tpm = Keyword.get(config, :tpm, @default_tpm)

    if not (is_integer(rpm) and rpm > 0) do
      Logger.error(
        "[Embeddings.RatePacer] :rpm must be a positive integer, got #{inspect(rpm)} — refusing to start"
      )

      {:stop, {:invalid_config, :rpm, rpm}}
    else
      if not (is_integer(tpm) and tpm > 0) do
        Logger.error(
          "[Embeddings.RatePacer] :tpm must be a positive integer, got #{inspect(tpm)} — refusing to start"
        )

        {:stop, {:invalid_config, :tpm, tpm}}
      else
        do_init(rpm, tpm, config)
      end
    end
  end

  defp do_init(rpm, tpm, config) do
    cluster_window_seconds =
      Keyword.get(config, :cluster_window_seconds, @default_cluster_window_seconds)

    {effective_window, forced_by} = derive_effective_window(rpm, tpm, cluster_window_seconds)

    if effective_window != cluster_window_seconds do
      Logger.info(
        "[Embeddings.RatePacer] cluster_window_seconds=#{cluster_window_seconds} too short for #{forced_by}=#{rpm_or_tpm(forced_by, rpm, tpm)}; widened effective window to #{effective_window}s"
      )
    end

    state = %__MODULE__{
      rpm: rpm,
      tpm: tpm,
      cluster_window_seconds: cluster_window_seconds,
      effective_window_seconds: effective_window,
      acquire_timeout_ms: Keyword.get(config, :acquire_timeout_ms, @default_acquire_timeout_ms),
      gc_after_seconds: Keyword.get(config, :gc_after_seconds, @default_gc_after_seconds),
      refill_interval_ms: Keyword.get(config, :refill_interval_ms, @default_refill_interval_ms),
      requests_remaining: rpm,
      tokens_remaining: tpm,
      last_refill_monotonic_ms: System.monotonic_time(:millisecond)
    }

    maybe_warn_unconfigured(config)
    :timer.send_interval(:timer.seconds(60), :gc_dispatch_window)
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, _model, tokens}, from, state) do
    state = refill(state)

    if state.requests_remaining >= 1 and state.tokens_remaining >= tokens do
      new_state = %{
        state
        | requests_remaining: state.requests_remaining - 1,
          tokens_remaining: state.tokens_remaining - tokens
      }

      {:reply, :ok, new_state}
    else
      timeout_ref = make_ref()

      timer_ref =
        Process.send_after(self(), {:acquire_timeout, timeout_ref}, state.acquire_timeout_ms)

      waiter = {from, tokens, timeout_ref, timer_ref}
      new_state = %{state | waiters: :queue.in(waiter, state.waiters)}
      {:noreply, ensure_refill_tick(new_state)}
    end
  end

  @impl true
  def handle_info(:refill_tick, state) do
    state = refill(state)
    state = drain_waiters(state)

    state =
      if :queue.is_empty(state.waiters) do
        cancel_refill_tick(state)
      else
        schedule_refill_tick(state)
      end

    {:noreply, state}
  end

  def handle_info({:acquire_timeout, timeout_ref}, state) do
    {removed?, waiters} = remove_waiter(state.waiters, timeout_ref)

    state = %{state | waiters: waiters}

    state =
      if removed? do
        if :queue.is_empty(state.waiters), do: cancel_refill_tick(state), else: state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:gc_dispatch_window, state) do
    cutoff = state.gc_after_seconds

    try do
      JidoClaw.Repo.query!(
        "DELETE FROM embedding_dispatch_window WHERE window_started_at < now() - ($1 || ' seconds')::interval",
        [Integer.to_string(cutoff)]
      )
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Bucket refill / waiter management
  # ---------------------------------------------------------------------------

  defp refill(state) do
    now_ms = System.monotonic_time(:millisecond)
    elapsed_ms = now_ms - state.last_refill_monotonic_ms

    if elapsed_ms <= 0 do
      state
    else
      add_requests = state.rpm * elapsed_ms / 60_000
      add_tokens = state.tpm * elapsed_ms / 60_000

      %{
        state
        | requests_remaining: min(state.rpm, state.requests_remaining + add_requests),
          tokens_remaining: min(state.tpm, state.tokens_remaining + add_tokens),
          last_refill_monotonic_ms: now_ms
      }
    end
  end

  defp drain_waiters(state) do
    case :queue.peek(state.waiters) do
      :empty ->
        state

      {:value, {from, tokens, timeout_ref, timer_ref}} ->
        if state.requests_remaining >= 1 and state.tokens_remaining >= tokens do
          {{:value, _}, rest} = :queue.out(state.waiters)
          _ = Process.cancel_timer(timer_ref)

          # Drain any stale {:acquire_timeout, timeout_ref} we may
          # have already enqueued for this waiter.
          receive do
            {:acquire_timeout, ^timeout_ref} -> :ok
          after
            0 -> :ok
          end

          GenServer.reply(from, :ok)

          drain_waiters(%{
            state
            | requests_remaining: state.requests_remaining - 1,
              tokens_remaining: state.tokens_remaining - tokens,
              waiters: rest
          })
        else
          state
        end
    end
  end

  defp remove_waiter(queue, timeout_ref) do
    list = :queue.to_list(queue)

    case Enum.split_with(list, fn {_from, _tokens, ref, _timer} -> ref == timeout_ref end) do
      {[], _} ->
        {false, queue}

      {[{from, _tokens, _ref, _timer} | _], rest} ->
        GenServer.reply(from, {:error, :timeout})
        {true, :queue.from_list(rest)}
    end
  end

  defp ensure_refill_tick(%{refill_tick_ref: nil} = state), do: schedule_refill_tick(state)
  defp ensure_refill_tick(state), do: state

  defp schedule_refill_tick(state) do
    if state.refill_tick_ref, do: Process.cancel_timer(state.refill_tick_ref)
    ref = Process.send_after(self(), :refill_tick, state.refill_interval_ms)
    %{state | refill_tick_ref: ref}
  end

  defp cancel_refill_tick(%{refill_tick_ref: nil} = state), do: state

  defp cancel_refill_tick(state) do
    Process.cancel_timer(state.refill_tick_ref)
    %{state | refill_tick_ref: nil}
  end

  # ---------------------------------------------------------------------------
  # Effective-window derivation
  # ---------------------------------------------------------------------------

  defp derive_effective_window(rpm, tpm, configured) do
    rpm_floor = ceil(60 / rpm)
    tpm_floor = ceil(60 / tpm)
    candidates = [{configured, :configured}, {rpm_floor, :rpm}, {tpm_floor, :tpm}]
    {window, source} = Enum.max_by(candidates, fn {n, _src} -> n end)

    if source == :configured do
      {window, :configured}
    else
      {window, source}
    end
  end

  defp rpm_or_tpm(:rpm, rpm, _tpm), do: rpm
  defp rpm_or_tpm(:tpm, _rpm, tpm), do: tpm
  defp rpm_or_tpm(_, _, _), do: :unknown

  # ---------------------------------------------------------------------------
  # Boot warning
  # ---------------------------------------------------------------------------

  defp maybe_warn_unconfigured(config) do
    api_key_present? = match?(s when is_binary(s) and s != "", System.get_env("VOYAGE_API_KEY"))
    rate_configured? = Keyword.has_key?(config, :rpm) or Keyword.has_key?(config, :tpm)

    if api_key_present? and not rate_configured? do
      Logger.warning(
        "[Embeddings.RatePacer] VOYAGE_API_KEY is set but :rate_limits are not configured. " <>
          "Defaults are conservative paid-Tier-1 levels. Override via " <>
          "config :jido_claw, JidoClaw.Embeddings.RatePacer, rpm: ..., tpm: ... — " <>
          "see https://docs.voyageai.com/docs/rate-limits for tier specs."
      )
    end
  end
end
