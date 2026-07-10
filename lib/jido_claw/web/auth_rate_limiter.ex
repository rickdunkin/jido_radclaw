defmodule JidoClaw.Web.AuthRateLimiter do
  @moduledoc """
  Per-node sliding-window limiter for password sign-in attempts.

  The limiter checks both an IP-wide bucket and an IP/email bucket before
  bcrypt runs. It intentionally returns the same decision for existing and
  missing accounts; email is used only as an opaque normalized bucket key.

  Request checks touch only those two buckets. Each bucket retains a bounded
  number of timestamps, and a scheduled sweep removes expired buckets away
  from the request path. The bucket map has a hard configured capacity; a new
  identity that cannot be represented without crossing that capacity fails
  closed with `:unavailable` instead of growing memory without bound.
  """

  use GenServer

  alias JidoClaw.Core.ConfigValue

  @default_window_ms 60_000
  @default_max_attempts 5
  @default_ip_max_attempts 100
  @default_max_buckets 10_000
  @default_max_timestamps_per_bucket 100
  @default_sweep_interval_ms 60_000

  @config_defaults [
    window_ms: @default_window_ms,
    max_attempts: @default_max_attempts,
    ip_max_attempts: @default_ip_max_attempts,
    max_buckets: @default_max_buckets,
    max_timestamps_per_bucket: @default_max_timestamps_per_bucket,
    sweep_interval_ms: @default_sweep_interval_ms
  ]

  @type decision :: :ok | {:error, {:rate_limited, pos_integer()} | :unavailable}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec check(String.t(), String.t()) :: decision()
  def check(ip, email) when is_binary(ip) and is_binary(email) do
    GenServer.call(__MODULE__, {:check, ip, normalize_email(email)})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec reset(String.t(), String.t()) :: :ok
  def reset(ip, email) when is_binary(ip) and is_binary(email) do
    GenServer.call(__MODULE__, {:reset, ip, normalize_email(email)})
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec reset_all() :: :ok
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(_opts) do
    {sweep_ref, sweep_token} = arm_sweep(config().sweep_interval_ms)

    {:ok,
     %{
       buckets: %{},
       saturated_until: nil,
       sweep_ref: sweep_ref,
       sweep_token: sweep_token
     }}
  end

  @impl GenServer
  def handle_call({:check, ip, email}, _from, state) do
    now = System.monotonic_time(:millisecond)
    config = config()
    cutoff = now - config.window_ms
    ip_key = {:ip, ip}
    credential_key = {:credential, ip, email}
    ip_limit = effective_limit(config.ip_max_attempts, config.max_timestamps_per_bucket)

    credential_limit =
      effective_limit(config.max_attempts, config.max_timestamps_per_bucket)

    state = maybe_leave_saturation(state, now)

    cond do
      saturated?(state, now) ->
        {:reply, {:error, :unavailable}, state}

      map_size(state.buckets) > config.max_buckets ->
        # A runtime capacity reduction cannot leave an oversized map resident.
        # Drop the bounded state and refuse all admission for one full window,
        # so forgetting those timestamps never turns into an auth bypass.
        {:reply, {:error, :unavailable}, saturate(state, now + config.window_ms)}

      true ->
        check_buckets(
          state,
          ip_key,
          credential_key,
          now,
          cutoff,
          ip_limit,
          credential_limit,
          config
        )
    end
  end

  def handle_call({:reset, ip, email}, _from, state) do
    buckets = Map.delete(state.buckets, {:credential, ip, email})
    {:reply, :ok, %{state | buckets: buckets}}
  end

  def handle_call(:reset_all, _from, state) do
    cancel_sweep(state.sweep_ref)
    {sweep_ref, sweep_token} = arm_sweep(config().sweep_interval_ms)

    {:reply, :ok,
     %{
       state
       | buckets: %{},
         saturated_until: nil,
         sweep_ref: sweep_ref,
         sweep_token: sweep_token
     }}
  end

  @impl GenServer
  def handle_info({:sweep, token}, %{sweep_token: token} = state) do
    now = System.monotonic_time(:millisecond)
    config = config()
    state = sweep(state, now, config)
    {sweep_ref, sweep_token} = arm_sweep(config.sweep_interval_ms)

    {:noreply, %{state | sweep_ref: sweep_ref, sweep_token: sweep_token}}
  end

  # A reset may cancel a timer after its message has already entered the
  # mailbox. Correlation keeps that stale delivery from arming a second loop.
  def handle_info({:sweep, _stale_token}, state), do: {:noreply, state}

  defp check_buckets(
         state,
         ip_key,
         credential_key,
         now,
         cutoff,
         ip_limit,
         credential_limit,
         config
       ) do
    {buckets_after_ip, ip_attempts} =
      refresh_bucket(state.buckets, ip_key, cutoff, ip_limit)

    {buckets, credential_attempts} =
      refresh_bucket(buckets_after_ip, credential_key, cutoff, credential_limit)

    state = %{state | buckets: buckets}

    cond do
      capacity_exceeded?(buckets, [ip_key, credential_key], config.max_buckets) ->
        {:reply, {:error, :unavailable}, state}

      length(ip_attempts) >= ip_limit ->
        {:reply, limited(ip_attempts, now, config.window_ms), state}

      length(credential_attempts) >= credential_limit ->
        {:reply, limited(credential_attempts, now, config.window_ms), state}

      true ->
        updated =
          buckets
          |> Map.put(ip_key, record(now, ip_attempts, ip_limit))
          |> Map.put(credential_key, record(now, credential_attempts, credential_limit))

        {:reply, :ok, %{state | buckets: updated}}
    end
  end

  defp refresh_bucket(buckets, key, cutoff, limit) do
    attempts = recent(Map.get(buckets, key, []), cutoff, limit)

    if attempts == [] do
      {Map.delete(buckets, key), attempts}
    else
      {Map.put(buckets, key, attempts), attempts}
    end
  end

  defp capacity_exceeded?(buckets, keys, max_buckets) do
    missing = Enum.count(keys, &(not Map.has_key?(buckets, &1)))
    map_size(buckets) + missing > max_buckets
  end

  defp record(now, attempts, limit), do: Enum.take([now | attempts], limit)

  # Timestamps are newest-first. Take before filtering so even a runtime config
  # reduction never makes one request traverse an older, larger bucket.
  defp recent(attempts, cutoff, limit) do
    attempts
    |> Enum.take(limit)
    |> Enum.filter(&(&1 > cutoff))
  end

  defp sweep(state, now, config) do
    state = maybe_leave_saturation(state, now)

    if saturated?(state, now) do
      state
    else
      cutoff = now - config.window_ms

      buckets =
        Enum.reduce(state.buckets, %{}, fn {key, attempts}, acc ->
          attempts = recent(attempts, cutoff, bucket_limit(key, config))
          if attempts == [], do: acc, else: Map.put(acc, key, attempts)
        end)

      if map_size(buckets) > config.max_buckets do
        saturate(state, now + config.window_ms)
      else
        %{state | buckets: buckets}
      end
    end
  end

  defp bucket_limit({:ip, _ip}, config),
    do: effective_limit(config.ip_max_attempts, config.max_timestamps_per_bucket)

  defp bucket_limit({:credential, _ip, _email}, config),
    do: effective_limit(config.max_attempts, config.max_timestamps_per_bucket)

  defp effective_limit(attempt_limit, timestamp_limit), do: min(attempt_limit, timestamp_limit)

  defp saturated?(%{saturated_until: until}, now) when is_integer(until), do: now < until
  defp saturated?(_state, _now), do: false

  defp maybe_leave_saturation(%{saturated_until: until} = state, now)
       when is_integer(until) and now >= until,
       do: %{state | saturated_until: nil}

  defp maybe_leave_saturation(state, _now), do: state

  defp saturate(state, until), do: %{state | buckets: %{}, saturated_until: until}

  defp arm_sweep(interval_ms) do
    token = make_ref()
    {Process.send_after(self(), {:sweep, token}, interval_ms), token}
  end

  defp cancel_sweep(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp limited(attempts, now, window_ms) do
    oldest = Enum.min(attempts)
    retry_after = max(div(window_ms - (now - oldest), 1_000), 1)
    {:error, {:rate_limited, retry_after}}
  end

  defp config do
    configured = Application.get_env(:jido_claw, :auth_rate_limit, [])

    Map.new(@config_defaults, fn {key, default} ->
      value = Keyword.get(configured, key, default)
      {key, ConfigValue.positive_integer(value, default)}
    end)
  end

  defp normalize_email(email), do: String.downcase(String.trim(email))
end
