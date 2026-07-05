defmodule JidoClaw.Orchestration.Verdict do
  # Ported from mateodaza/camus @ 53da91b3, MIT (adapter.py normalize_codex —
  # the three-exit contract + schema-drift-fails-closed-to-infra rules).
  @moduledoc """
  The verdict normalizer contract (camus C1-3): every boundary where a
  probabilistic judge's output enters the engine gets exactly three exits —

    * `{:verdict, %Verdict{}}` — a trustworthy verdict (clean or with findings);
    * `{:infra, reason}` — the judge did not produce a usable verdict (empty
      output, schema drift, self-contradiction, execution failure). Retried on
      a budget separate from the findings-driven rerun budget and terminalized
      as a distinct disposition — never folded as ran, never counted as a real
      rejection, never clean;
    * `{:inconclusive, reason}` — the judge ran but deliberately abstained.
      Produced by item 5's deterministic verify authority
      (`JidoClaw.Orchestration.Verify` → the `Reactors.VerifyStage` emission:
      `missing_tool`/`no_tests`/`timeout`/`output_limit`/
      `integrity_unavailable` refusals, config-resolution errors, and the
      composer's `"uncertified_green"` reclassification); consumers fold it
      into the infra lane.

  `normalize/2` must be **total over arbitrary input** — it is also item 7's
  deposit-tool contract (external CLI JSON that never passed Zoi). Schema drift
  always fails closed to `{:infra, _}`, never to a verdict.

  Kind modules implement the `normalize/1` callback; this module dispatches by
  kind (`:review` → `Verdict.Review`, `:iterative_eval` →
  `Verdict.IterativeEval`) and hosts the shared fail-closed primitives
  (`blank?/1`, `field/2`, `decode_enum/2` — whitelist decode, never
  `String.to_atom/1`) so the kind modules stay clone-free.

  Distinct from `JidoClaw.Triage.Verdict` (the front-door path classifier) —
  different subsystem; never alias both in one module.
  """

  @typedoc "Why a judge output failed to normalize — an atom or `{atom, raw}`."
  @type reason :: atom() | {atom(), term()}

  @type result :: {:verdict, t()} | {:infra, reason()} | {:inconclusive, reason()}

  @type t :: %__MODULE__{
          clean?: boolean(),
          decision: atom() | nil,
          findings: [map()],
          summary: String.t() | nil,
          source: map()
        }

  defstruct clean?: false, decision: nil, findings: [], summary: nil, source: %{}

  @doc """
  Normalize one kind's raw judge output. Total: any input maps to one of the
  three exits, never a raise (the item-7 deposit / item-5 verify seam).
  """
  @callback normalize(raw :: term()) :: result()

  @kinds %{review: __MODULE__.Review, iterative_eval: __MODULE__.IterativeEval}

  @doc """
  Dispatch `raw` to the `kind`'s normalizer. Raises on an unknown kind —
  callers pass a literal, so a miss is a programmer error, not judge input.
  """
  @spec normalize(atom(), term()) :: result()
  def normalize(kind, raw), do: Map.fetch!(@kinds, kind).normalize(raw)

  # Bounds for reasons that embed raw malformed judge output: `inspect/2` depth
  # + printable caps, then a hard grapheme cap — a huge garbage output never
  # becomes a huge reason string in traces, history, or the terminal error.
  @inspect_opts [limit: 5, printable_limit: 120]
  @max_reason_graphemes 240

  @doc """
  Render a `reason` as a bounded, human-readable string for outcome strings,
  trace events, and terminal errors. Total over any term.
  """
  @spec format_reason(reason()) :: String.t()
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason({tag, raw}) when is_atom(tag), do: "#{tag}: #{bounded_inspect(raw)}"
  def format_reason(other), do: bounded_inspect(other)

  defp bounded_inspect(term) do
    rendered = inspect(term, @inspect_opts)

    if String.length(rendered) > @max_reason_graphemes do
      String.slice(rendered, 0, @max_reason_graphemes) <> "…"
    else
      rendered
    end
  end

  # ---------------------------------------------------------------------------
  # Shared fail-closed primitives (used qualified by the kind modules — public
  # here, never re-wrapped in local delegates)
  # ---------------------------------------------------------------------------

  @doc "True for the empty-output shapes: `nil`, `\"\"`, whitespace-only."
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: false

  @doc """
  Atom-key-wins, string-key-fallback map read (the `projection.ex` idiom) —
  tolerates the atom-keyed live shape and the string-keyed JSON round-trip.
  """
  @spec field(map(), atom()) :: term()
  def field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  @doc """
  Whitelist-decode an enum value (atom or binary) via a fixed
  `%{string => decoded}` mapping — the `JidoClaw.Triage.Verdict.from_map/1`
  style, never `String.to_atom/1`. Any other shape (or a miss) is `:error`.
  """
  @spec decode_enum(term(), %{optional(String.t()) => term()}) :: {:ok, term()} | :error
  def decode_enum(value, mapping) when is_atom(value) or is_binary(value) do
    case Map.get(mapping, to_string(value)) do
      nil -> :error
      decoded -> {:ok, decoded}
    end
  end

  def decode_enum(_value, _mapping), do: :error
end
