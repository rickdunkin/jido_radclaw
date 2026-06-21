defmodule JidoClaw.Triage.Verdict do
  @moduledoc """
  The AR-8 triage result (AR-2 §8/§14): exactly one *path* the front door routes
  on — `talk` (answer inline) / `sketch` (throwaway) / `code` (a reviewed change)
  / `system` (a machine change) — plus advisory early signals, an `est_size`, the
  distilled `intent`, and `intent_confirmed?`.

  This struct is the durable contract between the LLM classifier and
  `JidoClaw.FrontDoor`. It carries **no `@enforce_keys`** on purpose: the
  `path: :talk` default is the fail-safe shape (the status-quo-safe inline path),
  so a coerced fallback verdict (`talk/0`) is always well-formed.

  `from_map/1` normalizes a (string- or atom-keyed) map — the shape
  `Jido.AI.generate_object/3` returns after `ReqLLM.Response.unwrap_object/2` — at
  the boundary, validating the path against a fixed whitelist (never
  `String.to_atom/1`). A **malformed** output (bad/absent path) returns
  `{:error, :invalid_verdict}` so the façade can *count* it as a fallback rather
  than silently emit a real `talk`; a model that genuinely said `"talk"` is
  `{:ok, talk-verdict}` (correctly **not** a fallback).
  """

  @type path :: :talk | :sketch | :code | :system

  @type t :: %__MODULE__{
          path: path(),
          signals: [atom()],
          est_size: atom() | nil,
          intent: String.t() | nil,
          intent_confirmed?: boolean(),
          reasons: %{optional(String.t()) => String.t()}
        }

  defstruct path: :talk,
            signals: [],
            est_size: nil,
            intent: nil,
            intent_confirmed?: false,
            reasons: %{}

  # Fixed whitelists — the only place a model-generated string becomes an atom.
  # Unknown values map to nil (dropped), never `String.to_atom/1` (memory-leak
  # risk on adversarial output).
  @paths %{"talk" => :talk, "sketch" => :sketch, "code" => :code, "system" => :system}

  @signals %{
    "ambiguous" => :ambiguous,
    "bug" => :bug,
    "novel-domain" => :novel_domain,
    "multi-file" => :multi_file,
    "auth-surface" => :auth_surface,
    "secrets" => :secrets,
    "perms-change" => :perms_change,
    "destructive-op" => :destructive_op,
    "irreversible" => :irreversible,
    "needs-tests" => :needs_tests,
    "significant-build" => :significant_build,
    "scope-shift" => :scope_shift
  }

  @sizes %{"XS" => :xs, "S" => :s, "M" => :m, "L" => :l, "XL" => :xl, "XXL" => :xxl}

  @doc "The fail-safe verdict: `talk`, optionally carrying a distilled `intent`."
  @spec talk(String.t() | nil) :: t()
  def talk(intent \\ nil), do: %__MODULE__{path: :talk, intent: intent}

  @doc "True when the verdict routes into the composer (`code` or `system`)."
  @spec composer?(t()) :: boolean()
  def composer?(%__MODULE__{path: p}), do: p in [:code, :system]

  @doc """
  Normalize a structured-output map (string- or atom-keyed) into a `%Verdict{}`.

  Returns `{:ok, verdict}` for a valid path, or `{:error, :invalid_verdict}` when
  the path is absent or unknown (a distinguishable, *countable* malformed output —
  R6-P2). Enum fields use the explicit whitelists above; unknown enum members are
  dropped (signals) or nil'd (`est_size`).
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, :invalid_verdict}
  def from_map(%{} = out) do
    case @paths[to_string(get(out, :path))] do
      nil ->
        {:error, :invalid_verdict}

      path ->
        {:ok,
         %__MODULE__{
           path: path,
           signals: norm_signals(get(out, :signals)),
           est_size: norm_size(get(out, :est_size)),
           intent: norm_intent(get(out, :intent)),
           intent_confirmed?: get(out, :intent_confirmed) == true,
           reasons: norm_reasons(get(out, :reasons))
         }}
    end
  end

  def from_map(_other), do: {:error, :invalid_verdict}

  # Atom key wins, else string key (the projection.ex idiom) — tolerates both the
  # string-keyed JSON `generate_object` returns and atom-keyed synthetic test maps.
  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp norm_signals(list) when is_list(list) do
    list
    |> Enum.map(fn signal -> @signals[to_string(signal)] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp norm_signals(_other), do: []

  defp norm_size(nil), do: nil
  defp norm_size(size), do: @sizes[String.upcase(to_string(size))]

  defp norm_intent(intent) when is_binary(intent), do: intent
  defp norm_intent(_other), do: nil

  # Model-generated keys/values — keep them STRING-keyed (never atomized, R5-P3).
  defp norm_reasons(reasons) when is_map(reasons) do
    Map.new(reasons, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp norm_reasons(_other), do: %{}
end
