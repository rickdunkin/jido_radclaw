defmodule JidoClaw.Cron.MfaReloadTest do
  @moduledoc """
  Regression for the fixed `target: :mfa` reload bug.

  A persisted `target: :mfa, mode: :main` row must rehydrate its MFA on
  `Scheduler.load_persistent_jobs/2` and dispatch through it on trigger.
  Before the fix, `build_mfa/1`'s `mode != :system_job` guard returned
  `{:ok, nil}` for such a row, so the worker booted with `mfa: nil` and
  every tick raised a rescued MatchError instead of running the MFA.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron
  alias JidoClaw.Cron.Job
  alias JidoClaw.Cron.Scheduler
  alias JidoClaw.Tenant.Manager

  test "target: :mfa with mode: :main reloads its MFA and dispatches through it" do
    tenant = seed_tenant("mfa_target_reload")
    {:ok, _} = Manager.ensure_tenant(tenant)

    {:ok, _job} =
      Job.upsert(
        %{
          job_id: "mfa-target-test",
          schedule_kind: :every,
          schedule_value: "60000",
          mode: :main,
          target: :mfa,
          mfa_module: "JidoClaw.Cron.TestSupport",
          mfa_function: "always_fail",
          mfa_args: %{}
        },
        tenant: tenant,
        actor: actor_for(tenant)
      )

    # The reload path is the ONLY way the worker gets its MFA here.
    assert {:ok, 1} = Scheduler.load_persistent_jobs(tenant, ".")
    on_exit(fn -> _ = Scheduler.unschedule(tenant, "mfa-target-test") end)

    state = Cron.Worker.get_state(tenant, "mfa-target-test")
    assert state.target == :mfa
    assert state.mfa == {JidoClaw.Cron.TestSupport, :always_fail, []}

    Cron.Worker.trigger(tenant, "mfa-target-test")

    eventually(fn ->
      st = Cron.Worker.get_state(tenant, "mfa-target-test")
      st.last_result == {:error, :forced}
    end)
  end

  defp eventually(fun, deadline_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk("eventually condition not met within timeout")

      true ->
        Process.sleep(20)
        do_eventually(fun, deadline)
    end
  end
end
