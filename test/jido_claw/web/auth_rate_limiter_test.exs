defmodule JidoClaw.Web.AuthRateLimiterTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Web.AuthRateLimiter

  setup do
    previous = Application.fetch_env(:jido_claw, :auth_rate_limit)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_claw, :auth_rate_limit, value)
        :error -> Application.delete_env(:jido_claw, :auth_rate_limit)
      end

      :ok = AuthRateLimiter.reset_all()
    end)

    :ok
  end

  test "credential reset preserves the broad IP bucket and admits the credential again" do
    configure(
      window_ms: 60_000,
      max_attempts: 2,
      ip_max_attempts: 10,
      max_buckets: 20,
      max_timestamps_per_bucket: 10,
      sweep_interval_ms: 60_000
    )

    assert :ok = AuthRateLimiter.check("192.0.2.1", "User@Example.com")
    assert :ok = AuthRateLimiter.check("192.0.2.1", "user@example.com")

    assert {:error, {:rate_limited, _retry_after}} =
             AuthRateLimiter.check("192.0.2.1", "user@example.com")

    assert :ok = AuthRateLimiter.reset("192.0.2.1", "USER@example.com")
    assert :ok = AuthRateLimiter.check("192.0.2.1", "user@example.com")

    state = :sys.get_state(AuthRateLimiter)
    assert Map.has_key?(state.buckets, {:ip, "192.0.2.1"})
    assert Map.has_key?(state.buckets, {:credential, "192.0.2.1", "user@example.com"})
  end

  test "scheduled sweeping removes expired buckets and the next window admits again" do
    configure(
      window_ms: 30,
      max_attempts: 2,
      ip_max_attempts: 10,
      max_buckets: 20,
      max_timestamps_per_bucket: 10,
      sweep_interval_ms: 5
    )

    assert :ok = AuthRateLimiter.check("192.0.2.2", "window@example.com")
    assert map_size(:sys.get_state(AuthRateLimiter).buckets) == 2

    assert eventually(fn -> :sys.get_state(AuthRateLimiter).buckets == %{} end)
    assert :ok = AuthRateLimiter.check("192.0.2.2", "window@example.com")
  end

  test "hard capacity fails closed and never grows under new-key churn" do
    configure(
      window_ms: 60_000,
      max_attempts: 10,
      ip_max_attempts: 10,
      max_buckets: 4,
      max_timestamps_per_bucket: 10,
      sweep_interval_ms: 60_000
    )

    assert :ok = AuthRateLimiter.check("192.0.2.10", "one@example.com")
    assert :ok = AuthRateLimiter.check("192.0.2.11", "two@example.com")
    assert map_size(:sys.get_state(AuthRateLimiter).buckets) == 4

    for index <- 1..100 do
      assert {:error, :unavailable} =
               AuthRateLimiter.check("198.51.100.#{index}", "churn-#{index}@example.com")
    end

    assert map_size(:sys.get_state(AuthRateLimiter).buckets) == 4
  end

  test "per-key timestamp storage is capped and the effective limit fails closed" do
    configure(
      window_ms: 60_000,
      max_attempts: 10,
      ip_max_attempts: 10,
      max_buckets: 20,
      max_timestamps_per_bucket: 3,
      sweep_interval_ms: 60_000
    )

    for _ <- 1..3 do
      assert :ok = AuthRateLimiter.check("192.0.2.12", "cap@example.com")
    end

    assert {:error, {:rate_limited, _retry_after}} =
             AuthRateLimiter.check("192.0.2.12", "cap@example.com")

    state = :sys.get_state(AuthRateLimiter)

    assert Enum.all?(state.buckets, fn {_key, timestamps} ->
             Enum.count_until(timestamps, 4) <= 3
           end)
  end

  defp configure(opts) do
    Application.put_env(:jido_claw, :auth_rate_limit, opts)
    :ok = AuthRateLimiter.reset_all()
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          5 -> eventually(fun, attempts - 1)
        end
    end
  end
end
