defmodule JidoClaw.Orchestration.WorkflowRun.Calculations.Disposition do
  @moduledoc """
  Public GraphQL projection of the run's terminal disposition marker.

  Delegates to `JidoClaw.Orchestration.Visibility.result_disposition/1` — the
  same derivation `run_view/3` uses — so the camus C1-4 "never plain green"
  rule (a completed-with-deferred-findings run must be distinguishable from a
  clean one on EVERY surface) rides the GraphQL schema without forking the
  semantics. Non-sensitive by construction: the marker is a disposition
  string, never finding bodies.

  Loads the private `result` attribute (`load/3` — Ash 3 removed `select/3`);
  the raw map itself is never exposed, only the derived marker.
  """

  use Ash.Resource.Calculation

  alias JidoClaw.Orchestration.Visibility

  @impl Ash.Resource.Calculation
  def load(_query, _opts, _context), do: [:result]

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, &Visibility.result_disposition(&1.result))
  end
end
