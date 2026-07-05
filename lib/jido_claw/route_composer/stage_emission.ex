defmodule JidoClaw.RouteComposer.StageEmission do
  @moduledoc """
  One stage's typed emission on a wave — the signals it published and the
  artifacts it produced (AR-2 §7).

  `artifacts` is `%{name => ref}` — an opaque `ComposerArtifact` ref string
  (Phase 2b), not the value. `JidoClaw.RouteComposer.Emit.DefaultMapper`
  produces the pre-persist emission (inline mapper values), then
  `JidoClaw.RouteComposer.Steps.WaveCollect` ref-stores each value and the
  composer rehydrates the ref-valued emission via `from_map/1`;
  `JidoClaw.RouteComposer.Fold` indexes the refs. The struct itself
  is **not** json-safe (`JidoClaw.Orchestration.ReactorMiddleware`'s
  `json_safe?/1` rejects every struct), so `JidoClaw.RouteComposer.Steps.WaveCollect`
  returns the json-safe **map** form and the composer rehydrates each emission
  with `from_map/1`.

  `outcome` (camus C1-3) is the stage's normalizer exit: `:ok` for a real
  emission, `{:infra, reason}` when the judge produced no usable verdict,
  `{:inconclusive, reason}` (produced by item 5's deterministic verify stage —
  consumers fold it into the infra lane), or `{:tampered, reason}` (item 5:
  the verify stage detected tampering — the composer welds `:stage_tampered`
  and terminalizes, never retries, never summons the fixer). A non-`:ok`
  emission carries no signals and is **never folded**.

  `certification` (item 5, C1-6) is the bounded integrity tuple a GREEN verify
  emission carries — `%{head, tree_digest, mode}`, whitelist-decoded
  (`mode` crosses the boundary as `"working_tree"`/`"sealed"`; malformed →
  nil = no certification, which the composer reclassifies to an
  `{:inconclusive, "uncertified_green"}` before the fold). Always nil on
  worker emissions.

  `from_map/1` normalizes both shapes a wave return can arrive in — the
  atom-keyed live `{:ok, value, _run}` return and the string-keyed
  JSONB-round-tripped persisted map — into one struct, the same atom/string
  tolerance `JidoClaw.Orchestration.WorkflowEvent.Projection` applies
  (`projection.ex:19`).
  """

  alias JidoClaw.Orchestration.Verdict
  alias JidoClaw.RouteComposer.StageEmission

  @type outcome ::
          :ok | {:infra, String.t()} | {:inconclusive, String.t()} | {:tampered, String.t()}

  @type certification :: %{head: String.t(), tree_digest: String.t() | nil, mode: atom()} | nil

  @type t :: %__MODULE__{
          stage: String.t() | nil,
          signals: [String.t()],
          artifacts: %{optional(String.t()) => term()},
          outcome: outcome(),
          certification: certification()
        }

  defstruct stage: nil, signals: [], artifacts: %{}, outcome: :ok, certification: nil

  @certification_modes %{"working_tree" => :working_tree, "sealed" => :sealed}

  @doc """
  Normalize an atom- or string-keyed emission map into a `%StageEmission{}`.

  Tolerates both key styles for `stage` / `signals` / `artifacts` / `outcome`
  / `certification`; missing `signals` / `artifacts` default to `[]` / `%{}`.
  `outcome` decodes **fail-closed on the trust boundary** (the child
  `WorkflowRun.result` is DB data): absent — legacy rows and normal
  emissions — is `:ok`; a recognized `%{"kind" => "infra" | "inconclusive" |
  "tampered", "reason" => r}` decodes; **any other present value becomes
  `{:infra, _}`** so a malformed child result can never be folded as ran.
  `certification` decodes by whitelist (a binary `head`, a whitelisted
  string `mode`, and — for `"working_tree"` mode — a binary `tree_digest`);
  any malformed shape decodes to nil, never a partial certificate.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %StageEmission{
      stage: pick(map, :stage, "stage", nil),
      signals: pick(map, :signals, "signals", []),
      artifacts: pick(map, :artifacts, "artifacts", %{}),
      outcome: decode_outcome(pick(map, :outcome, "outcome", nil)),
      certification: decode_certification(pick(map, :certification, "certification", nil))
    }
  end

  # Atom key wins when present (live wave return); else the string key (persisted
  # round-trip); else the default.
  defp pick(map, atom_key, string_key, default) do
    case Map.get(map, atom_key) do
      nil -> Map.get(map, string_key, default)
      value -> value
    end
  end

  defp decode_outcome(nil), do: :ok

  defp decode_outcome(%{} = outcome) do
    kind = pick(outcome, :kind, "kind", nil)
    reason = pick(outcome, :reason, "reason", nil)

    case {decode_kind(kind), reason} do
      {{:ok, decoded}, reason} when is_binary(reason) -> {decoded, reason}
      _unrecognized -> unrecognized(outcome)
    end
  end

  defp decode_outcome(other), do: unrecognized(other)

  defp decode_kind(kind) when kind in [:infra, "infra"], do: {:ok, :infra}
  defp decode_kind(kind) when kind in [:inconclusive, "inconclusive"], do: {:ok, :inconclusive}
  defp decode_kind(kind) when kind in [:tampered, "tampered"], do: {:ok, :tampered}
  defp decode_kind(_kind), do: :error

  # Fail closed: an unrecognized present outcome is itself an infra exit, with
  # the offending value rendered bounded (`Verdict.format_reason/1`).
  defp unrecognized(value), do: {:infra, Verdict.format_reason({:unrecognized_outcome, value})}

  # Whitelist decode of the item-5 certification tuple: absent/malformed → nil
  # (no certificate — the composer's uncertified-green guard then applies).
  defp decode_certification(%{} = cert) do
    head = pick(cert, :head, "head", nil)
    digest = pick(cert, :tree_digest, "tree_digest", nil)
    mode = decode_mode(pick(cert, :mode, "mode", nil))

    case {head, digest, mode} do
      {head, digest, :working_tree} when is_binary(head) and is_binary(digest) ->
        %{head: head, tree_digest: digest, mode: :working_tree}

      {head, digest, :sealed} when is_binary(head) and (is_binary(digest) or is_nil(digest)) ->
        %{head: head, tree_digest: digest, mode: :sealed}

      _malformed ->
        nil
    end
  end

  defp decode_certification(_other), do: nil

  defp decode_mode(mode) when is_binary(mode), do: Map.get(@certification_modes, mode)
  defp decode_mode(mode) when mode in [:working_tree, :sealed], do: mode
  defp decode_mode(_mode), do: nil
end
