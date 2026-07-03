defmodule JidoClaw.CLI.RunAwait do
  @moduledoc """
  Awaits a composer run's terminal state for the one-shot CLI runner
  (`JidoClaw.CLI.RunCommand`).

  Polling `WorkflowRun.by_id` is the AUTHORITATIVE terminal detector: a
  composer *parent*'s terminal status is written via the
  `WorkflowLog.append` → projection path, which does not broadcast (ordinary
  Reactor runs do broadcast completion — do not rely on that here).
  `RunPubSub.subscribe/1` is wired only as an early-wake optimization: any
  run-topic event cuts the current tick short and triggers an immediate
  re-poll.

  Gate detection probes `AgentCase.pending_for_run_tree/1` because a composer
  parent stays `:running` while parked on a human gate — the child wave run
  goes `:awaiting_approval` and carries the `AgentCase`.
  """

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowRun

  @terminal_statuses [:completed, :failed, :cancelled, :abandoned]
  @tick_ms 500

  @type outcome ::
          {:done, atom(), WorkflowRun.t()}
          | {:gate_pending, [String.t()]}
          | :timeout
          | {:error, term()}

  @doc """
  Poll `run_id` (~#{@tick_ms}ms tick, pubsub early-wake) until it reaches a
  terminal status, a pending gate appears anywhere in its run tree, or
  `timeout_ms` elapses.
  """
  @spec await(String.t(), String.t(), map(), non_neg_integer()) :: outcome()
  def await(run_id, tenant_id, actor, timeout_ms)
      when is_binary(run_id) and is_binary(tenant_id) and is_integer(timeout_ms) do
    _ = RunPubSub.subscribe(run_id)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(run_id, tenant_id, actor, deadline)
  end

  defp poll(run_id, tenant_id, actor, deadline) do
    case WorkflowRun.by_id(run_id, tenant: tenant_id, actor: actor) do
      {:ok, %WorkflowRun{status: status} = run} when status in @terminal_statuses ->
        {:done, status, run}

      {:ok, %WorkflowRun{}} ->
        check_gates(run_id, tenant_id, actor, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_gates(run_id, tenant_id, actor, deadline) do
    case AgentCase.pending_for_run_tree(run_id, tenant: tenant_id, actor: actor) do
      {:ok, [_ | _] = cases} ->
        {:gate_pending, Enum.map(cases, & &1.id)}

      _ ->
        wait_then_repoll(run_id, tenant_id, actor, deadline)
    end
  end

  defp wait_then_repoll(run_id, tenant_id, actor, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      # SELECTIVE early wake: consume only run-topic events for THIS run
      # (`{kind, run_id, info}` — the RunPubSub payload shape). A catch-all
      # here would eat unrelated mailbox messages of the calling process
      # (Task replies, monitor DOWNs). Polling stays the source of truth, so
      # an event this pattern misses only costs one tick of latency.
      receive do
        {_kind, ^run_id, _info} -> :ok
      after
        min(remaining, @tick_ms) -> :ok
      end

      poll(run_id, tenant_id, actor, deadline)
    end
  end
end
