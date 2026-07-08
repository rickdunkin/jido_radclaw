defmodule JidoClaw.Cluster.CronProbeRunner do
  @moduledoc """
  A `:cron_workflow_runner` stub for the WS4a cron-failover proof
  (`cron_failover_test.exs`): every fire records one durable, node-attributed
  `WorkflowRun` row instead of resolving/compiling a skill — so "which node
  fired, and when" is answerable from the shared DB, the only cross-BEAM
  evidence channel.

  Mirrors `JidoClaw.Orchestration.WorkflowRunner.run/1`'s argument/return
  contract (the worker's dispatch state in, `:ok | {:error, _}` out) but
  deliberately inherits NONE of its read-first/window dedupe: the probe's
  `idempotency_key` carries a per-fire unique suffix, so a fire from a wrong
  node can never be masked by the real `cron:<job>:<window>` unique index —
  every fire is a visible row, attributed via `metadata.node`. The
  no-double-fire assertions are node-partition set arithmetic over these rows,
  not window grouping (each worker computes its `:every` window from its own
  clock, so two wrongly-live workers would fire one real interval under
  different window stamps).
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.WorkflowRun

  @doc """
  Record one probe row for this fire. Reads `id` (the job id), `tenant_id`,
  and the `fire` provenance from the worker's dispatch state; never raises
  (the cron worker treats a raise as a job failure and counts toward
  auto-disable — a probe must not disable the job it is probing).
  """
  @spec run(map()) :: :ok | {:error, term()}
  def run(state) do
    window = window_label(Map.get(state, :fire))
    node = Atom.to_string(node())

    attrs = %{
      name: "cron-probe:#{state.id}:#{window}:#{node}",
      workflow_type: "cron-probe",
      idempotency_key:
        "cron-probe:#{state.id}:#{window}:#{node}:#{System.unique_integer([:positive])}",
      metadata: %{node: node, window: window}
    }

    case WorkflowRun.create(attrs,
           tenant: state.tenant_id,
           actor: Actor.system(state.tenant_id)
         ) do
      {:ok, _run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp window_label({:scheduled, %DateTime{} = window}), do: DateTime.to_iso8601(window)
  defp window_label(other), do: inspect(other)
end
