defmodule JidoClaw.Orchestration.ComposerArtifact.ActivateForWave do
  @moduledoc """
  Generic-action implementation for `ComposerArtifact.activate_for_wave` —
  the atomic `:pending → :active` promotion of a wave's artifacts, tombstoning
  any superseded `:active` row first so the
  `composer_artifacts_active_ref_index` partial-unique invariant
  (≤1 `:active` per `{tenant, parent_run_id, name, producer}`) is never
  violated mid-promotion (AR-2 Phase 2b).

  **Defined in 2b, wired in 2c.** 2b only inserts `:pending` rows
  (`store_pending`) and resolves them regardless of state (`resolve_ref`);
  the live composer's artifact availability still derives from the in-memory
  fold. This action ships complete so 2c's commit step can call it.

  Tombstone-before-promote runs in one `Ash.transact` so the index sees at
  most one `:active` per key at every step.
  """
  use Ash.Resource.Actions.Implementation

  alias JidoClaw.Orchestration.ComposerArtifact

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, context) do
    parent_run_id = input.arguments.parent_run_id
    wave_index = input.arguments.wave_index
    opts = [tenant: input.tenant, actor: context.actor]

    Ash.transact([ComposerArtifact], fn ->
      with {:ok, pendings} <- ComposerArtifact.pending_for_wave(parent_run_id, wave_index, opts),
           {:ok, actives} <- ComposerArtifact.active_for_run(parent_run_id, opts),
           :ok <- promote_all(pendings, index_by_key(actives), opts) do
        length(pendings)
      end
    end)
  end

  defp index_by_key(actives), do: Map.new(actives, fn a -> {{a.name, a.producer}, a} end)

  defp promote_all(pendings, active_by_key, opts) do
    Enum.reduce_while(pendings, :ok, fn pending, :ok ->
      case promote_one(pending, Map.get(active_by_key, {pending.name, pending.producer}), opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Tombstone the superseded active (if any) BEFORE flipping the pending to
  # active, so the partial-unique index never sees two actives for the key.
  defp promote_one(pending, nil, opts), do: ComposerArtifact.set_active(pending, opts)

  defp promote_one(pending, superseded, opts) do
    case ComposerArtifact.tombstone_active(superseded, opts) do
      {:ok, _} -> ComposerArtifact.set_active(pending, opts)
      {:error, _reason} = error -> error
    end
  end
end
