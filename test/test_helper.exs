# Manual sandbox ownership is what makes `async: true` DB tests sound: each
# test's `Sandbox.start_owner!` (TenantCase/SolutionsCase) owns a connection,
# and processes the test spawns reach it through `$callers` — a mechanism the
# ownership pool only consults in `:manual` mode. The pool's default `:auto`
# mode instead hands any unassociated process a fresh auto-checkout whose
# transaction cannot see the test's uncommitted rows (and which pins a pool
# connection for the process's lifetime). App boot has already completed by
# the time this file runs, so boot-time writes are unaffected; background
# processes touching the DB outside any owner now raise the loud
# `DBConnection.OwnershipError` instead of silently reading stale state.
#
# The cluster suite (JIDOCLAW_CLUSTER_TEST=1) swaps the sandbox for a regular
# pool, where sandbox operations raise — hence the guard.
if System.get_env("JIDOCLAW_CLUSTER_TEST") != "1" do
  Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :manual)
end

# Cap module concurrency to the connection budget config/test.exs sized the
# pool for (partition-aware). A CLI --max-cases still overrides.
max_cases =
  Application.get_env(:jido_claw, :test_async_case_budget, System.schedulers_online() * 2)

ExUnit.start(exclude: [:docker_sandbox, :slow, :cluster], max_cases: max_cases)
