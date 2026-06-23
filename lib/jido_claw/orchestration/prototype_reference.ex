defmodule JidoClaw.Orchestration.PrototypeReference do
  @moduledoc """
  The single-sourced "is this prototype dir still needed by a live run?" check
  the AR-8b-2 C3 retention sweeper consults before deleting a `.prototypes/<id>/`
  dir.

  A prototype is *referenced* while some non-terminal `WorkflowRun` carries it in
  `config["premises"]["prototype_id"]` — under fresh summarization (C1) the only
  process that reads the dir after launch is the in-flight sketch run whose parent
  holds that premise, so this protects exactly the live window. `graduated_from`
  is pure provenance and needs no protection; a dangling un-consumed graduation
  candidate isn't protected either (it degrades gracefully).

  Three-state and **fail-safe**: a DB error is `:unknown`, never
  `:unreferenced`, so a transient query failure can never green-light a deletion.
  """

  alias JidoClaw.Orchestration.WorkflowRun

  @doc """
  Whether `id` is referenced by a live (non-terminal) run.

  `:referenced` (keep), `:unreferenced` (safe to sweep), or `:unknown` (a DB
  error — the sweeper MUST keep).
  """
  @spec reference_state(String.t()) :: :referenced | :unreferenced | :unknown
  def reference_state(id) when is_binary(id) do
    case WorkflowRun.list_referencing_prototype_global(id) do
      {:ok, [_ | _]} -> :referenced
      {:ok, []} -> :unreferenced
      _ -> :unknown
    end
  end
end
