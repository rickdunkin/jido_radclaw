defmodule JidoClaw.Orchestration.WorkflowRun.Calculations.FindingsDeferredCount do
  @moduledoc """
  Public GraphQL projection of the run's deferred-findings count.

  Delegates to
  `JidoClaw.Orchestration.Visibility.result_findings_deferred_count/1` — the
  same derivation `run_view/3` uses — pairing with
  `WorkflowRun.Calculations.Disposition` so amber rendering (camus C1-4)
  reaches GraphQL consumers with unforked semantics. Non-sensitive by
  construction: a count, never finding bodies.

  Loads the private `result` attribute (`load/3` — Ash 3 removed `select/3`);
  the raw map itself is never exposed, only the derived count.
  """

  use Ash.Resource.Calculation

  alias JidoClaw.Orchestration.Visibility

  @impl Ash.Resource.Calculation
  def load(_query, _opts, _context), do: [:result]

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, &Visibility.result_findings_deferred_count(&1.result))
  end
end
