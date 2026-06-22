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
  Peel a lone gate out of a mixed dispatch cohort (AR-2 §14 Phase 4b).

  A gate runs as its own single-stage wave (a module reactor, not a struct), but
  the router does not guarantee a `{:gate, _}` stage is alone in its Kahn level —
  the shipped catalog co-locates `plan-gate` with `test-author` / `implementer`.
  So when a `dispatch` cohort holds **exactly one** gate alongside ≥1 other stage,
  dispatch that gate alone this turn; the independent workers have no intra-level
  edge to it (`wave_builder.ex` — same-level stages are independent) and re-compose
  next tick, preserving linear progress.

  Everything else passes through unchanged: a cohort with no gate, a cohort that is
  already a solo gate, and — deliberately — a cohort with **more than one** gate. A
  multi-gate cohort then hits `WaveBuilder`'s `{:gate_must_be_solo_wave, names}`
  backstop, because multi-gate-per-level is unsupported (the composer holds a single
  `state.parked` at a time).
  """
  @spec split_solo_gate([String.t()], catalog()) :: [String.t()]
  def split_solo_gate(dispatch, catalog) do
    peel_gate(Enum.filter(dispatch, &gate_stage?(catalog, &1)), dispatch)
  end

  # A LONE gate in a cohort of ≥2 stages → peel that gate; a cohort with no gate, an
  # already-solo gate, OR >1 gate passes through unchanged. A multi-gate cohort then hits
  # WaveBuilder's `{:gate_must_be_solo_wave, names}` backstop (wave_builder.ex) — multi-gate-
  # per-level is unsupported (one `state.parked` at a time). Pattern-matched, not `length/1`.
  defp peel_gate([gate], [_, _ | _]), do: [gate]
  defp peel_gate(_gates, dispatch), do: dispatch

  defp gate_stage?(catalog, name) do
    match?(%Stage{unit: {:gate, _name}}, Map.get(catalog, name))
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
