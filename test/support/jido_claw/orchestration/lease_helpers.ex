defmodule JidoClaw.Orchestration.LeaseHelpers.ForcedStampErrorLease do
  @moduledoc """
  Stub lease module for `LeaseHelpers.with_forced_stamp_error/1`: forces the
  middleware's CAS row-claim to `{:error, :forced}` WITHOUT touching the DB (a real
  Postgrex error would poison the shared sandbox transaction, and the project has no
  Mox). Only `stamp/4` is overridden — the `Lease.Middleware` test seam calls only
  that on `lease_module()`.
  """
  @spec stamp(String.t(), String.t(), String.t() | nil, keyword()) :: {:error, :forced}
  def stamp(_run_id, _new_token, _expected_token, _opts \\ []), do: {:error, :forced}
end

defmodule JidoClaw.Orchestration.LeaseHelpers do
  @moduledoc """
  Shared lease-seeding helpers for the WS1 lease suite (`workflow_lease_test.exs`)
  and the WS3 reclaim suite (`reclaim_pooler_test.exs`).

  The raw-SQL claim/status/age seeders (the `retention_sweeper_test` backdating
  precedent — expired leases / rotated tokens / aged `inserted_at` are seeded via
  `Repo.query!` so the production auto-renew timer never has to be unparked) plus
  `launch_blocking/1` (a forever-blocking *leased* run via the full runner path).
  Extracted from `workflow_lease_test.exs`'s `defp`s for cross-suite reuse.

  Every helper takes the test `ctx` (`%{tenant:, actor:}`) explicitly and computes
  its scope inline, so the module is self-contained; the ExUnit macros
  (`assert_receive`, `on_exit`) expand in the importing test's process.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias JidoClaw.Orchestration.LeaseHelpers.ForcedStampErrorLease
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Reactors.BlockingTestReactor
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo

  @doc "Create a fresh `:pending` reactor run for `ctx`'s tenant."
  @spec seed_run(map(), String.t()) :: WorkflowRun.t()
  def seed_run(%{tenant: tenant, actor: actor}, name \\ "lease-test") do
    {:ok, run} =
      WorkflowRun.create(%{name: name, workflow_type: "reactor"}, tenant: tenant, actor: actor)

    run
  end

  @doc "Reload a run by id across tenants (the policy-bypassed global lookup)."
  @spec reload_global(String.t()) :: WorkflowRun.t()
  def reload_global(run_id) do
    {:ok, %WorkflowRun{} = run} = WorkflowRun.by_id_global(run_id)
    run
  end

  @doc "The ordered event kinds in a run's durable log."
  @spec kinds(String.t(), map()) :: [atom()]
  def kinds(run_id, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run_id, tenant: tenant, actor: actor)
    Enum.map(events, & &1.kind)
  end

  @doc """
  Launch a forever-blocking run via the full runner path (so it stamps its lease +
  starts a sidecar), returning `{launcher_task, run_id, executor_pid}`. Raw-pid
  kills in `on_exit` (off the owner process, where `Task.shutdown` raises); killing a
  dead pid is a no-op.
  """
  @spec launch_blocking(map()) :: {Task.t(), String.t(), pid()}
  def launch_blocking(%{tenant: tenant, actor: actor}) do
    test_pid = self()

    launcher =
      Task.async(fn ->
        ReactorRunner.run(
          BlockingTestReactor,
          %{},
          tenant: tenant,
          actor: actor,
          context: %{test_pid: test_pid}
        )
      end)

    assert_receive {:blocking_step_started, _step_pid, run_id}, 5_000
    assert {:ok, executor, _tenant} = RunExecution.lookup(run_id)

    launcher_pid = launcher.pid

    on_exit(fn ->
      Process.exit(executor, :kill)
      Process.exit(launcher_pid, :kill)
    end)

    {launcher, run_id, executor}
  end

  @doc "Run `fun` with `:cluster_enabled` set to `value`, restoring the prior value after."
  @spec with_cluster_enabled(boolean(), (-> any())) :: any()
  def with_cluster_enabled(value, fun) do
    prev = Application.get_env(:jido_claw, :cluster_enabled, false)
    Application.put_env(:jido_claw, :cluster_enabled, value)

    try do
      fun.()
    after
      Application.put_env(:jido_claw, :cluster_enabled, prev)
    end
  end

  @doc """
  Run `fun` with the lease module's `stamp/4` forced to `{:error, :forced}` (via the
  `:workflow_lease_module` app-env seam `Lease.Middleware` reads), restoring after.
  Models `with_cluster_enabled/2`, but restores with the EXACT delete-vs-put dance
  (`Application.fetch_env/2`): no config sets `:workflow_lease_module`, so the prior
  value is normally absent and must be DELETED, not put back as `nil`.
  """
  @spec with_forced_stamp_error((-> any())) :: any()
  def with_forced_stamp_error(fun) do
    prev = Application.fetch_env(:jido_claw, :workflow_lease_module)
    Application.put_env(:jido_claw, :workflow_lease_module, ForcedStampErrorLease)

    try do
      fun.()
    after
      case prev do
        {:ok, value} -> Application.put_env(:jido_claw, :workflow_lease_module, value)
        :error -> Application.delete_env(:jido_claw, :workflow_lease_module)
      end
    end
  end

  # -- raw SQL seeding (the retention_sweeper_test backdating precedent) --

  @doc "Stamp a claim with `token`/`claimed_by` and an expiry `expires_in_seconds` from now (negative = expired)."
  @spec set_claim!(String.t(), String.t() | nil, integer()) :: term()
  def set_claim!(run_id, token, expires_in_seconds) do
    Repo.query!(
      "UPDATE workflow_runs SET claim_token = $1, claimed_by = $2, " <>
        "claim_expires_at = now() + ($3 || ' seconds')::interval WHERE id = $4",
      [dump_token(token), "seed-node", to_string(expires_in_seconds), Ecto.UUID.dump!(run_id)]
    )
  end

  @doc "Rotate a run's `claim_token` directly (no expiry change) — the reclaimer-steal seed."
  @spec rotate_token!(String.t(), String.t()) :: term()
  def rotate_token!(run_id, token) do
    Repo.query!(
      "UPDATE workflow_runs SET claim_token = $1 WHERE id = $2",
      [Ecto.UUID.dump!(token), Ecto.UUID.dump!(run_id)]
    )
  end

  @doc "Force a run's `status` directly (bypassing the projection) — the terminal/running seed."
  @spec set_status!(String.t(), String.t()) :: term()
  def set_status!(run_id, status) do
    Repo.query!(
      "UPDATE workflow_runs SET status = $1 WHERE id = $2",
      [status, Ecto.UUID.dump!(run_id)]
    )
  end

  @doc "Backdate a run's `inserted_at` by `seconds_ago` — ages a `:pending` row past the genesis grace."
  @spec backdate_inserted!(String.t(), integer()) :: term()
  def backdate_inserted!(run_id, seconds_ago) do
    Repo.query!(
      "UPDATE workflow_runs SET inserted_at = now() - ($1 || ' seconds')::interval WHERE id = $2",
      [to_string(seconds_ago), Ecto.UUID.dump!(run_id)]
    )
  end

  defp dump_token(nil), do: nil
  defp dump_token(token), do: Ecto.UUID.dump!(token)
end
