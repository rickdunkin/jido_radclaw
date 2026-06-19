defmodule JidoClaw.RouteComposer.Loop do
  @moduledoc """
  Pure loop decisions for `JidoClaw.RouteComposer` (AR-2 §4) — tested without
  the process.

    * `dispatch_cohort/2` — the first merged wave minus `ran` that is non-empty
      (the runnable cohort). `merge_sticky` yields a **display** route that may
      re-add already-run sticky stages, so the loop filters each wave to
      `stage not in ran` before executing or testing convergence — folding the
      merged route straight into `hd(waves)` would re-run a sticky stage and
      never converge.
    * `terminal/2` — classifies the run when no unrun cohort remains:
      `:converged` (nothing held and every ran lens clean), `:not_converged`
      (a ran lens still has open findings and, with self-heal/rerun deferred in
      forward-only Phase 1, nothing will resolve it — an explicit terminal
      failure, not a spin), or `:deadlock` (a non-empty `held` no runnable stage
      can ever release — surfaced, not a busy-wait).
    * `lenses_clean?/3` — every `ran` stage carrying a `lens` has its
      `clean:<lens>` live (the fold's paired-verdict invariant guarantees
      exactly one of the pair is live per lens).
  """

  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.Stage

  @type catalog :: %{optional(String.t()) => Stage.t()}
  @type terminal :: :converged | :not_converged | :deadlock

  @doc """
  The first display wave, filtered to `stage not in ran`, that is non-empty —
  the runnable cohort for this turn — or `nil` when nothing unrun remains.
  """
  @spec dispatch_cohort(Router.merged(), MapSet.t(String.t())) :: [String.t()] | nil
  def dispatch_cohort(display, ran) do
    display.waves
    |> Enum.map(fn wave -> Enum.reject(wave, &MapSet.member?(ran, &1)) end)
    |> Enum.find(fn cohort -> cohort != [] end)
  end

  @doc """
  Classify a dispatch-empty turn. `state` carries `:catalog`, `:ran`, `:live`.
  """
  @spec terminal(Router.merged(), %{
          :catalog => catalog(),
          :ran => MapSet.t(String.t()),
          :live => MapSet.t(String.t()),
          optional(atom()) => term()
        }) :: terminal()
  def terminal(display, state) do
    cond do
      map_size(display.held) > 0 -> :deadlock
      lenses_clean?(state.catalog, state.ran, state.live) -> :converged
      true -> :not_converged
    end
  end

  @doc """
  True when every `ran` stage carrying a `lens` has its `clean:<lens>` in `live`.
  """
  @spec lenses_clean?(catalog(), MapSet.t(String.t()), MapSet.t(String.t())) :: boolean()
  def lenses_clean?(catalog, ran, live) do
    ran
    |> Enum.map(&Map.get(catalog, &1))
    |> Enum.filter(&lens_stage?/1)
    |> Enum.all?(fn %Stage{lens: lens} -> MapSet.member?(live, "clean:#{lens}") end)
  end

  defp lens_stage?(%Stage{lens: lens}), do: is_binary(lens)
  defp lens_stage?(_stage), do: false
end
