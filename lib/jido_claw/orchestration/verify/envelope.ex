defmodule JidoClaw.Orchestration.Verify.Envelope do
  @moduledoc """
  The verify verdict envelope (camus C1-2's `{pass, inconclusive, tampered,
  failures, checks}` contract plus our extensions: `head`, `integrity_note`,
  `mode`, `tree_digest`, `sealed_head`).

  `to_map/1` / `from_map/1` round-trip through the JSONB boundary with string
  keys and string enums (`kind`, `mode` — atoms never cross; the
  `feedback_pin_types_at_ash_persistence_boundaries` rule). `from_map/1` is
  **total and fail-closed**: any non-map or undecodable input yields the
  never-pass sentinel (`pass: false, inconclusive: true`), and the boolean
  fields decode `true` ONLY from the literal `true` — garbage can never decode
  to a pass, a certified green, or a silent non-tamper.
  """

  # The shared atom-key-wins/string-key-fallback map read lives on Verdict
  # (the projection idiom) — single-sourced, never re-cloned per module.
  alias JidoClaw.Orchestration.Verdict
  alias JidoClaw.Orchestration.Verify.Envelope

  @type failure :: %{
          stage: String.t() | nil,
          kind: String.t() | nil,
          log_tail: String.t() | nil,
          exit: integer() | nil,
          reason: String.t() | nil
        }

  @type check :: %{name: String.t() | nil, cmd: [String.t()], exit: integer() | nil}

  @type mode :: :working_tree | :sealed

  @type t :: %__MODULE__{
          pass: boolean(),
          inconclusive: boolean(),
          tampered: boolean(),
          failures: [failure()],
          checks: [check()],
          head: String.t() | nil,
          integrity_note: String.t() | nil,
          mode: mode(),
          tree_digest: String.t() | nil,
          sealed_head: String.t() | nil
        }

  defstruct pass: false,
            inconclusive: false,
            tampered: false,
            failures: [],
            checks: [],
            head: nil,
            integrity_note: nil,
            mode: :working_tree,
            tree_digest: nil,
            sealed_head: nil

  @modes %{"working_tree" => :working_tree, "sealed" => :sealed}

  @doc """
  The canonical failure-entry constructor — the ONE construction site for the
  `{stage, kind, log_tail, exit, reason}` shape (used by `Verify.build_result/2`,
  the decode path, and the sentinel).
  """
  @spec failure(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          integer() | nil,
          String.t() | nil
        ) ::
          failure()
  def failure(stage, kind, log_tail, exit \\ nil, reason \\ nil) do
    %{stage: stage, kind: kind, log_tail: log_tail, exit: exit, reason: reason}
  end

  @doc "Serialize to the JSON-safe, string-keyed map form (the stored report shape)."
  @spec to_map(t()) :: map()
  def to_map(%Envelope{} = envelope) do
    %{
      "pass" => envelope.pass,
      "inconclusive" => envelope.inconclusive,
      "tampered" => envelope.tampered,
      "failures" => Enum.map(envelope.failures, &failure_to_map/1),
      "checks" => Enum.map(envelope.checks, &check_to_map/1),
      "head" => envelope.head,
      "integrity_note" => envelope.integrity_note,
      "mode" => Atom.to_string(envelope.mode),
      "tree_digest" => envelope.tree_digest,
      "sealed_head" => envelope.sealed_head
    }
  end

  @doc """
  Rebuild an envelope from its map form. Total + fail-closed: a non-map input
  (or one whose `mode` fails the whitelist) returns the never-pass sentinel;
  the booleans decode `true` only from the literal `true`.
  """
  @spec from_map(term()) :: t()
  def from_map(map) when is_map(map) do
    case decode_mode(Verdict.field(map, :mode)) do
      {:ok, mode} ->
        %Envelope{
          pass: Verdict.field(map, :pass) == true,
          inconclusive: Verdict.field(map, :inconclusive) == true,
          tampered: Verdict.field(map, :tampered) == true,
          failures: decode_list(Verdict.field(map, :failures), &failure_from_map/1),
          checks: decode_list(Verdict.field(map, :checks), &check_from_map/1),
          head: binary_or_nil(Verdict.field(map, :head)),
          integrity_note: binary_or_nil(Verdict.field(map, :integrity_note)),
          mode: mode,
          tree_digest: binary_or_nil(Verdict.field(map, :tree_digest)),
          sealed_head: binary_or_nil(Verdict.field(map, :sealed_head))
        }

      :error ->
        decode_failed()
    end
  end

  def from_map(_other), do: decode_failed()

  # The never-pass sentinel: pass false, inconclusive true, an
  # `integrity_unavailable` failure naming the decode — never a green, never a
  # silent skip.
  defp decode_failed do
    %Envelope{
      pass: false,
      inconclusive: true,
      tampered: false,
      failures: [
        failure(
          "envelope",
          "integrity_unavailable",
          "verify envelope failed to decode; treating as inconclusive",
          nil,
          "decode_failed"
        )
      ],
      checks: [],
      mode: :working_tree
    }
  end

  defp failure_to_map(failure) do
    %{
      "stage" => failure.stage,
      "kind" => failure.kind,
      "log_tail" => failure.log_tail,
      "exit" => failure.exit,
      "reason" => failure.reason
    }
  end

  defp failure_from_map(map) when is_map(map) do
    failure(
      binary_or_nil(Verdict.field(map, :stage)),
      binary_or_nil(Verdict.field(map, :kind)),
      binary_or_nil(Verdict.field(map, :log_tail)),
      int_or_nil(Verdict.field(map, :exit)),
      binary_or_nil(Verdict.field(map, :reason))
    )
  end

  defp failure_from_map(_other), do: nil

  defp check_to_map(check) do
    %{"name" => check.name, "cmd" => check.cmd, "exit" => check.exit}
  end

  defp check_from_map(map) when is_map(map) do
    %{
      name: binary_or_nil(Verdict.field(map, :name)),
      cmd: string_list(Verdict.field(map, :cmd)),
      exit: int_or_nil(Verdict.field(map, :exit))
    }
  end

  defp check_from_map(_other), do: nil

  # Absent mode (a legacy/partial map) defaults to :working_tree; a PRESENT
  # non-whitelisted value fails the whole decode (never a kept string).
  defp decode_mode(nil), do: {:ok, :working_tree}
  defp decode_mode(value) when is_binary(value), do: Map.fetch(@modes, value)
  defp decode_mode(_value), do: :error

  defp decode_list(list, decoder) when is_list(list) do
    list
    |> Enum.map(decoder)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_list(_other, _decoder), do: []

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_value), do: nil
end
