defmodule JidoClaw.Cron.NextRunTest do
  @moduledoc """
  Pins `JidoClaw.Cron.NextRun.compute_next_cron_utc/3`:

    * `"Etc/UTC"` is byte-identical to the legacy
      `DateTime.from_naive!(get_next_run_date(cron), "Etc/UTC")` path.
    * Cron fields are read as wall-clock in the given zone (EDT vs EST).
    * DST gaps (spring-forward) resolve to the instant after the gap;
      DST overlaps (fall-back) resolve to the first occurrence.
    * Unknown zone / invalid expression / `@reboot` map to tagged errors
      and never raise.

  Pure + deterministic: `now_utc` is pinned, so no DB. The tz database is
  provided by the started `:time_zone_info` app (wired in `config/config.exs`).
  """
  use ExUnit.Case, async: true

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler
  alias JidoClaw.Cron.NextRun

  @now ~U[2026-06-04 12:00:00Z]

  describe "Etc/UTC is byte-identical to the legacy path" do
    test ~S|matches DateTime.from_naive!(get_next_run_date(cron), "Etc/UTC")| do
      for expr <- ["0 9 * * *", "*/30 * * * *", "15 3 * * 1", "0 0 1 * *"] do
        {:ok, legacy_naive} =
          Scheduler.get_next_run_date(
            Parser.parse!(expr),
            DateTime.to_naive(@now)
          )

        legacy = DateTime.from_naive!(legacy_naive, "Etc/UTC")

        assert {:ok, computed} = NextRun.compute_next_cron_utc(expr, "Etc/UTC", @now)
        assert computed == legacy, "#{expr}: #{inspect(computed)} != #{inspect(legacy)}"
      end
    end
  end

  describe "wall-clock interpretation in a zone" do
    test "America/New_York 9am is 13:00Z in summer (EDT)" do
      assert {:ok, ~U[2026-06-04 13:00:00Z]} =
               NextRun.compute_next_cron_utc("0 9 * * *", "America/New_York", @now)
    end

    test "America/New_York 9am is 14:00Z in winter (EST)" do
      assert {:ok, ~U[2026-01-15 14:00:00Z]} =
               NextRun.compute_next_cron_utc(
                 "0 9 * * *",
                 "America/New_York",
                 ~U[2026-01-15 12:00:00Z]
               )
    end

    test "Australia/Sydney 9am resolves to a real UTC instant (UTC+10/+11)" do
      assert {:ok, %DateTime{time_zone: "Etc/UTC"} = dt} =
               NextRun.compute_next_cron_utc("0 9 * * *", "Australia/Sydney", @now)

      # 9am Sydney is 22:00Z (AEST, +10) or 23:00Z (AEDT, +11) the prior day.
      assert dt.hour in [22, 23]
      assert dt.minute == 0
    end
  end

  describe "DST resolution" do
    test "spring-forward gap resolves to the instant after the gap" do
      # 2025-03-09 02:00 America/New_York does not exist (clock jumps 2->3am);
      # the instant just after the gap is 03:00 EDT = 07:00Z.
      assert {:ok, ~U[2025-03-09 07:00:00Z]} =
               NextRun.compute_next_cron_utc(
                 "0 2 * * *",
                 "America/New_York",
                 ~U[2025-03-09 00:00:00Z]
               )
    end

    test "fall-back overlap resolves to the first occurrence" do
      # 2025-11-02 01:00 America/New_York occurs twice; first is 01:00 EDT = 05:00Z.
      assert {:ok, ~U[2025-11-02 05:00:00Z]} =
               NextRun.compute_next_cron_utc(
                 "0 1 * * *",
                 "America/New_York",
                 ~U[2025-11-02 00:00:00Z]
               )
    end
  end

  describe "error mapping (never raises)" do
    test "unknown timezone -> :unknown_timezone" do
      assert {:error, :unknown_timezone} =
               NextRun.compute_next_cron_utc("0 9 * * *", "Nowhere/Nope", @now)
    end

    test "invalid expression -> :invalid_expression" do
      assert {:error, :invalid_expression} =
               NextRun.compute_next_cron_utc("not a cron", "Etc/UTC", @now)
    end

    test "@reboot parses but the scheduler raises -> :calc_error" do
      assert {:error, :calc_error} = NextRun.compute_next_cron_utc("@reboot", "Etc/UTC", @now)
    end
  end
end
