defmodule JidoClaw.Gates.TestIrreversibleWrite do
  @moduledoc """
  Test gate impl for the `:irreversible_write` kind.

  Records `after_approved` / `after_rejected` invocations to a public named ETS
  table so tests can assert the **operator-path** hook fired (and, on the
  boot-recovery path, that it did *not* — Decision 8). Writes are idempotent
  (set semantics), matching the at-least-once hook contract.

  `set_behavior/1` makes `after_approved` misbehave on demand
  (`:throw`/`:exit`/`:hang`) so tests can prove a crashing or hung hook can no
  longer block or strand the decision/resume path (the hook now runs on an
  isolated, timed supervised task). Default `:ok` records the marker as before.
  """

  use JidoClaw.Orchestration.Gates, kind: :irreversible_write

  alias JidoClaw.Orchestration.GateContext

  @table :gate_test_markers

  @impl JidoClaw.Orchestration.Gates
  def after_approved(%GateContext{agent_case: agent_case}) do
    case behavior() do
      :ok ->
        record(:approved, agent_case.id)
        :ok

      :throw ->
        throw(:boom)

      :exit ->
        exit(:boom)

      :hang ->
        Process.sleep(:infinity)
    end
  end

  @impl JidoClaw.Orchestration.Gates
  def after_rejected(%GateContext{agent_case: agent_case}) do
    record(:rejected, agent_case.id)
    :ok
  end

  @doc "True if `after_approved` recorded a marker for this case."
  @spec approved?(Ecto.UUID.t()) :: boolean()
  def approved?(case_id), do: marked?(:approved, case_id)

  @doc "True if `after_rejected` recorded a marker for this case."
  @spec rejected?(Ecto.UUID.t()) :: boolean()
  def rejected?(case_id), do: marked?(:rejected, case_id)

  @doc """
  Create/clear the markers table and reset the hook behavior (call in setup).

  **Creates** the table here (owned by the calling test process) so it outlives
  the now-isolated hook task: an un-heired named table is destroyed when its
  owner dies, so if the short-lived hook task were the first to create it, its
  marker would vanish the instant the task exits.
  """
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Set the `after_approved` hook behavior. `:ok` (the default) records the
  marker; `:throw`/`:exit`/`:hang` make the hook crash or hang so tests can
  prove it cannot block or strand the decision/resume path.
  """
  @spec set_behavior(:ok | :throw | :exit | :hang) :: :ok
  def set_behavior(behavior) when behavior in [:ok, :throw, :exit, :hang] do
    :ets.insert(ensure_table(), {:behavior, behavior})
    :ok
  end

  defp record(marker, case_id) do
    :ets.insert(ensure_table(), {{marker, case_id}, true})
  end

  defp marked?(marker, case_id) do
    case :ets.whereis(@table) do
      :undefined -> false
      _tid -> :ets.member(@table, {marker, case_id})
    end
  end

  # The configured hook behavior, defaulting to `:ok` when unset/reset.
  defp behavior do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        case :ets.lookup(@table, :behavior) do
          [{:behavior, behavior}] -> behavior
          [] -> :ok
        end
    end
  end

  # Lazily create the public named table; tolerate a concurrent creator.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _tid -> @table
    end
  rescue
    ArgumentError -> @table
  end
end
