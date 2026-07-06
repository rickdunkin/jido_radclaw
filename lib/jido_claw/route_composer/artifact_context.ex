defmodule JidoClaw.RouteComposer.ArtifactContext do
  @moduledoc """
  Formats the cross-wave artifact store into the single `:extra_context` string
  a wave reactor receives (AR-2 §5).

  Per-wave reactors are separate, so the in-reactor `StepResult` edges
  `JidoClaw.Workflows.ContextBuilder` wires don't span waves. The composer
  instead serializes the artifacts each wave's stages name in their `input`
  (required ∪ optional, across producers) out of the **provenance-keyed** store
  (`name → %{producer => ref}`) into one markdown block.

  Phase 2b: a **wave-produced** entry is an explicitly-tagged `{:ref, art_<hex>}`
  (`JidoClaw.RouteComposer.Fold` tags every emission artifact value, P2),
  **resolved + decrypted** via `ComposerArtifact.resolve_value/2` (tenant/actor
  threaded from the composer state) before formatting — the **only** place a
  decrypted artifact value re-enters live execution. (One documented sibling
  decrypt site exists outside execution: the composer's review-stall raise
  (camus C1-4, `RouteComposer.build_stall_park/2`) resolves the surviving
  `findings` artifacts to build the gate case's redacted, bounded operator
  details — those values flow only into `AgentCase.details`, never back into
  a wave.) The tag (not an `art_<hex>`
  regex heuristic) is what distinguishes a ref from an inline value, so a seed
  that merely looks like a ref is never misread.

  A **seed** entry takes one of two shapes (Phase 2d):

    * **folded / recovered** — once `do_rebuild` folds the genesis
      `artifacts_produced` event, the inline seed is overwritten with a
      `{:ref, art_<hex>}` (a real ref-stored seed row, `wave_index: -1`,
      `producer: "seed"`), so it resolves + decrypts here exactly like a
      wave-produced artifact (this is the normal launch *and* recovery path);
    * **minimal launch** — a `create_parent_run` with no genesis seed event
      (the lifecycle tests' bare path) keeps the in-memory seed as an untagged
      inline value, used directly.

  Either way a seed's durable exposure is via the subagent task, sanitized by the
  Phase 2b marker (Theme B).

  `build/4` returns `{:ok, text} | {:error, reason}`: a missing ref, corrupt
  envelope, wrong-tenant ref, or decrypt failure is a **controlled wave
  failure**, never a crash or a silently-omitted artifact (P1-2).

  Missing optionals are simply absent; a missing *required* input is the
  router's drop decision, not the formatter's. Each rendered value is truncated
  to a per-value byte cap (elision marked) and the whole string to a total cap.
  Names and producers are sorted so the string is deterministic.
  """

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.RouteComposer.Stage

  @per_value_cap 4_000
  @total_cap 16_000
  @elision "…[truncated]"

  @type store :: %{optional(String.t()) => %{optional(String.t()) => {:ref, String.t()} | term()}}

  @doc """
  Build the `:extra_context` string for `stages` from the provenance `store`,
  resolving + decrypting each ref under `tenant`/`actor`.

  Collects every artifact named in the stages' `input` (required ∪ optional),
  resolves each present artifact's `producer → ref` entries, renders them, and
  joins them. Returns `{:ok, ""}` when none of the wanted artifacts are present,
  `{:ok, text}` otherwise, or `{:error, reason}` if any ref fails to resolve.
  """
  @spec build([Stage.t()], store(), String.t(), term()) ::
          {:ok, String.t()} | {:error, term()}
  def build(stages, store, tenant, actor) do
    case resolve_sections(stages, store, tenant, actor) do
      {:ok, sections} -> {:ok, cap(Enum.join(sections, "\n\n"), @total_cap)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_sections(stages, store, tenant, actor) do
    stages
    |> wanted_names()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case section(name, Map.get(store, name), tenant, actor) do
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, [section]} -> {:cont, {:ok, [section | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp wanted_names(stages) do
    Enum.reduce(stages, MapSet.new(), fn %Stage{input: input}, acc ->
      acc
      |> MapSet.union(MapSet.new(input.required))
      |> MapSet.union(MapSet.new(input.optional))
    end)
  end

  defp section(_name, nil, _tenant, _actor), do: {:ok, []}
  defp section(_name, producers, _tenant, _actor) when map_size(producers) == 0, do: {:ok, []}

  defp section(name, producers, tenant, actor) do
    case resolve_entries(producers, tenant, actor) do
      {:ok, entries} -> {:ok, ["### #{name}\n#{Enum.join(entries, "\n")}"]}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_entries(producers, tenant, actor) do
    producers
    |> Enum.sort_by(fn {producer, _entry} -> producer end)
    |> Enum.reduce_while({:ok, []}, fn {producer, entry}, {:ok, acc} ->
      case resolve_entry(entry, tenant, actor) do
        {:ok, value} ->
          line = "- **#{producer}**: #{cap(to_text(value), @per_value_cap)}"
          {:cont, {:ok, [line | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:artifact_resolve_failed, entry, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  # A tagged `{:ref, ref}` (P2) — a wave-produced artifact, OR a folded/recovered
  # seed row (Phase 2d: genesis ref-stores the seed, `do_rebuild` folds it to a
  # ref): resolve + decrypt. Any other term is an untagged inline seed value (a
  # minimal in-memory launch with no genesis seed event), used directly — so a
  # seed that merely looks like `art_<hex>` is never misread as a ref and failed.
  defp resolve_entry({:ref, ref}, tenant, actor) when is_binary(ref),
    do: ComposerArtifact.resolve_value(ref, tenant: tenant, actor: actor)

  defp resolve_entry(entry, _tenant, _actor), do: {:ok, entry}

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: inspect(value)

  defp cap(text, limit) when byte_size(text) <= limit, do: text
  defp cap(text, limit), do: byte_truncate(text, limit) <> @elision

  # Byte-bounded but UTF-8-safe: take `limit` bytes, then drop any dangling
  # partial codepoint (at most 3 bytes) so the result is always a valid string.
  defp byte_truncate(text, limit) do
    part = binary_part(text, 0, limit)
    if String.valid?(part), do: part, else: byte_truncate(text, limit - 1)
  end
end
