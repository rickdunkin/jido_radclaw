defmodule JidoClaw.Cron.FireFencingTest do
  @moduledoc """
  Durable cron-window fencing: the claim is an atomic filtered UPDATE on the
  persisted job row, so split-brain leaders cannot both dispatch one logical
  scheduled window. `:every` claims accept only the interval: PostgreSQL supplies
  both the cadence cutoff and stored timestamp, so caller clock skew is inert.
  """

  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Cron.Job
  alias JidoClaw.Repo

  test "two concurrent claims for one cron window have exactly one winner" do
    tenant = seed_tenant("cron-fire-claim")
    actor = actor_for(tenant)
    job = job!(tenant, actor, "claim-race")
    window = DateTime.add(DateTime.utc_now(), 60, :second)
    cutoff = DateTime.add(window, -1, :microsecond)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Job.claim_scheduled_fire(job, window, cutoff, job.definition_token,
            tenant: tenant,
            actor: actor
          )
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    assert {:ok, %{last_fire_at: ^window}} =
             Job.by_job_id(job.job_id, tenant: tenant, actor: actor)
  end

  test "skewed concurrent :every claims have one winner and store DB time" do
    tenant = seed_tenant("cron-every-claim")
    actor = actor_for(tenant)

    job =
      job!(tenant, actor, "every-race",
        schedule_kind: :every,
        schedule_value: "60000"
      )

    db_before = db_time!()

    # These model nodes whose local wall clocks disagree by a day. They are
    # deliberately NOT inputs to the interval-claim API; only the durable
    # interval reaches SQL.
    node_windows = [
      DateTime.add(db_before, -86_400, :second),
      DateTime.add(db_before, 86_400, :second)
    ]

    results =
      node_windows
      |> Enum.map(fn node_window ->
        Task.async(fn ->
          result =
            Job.claim_interval_fire(job, 60_000, job.definition_token,
              tenant: tenant,
              actor: actor
            )

          {node_window, result}
        end)
      end)
      |> Task.await_many(5_000)

    db_after = db_time!()

    assert Enum.count(results, fn {_window, result} -> match?({:ok, _}, result) end) == 1
    assert Enum.count(results, fn {_window, result} -> match?({:error, _}, result) end) == 1

    assert {:ok, %{last_fire_at: last_fire_at}} =
             Job.by_job_id(job.job_id, tenant: tenant, actor: actor)

    assert DateTime.compare(last_fire_at, db_before) in [:eq, :gt]
    assert DateTime.compare(last_fire_at, db_after) in [:eq, :lt]
    refute last_fire_at in node_windows

    assert {:error, _} =
             Job.claim_interval_fire(job, 60_000, job.definition_token,
               tenant: tenant,
               actor: actor
             )
  end

  test "re-upserting a job preserves its last claimed fire window" do
    tenant = seed_tenant("cron-upsert-claim")
    actor = actor_for(tenant)
    job = job!(tenant, actor, "upsert-claim")
    window = DateTime.add(DateTime.utc_now(), 60, :second)
    cutoff = DateTime.add(window, -1, :microsecond)

    assert {:ok, _} =
             Job.claim_scheduled_fire(job, window, cutoff, job.definition_token,
               tenant: tenant,
               actor: actor
             )

    re_upserted = job!(tenant, actor, job.job_id)
    assert re_upserted.last_fire_at == window
    refute re_upserted.definition_token == job.definition_token

    assert {:error, _} =
             Job.claim_scheduled_fire(re_upserted, window, cutoff, job.definition_token,
               tenant: tenant,
               actor: actor
             )
  end

  test "disabled and stale-definition workers cannot claim a later fire" do
    tenant = seed_tenant("cron-definition-claim")
    actor = actor_for(tenant)
    original = job!(tenant, actor, "definition-fence")
    later = DateTime.add(DateTime.utc_now(), 120, :second)
    cutoff = DateTime.add(later, -1, :microsecond)

    assert {:ok, disabled} = Job.disable(original, tenant: tenant, actor: actor)

    assert {:error, _} =
             Job.claim_scheduled_fire(disabled, later, cutoff, original.definition_token,
               tenant: tenant,
               actor: actor
             )

    replacement = job!(tenant, actor, original.job_id)
    refute replacement.definition_token == original.definition_token

    assert {:error, _} =
             Job.claim_scheduled_fire(replacement, later, cutoff, original.definition_token,
               tenant: tenant,
               actor: actor
             )

    assert {:ok, _} =
             Job.claim_scheduled_fire(replacement, later, cutoff, replacement.definition_token,
               tenant: tenant,
               actor: actor
             )

    assert {:error, _} =
             Job.record_failure(replacement, original.definition_token,
               tenant: tenant,
               actor: actor
             )

    assert {:ok, unchanged} = Job.by_job_id(replacement.job_id, tenant: tenant, actor: actor)
    assert unchanged.failure_count == 0

    assert {:error, _} =
             Job.disable_generation(replacement, original.definition_token,
               tenant: tenant,
               actor: actor
             )

    assert {:ok, still_enabled} =
             Job.by_job_id(replacement.job_id, tenant: tenant, actor: actor)

    assert is_nil(still_enabled.disabled_at)
  end

  defp job!(tenant, actor, id, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          job_id: id,
          task: "audit",
          schedule_kind: :cron,
          schedule_value: "0 * * * *",
          mode: :main
        },
        Map.new(overrides)
      )

    {:ok, job} =
      Job.upsert(attrs,
        tenant: tenant,
        actor: actor
      )

    job
  end

  defp db_time! do
    %{rows: [[timestamp]]} = Repo.query!("SELECT statement_timestamp()")
    timestamp
  end
end
