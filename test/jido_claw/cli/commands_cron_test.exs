defmodule JidoClaw.CLI.CommandsCronTest do
  @moduledoc """
  CLI `/cron` surface:

    * `/cron add` validates the cron expression *before* scheduling — a
      malformed expression neither starts a worker nor persists a row (the
      §5 race fix; before it, an invalid cron started a worker whose
      `persist_disabled/1` no-op'd, then persisted an active bad row).
    * `/cron` renders a non-UTC job's timezone and omits UTC's.

  Uses the hardcoded `"default"` tenant the CLI targets; schedules that never
  fire during the test (1-day intervals, or a cron pinned ~2 days out) keep
  scheduled workers from ticking, and on_exit unschedules them.
  """
  use JidoClaw.TenantCase, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.Commands
  alias JidoClaw.Cron.Job, as: CronJob
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  @tenant "default"

  defp base_state do
    %{
      session_id: "commands-cron-test-#{System.unique_integer([:positive])}",
      profile: "default",
      strategy: "auto",
      cwd: File.cwd!(),
      config: %{},
      model: "test:model"
    }
  end

  defp worker_registered?(job_id) do
    not is_nil(
      GenServer.whereis({:via, Registry, {JidoClaw.TenantRegistry, {:cron, @tenant, job_id}}})
    )
  end

  setup do
    {:ok, _} = Manager.ensure_tenant(@tenant)
    :ok
  end

  describe "/cron add validate-before-schedule" do
    test "a malformed cron expression neither schedules a worker nor persists a row" do
      id = "bad-cron-#{System.unique_integer([:positive])}"

      output =
        capture_io(fn ->
          {:ok, _state} =
            Commands.handle(~s|/cron add #{id} "totally invalid" do something|, base_state())
        end)

      assert output =~ "Failed to schedule"
      refute worker_registered?(id)

      assert {:error, _} =
               CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant))
    end

    test "an @reboot expression neither schedules a worker nor persists a row" do
      # Parser.parse/1 accepts @reboot, but the scheduler raises on it; routing
      # validation through NextRun catches that as :calc_error before scheduling.
      id = "reboot-cron-#{System.unique_integer([:positive])}"

      output =
        capture_io(fn ->
          {:ok, _state} =
            Commands.handle(~s|/cron add #{id} "@reboot" do a thing|, base_state())
        end)

      assert output =~ "Failed to schedule"
      refute worker_registered?(id)

      assert {:error, _} =
               CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant))
    end

    test "a valid cron expression schedules and persists" do
      id = "good-cron-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = Scheduler.unschedule(@tenant, id)

        case CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant)) do
          {:ok, row} -> _ = CronJob.remove(row, tenant: @tenant, actor: Actor.system(@tenant))
          _ -> :ok
        end
      end)

      # A cron pinned ~2 days out: its next fire is always ~2 days away no matter
      # when the test runs (eliminates the daily-cron auto-tick race), yet well
      # under Process.send_after's ~49-day ceiling. `future` is a real calendar
      # date, so the pinned day/month is always a satisfiable cron.
      future = DateTime.add(DateTime.utc_now(), 2, :day)
      cron = "#{future.minute} #{future.hour} #{future.day} #{future.month} *"

      output =
        capture_io(fn ->
          {:ok, _state} =
            Commands.handle(~s|/cron add #{id} "#{cron}" run the thing|, base_state())
        end)

      assert output =~ "Scheduled"
      # WS4a: /cron add persists the row (the source of truth) and hands off to
      # the leader's Cron.Owner; with the Owner disabled in test no local worker
      # starts, so we assert the persisted row, not a worker.
      assert {:ok, row} = CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant))
      assert row.schedule_kind == :cron
      # CLI add omits timezone -> resource default applies.
      assert row.timezone == "Etc/UTC"
    end

    test "re-adding an agent-created job id drops the stored outcome contract" do
      id = "readd-cron-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = Scheduler.unschedule(@tenant, id)

        case CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant)) do
          {:ok, row} -> _ = CronJob.remove(row, tenant: @tenant, actor: Actor.system(@tenant))
          _ -> :ok
        end
      end)

      # Seed the row the way the schedule_task tool writes it: an agent-created
      # job carries its outcome contract under metadata["outcome_spec"] (item 9,
      # OH1-3), which the scheduler hydrates and the dispatcher appends at fire
      # time.
      {:ok, _} =
        CronJob.upsert(
          %{
            job_id: id,
            task: "agent task",
            mode: :main,
            schedule_kind: :every,
            schedule_value: "86400000",
            metadata: %{
              "outcome_spec" => %{
                "end_state" => "the digest email is sent",
                "check" => "the send API returned 200",
                "stop_bound" => "stop after 2 failed attempts"
              }
            }
          },
          tenant: @tenant,
          actor: Actor.system(@tenant)
        )

      future = DateTime.add(DateTime.utc_now(), 2, :day)
      cron = "#{future.minute} #{future.hour} #{future.day} #{future.month} *"

      output =
        capture_io(fn ->
          {:ok, _state} =
            Commands.handle(~s|/cron add #{id} "#{cron}" new task|, base_state())
        end)

      assert output =~ "Scheduled"

      # The documented item-9 exemption: operator CLI jobs carry no outcome
      # contract. Re-adding an agent-created job id must drop the stored
      # contract — otherwise the scheduler keeps hydrating it and the
      # dispatcher appends stale success criteria at fire time. Deliberately
      # contract-specific (not `metadata == %{}`): the pin is "CLI jobs carry
      # no contract", not "CLI clears all metadata".
      assert {:ok, row} = CronJob.by_job_id(id, tenant: @tenant, actor: Actor.system(@tenant))
      assert row.task == "new task"
      refute Map.has_key?(row.metadata || %{}, "outcome_spec")
    end
  end

  describe "/cron timezone display" do
    test "renders a non-UTC job's tz and omits UTC's (from persisted rows)" do
      ny = "cli-ny-#{System.unique_integer([:positive])}"
      utc = "cli-utc-#{System.unique_integer([:positive])}"
      actor = Actor.system(@tenant)

      # WS4a: /cron reads persisted rows, not local workers.
      {:ok, _} =
        CronJob.upsert(
          %{
            job_id: ny,
            task: "t",
            mode: :main,
            schedule_kind: :every,
            schedule_value: "86400000",
            timezone: "America/New_York"
          },
          tenant: @tenant,
          actor: actor
        )

      {:ok, _} =
        CronJob.upsert(
          %{
            job_id: utc,
            task: "t",
            mode: :main,
            schedule_kind: :every,
            schedule_value: "86400000"
          },
          tenant: @tenant,
          actor: actor
        )

      output =
        capture_io(fn ->
          {:ok, _state} = Commands.handle("/cron", base_state())
        end)

      assert output =~ ny
      assert output =~ utc
      assert output =~ "tz: America/New_York"
      # A UTC job never prints its zone.
      refute output =~ "Etc/UTC"
    end
  end
end
