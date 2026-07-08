defmodule JidoClaw.Cron.Dispatcher do
  @moduledoc """
  Routes a `Cron.Worker` tick to its execution target.

  Dispatch is legacy-first: `mode: :system_job` resolves to MFA *before*
  `target` is consulted, so every pre-`target` row — and the in-memory
  memory-consolidator system job, which has no DB row — keeps working
  unchanged. New rows default to `target: :agent`.

    * `mode: :system_job` → MFA (legacy precedence)
    * `target: :workflow` → tracked `WorkflowRun` via the runner seam
    * `target: :mfa`      → MFA
    * otherwise (`:agent`) → a chat turn (`:main` shared / `:isolated` fresh)

  There is deliberately no `mfa`-present fallback clause: today
  `:main`/`:isolated` rows ignore any `mfa` field, and a
  `when not is_nil(mfa)` clause would silently change that. MFA fires
  only for `:system_job` / `:mfa`.

  Pure routing — telemetry, failure-counting, and `record_run` stay in
  the worker. The return value is passed through verbatim to the
  worker's `case result` handling (`:ok | {:ok, _} | {:error, _} | other`).
  """

  alias JidoClaw.Authorization.Actor

  @doc """
  The effective dispatch path for a worker state — the single source of truth
  for both routing (`dispatch/1`) and telemetry enrichment (`Cron.Worker`).

  Legacy-first precedence: `mode: :system_job` resolves to `:mfa` *before*
  `target` is read, so a `:system_job` row whose `target` defaults to `:agent`
  (e.g. the memory consolidator) reports — and runs — `:mfa`, not `:agent`.
  """
  @spec dispatch_target(map()) :: :agent | :workflow | :mfa
  def dispatch_target(%{mode: :system_job}), do: :mfa
  def dispatch_target(%{target: :workflow}), do: :workflow
  def dispatch_target(%{target: :mfa}), do: :mfa
  def dispatch_target(_), do: :agent

  @spec dispatch(map()) :: term()
  def dispatch(state) do
    case dispatch_target(state) do
      :mfa -> run_mfa(state)
      :workflow -> run_workflow(state)
      :agent -> run_agent(state)
    end
  end

  # Lifted verbatim from the former Worker.execute_job/1 `:isolated` arm.
  # `clarify: :one_shot` (queue item 8): a fresh per-tick session could never
  # answer a parked question round.
  defp run_agent(%{mode: :isolated} = state) do
    session_id = "cron_#{state.id}_#{System.system_time(:second)}"

    JidoClaw.chat(state.tenant_id, session_id, state.task,
      kind: :cron,
      external_id: session_id,
      actor: Actor.system(state.tenant_id),
      clarify: :one_shot
    )
  end

  # Lifted verbatim from the former `:main` arm. `clarify: :one_shot` here
  # too, DESPITE the stable session (`state.agent_id` is reused every tick):
  # nobody attends a cron session, and the next scheduled task must never be
  # read as an answer to a parked question round.
  defp run_agent(state) do
    JidoClaw.chat(state.tenant_id, state.agent_id, state.task,
      kind: :cron,
      external_id: state.agent_id,
      actor: Actor.system(state.tenant_id),
      clarify: :one_shot
    )
  end

  # Lifted verbatim from the former `:system_job` arm.
  defp run_mfa(state) do
    {m, f, a} = state.mfa
    apply(m, f, a)
  end

  defp run_workflow(state) do
    runner =
      Application.get_env(
        :jido_claw,
        :cron_workflow_runner,
        JidoClaw.Orchestration.WorkflowRunner
      )

    runner.run(state)
  end
end
