defmodule JidoClaw.Cron.NextRun do
  @moduledoc """
  Pure computation of a cron expression's next fire time as a UTC `DateTime`,
  interpreting the schedule in a wall-clock timezone.

  This is the single timezone-aware seam for `JidoClaw.Cron.Worker`. The legacy
  worker hardcoded `DateTime.from_naive!(naive, "Etc/UTC")`, so `"0 9 * * *"`
  fired at 09:00 **UTC** regardless of the operator's zone.
  `compute_next_cron_utc/3` instead reads the crontab fields as local wall-clock
  time in `tz`, then converts the resulting instant back to UTC for
  `Process.send_after/3` math.

  ## Hard crontab boundary

  `Crontab` is a partial function at this layer: `Parser.parse/1` accepts
  `@reboot` (returns `{:ok, %CronExpression{reboot: true}}`), but
  `Scheduler.get_next_run_date/2` then *raises* on it. Both crontab calls are
  wrapped in `try/rescue/catch` so a raise never escapes — it is mapped to a
  tagged error (`:invalid_expression` / `:calc_error`). Every failure mode the
  worker can hit here is a deterministic, permanent config error, so the worker
  disables the job rather than retrying.

  ## `"Etc/UTC"` is byte-identical to the legacy path

  Elixir's `DateTime.from_naive/2` and `DateTime.shift_zone/2` special-case
  `"Etc/UTC"` and build the UTC datetime directly without consulting the
  configured time zone database. So a default-tz job computes exactly
  `DateTime.from_naive!(next_naive, "Etc/UTC")` — identical to before this
  module existed — and needs no timezone data loaded.

  ## DST resolution

  When the local wall-clock instant is ambiguous (a fall-back overlap, where
  the clock is set back and the wall time occurs twice) or does not exist (a
  spring-forward gap, where the clock jumps and the wall time is skipped),
  `resolve_local_to_utc/2` picks the conventional cron semantics: the *first*
  occurrence for an ambiguous time, and the instant *just after* the gap for a
  skipped time.
  """

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @type error :: :invalid_expression | :unknown_timezone | :calc_error

  @doc """
  Compute the next UTC `DateTime` at which `expression` fires, reading the
  schedule as wall-clock time in `tz`.

  `now_utc` is the reference instant (defaults to now); it is shifted into `tz`
  before the crontab walk so "next 9am" means 9am *local*.
  """
  @spec compute_next_cron_utc(String.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, error()}
  def compute_next_cron_utc(expression, tz, now_utc \\ DateTime.utc_now()) do
    with {:ok, local_now} <- to_local(now_utc, tz),
         {:ok, cron} <- parse(expression),
         {:ok, next_naive} <- next_naive(cron, DateTime.to_naive(local_now)) do
      resolve_local_to_utc(next_naive, tz)
    end
  end

  # now_utc -> wall-clock in tz. An unknown zone is a permanent config error.
  @spec to_local(DateTime.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :unknown_timezone}
  defp to_local(now_utc, tz) do
    case DateTime.shift_zone(now_utc, tz) do
      {:ok, local} -> {:ok, local}
      {:error, _} -> {:error, :unknown_timezone}
    end
  end

  # Parse never raises out of here: @reboot etc. parse fine, but a malformed
  # field raises inside Parser — both collapse to :invalid_expression.
  @spec parse(String.t()) :: {:ok, CronExpression.t()} | {:error, :invalid_expression}
  defp parse(expression) do
    case Parser.parse(expression) do
      {:ok, cron} -> {:ok, cron}
      _ -> {:error, :invalid_expression}
    end
  rescue
    _ -> {:error, :invalid_expression}
  catch
    _, _ -> {:error, :invalid_expression}
  end

  # get_next_run_date raises on @reboot and can error on an unsatisfiable
  # expression; both collapse to :calc_error.
  @spec next_naive(CronExpression.t(), NaiveDateTime.t()) ::
          {:ok, NaiveDateTime.t()} | {:error, :calc_error}
  defp next_naive(cron, ref_naive) do
    case Scheduler.get_next_run_date(cron, ref_naive) do
      {:ok, naive} -> {:ok, naive}
      _ -> {:error, :calc_error}
    end
  rescue
    _ -> {:error, :calc_error}
  catch
    _, _ -> {:error, :calc_error}
  end

  # Interpret the crontab-produced naive as wall-clock in tz, then shift to UTC.
  # "Etc/UTC" shifts are infallible (handled by Elixir's UTC short-circuit).
  @spec resolve_local_to_utc(NaiveDateTime.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :calc_error}
  defp resolve_local_to_utc(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      {:ambiguous, first, _second} -> {:ok, DateTime.shift_zone!(first, "Etc/UTC")}
      {:gap, _just_before, just_after} -> {:ok, DateTime.shift_zone!(just_after, "Etc/UTC")}
      {:error, _} -> {:error, :calc_error}
    end
  end
end
