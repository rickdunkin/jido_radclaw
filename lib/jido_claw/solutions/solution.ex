defmodule JidoClaw.Solutions.Solution do
  @moduledoc """
  Data struct representing a coding solution.

  Fields:
    - `id`                 — UUID v4, generated on `new/1` when absent
    - `problem_signature`  — SHA-256 hex digest of normalised problem description + language + framework
    - `solution_content`   — Full solution text / code
    - `language`           — e.g. "elixir", "python", "typescript"
    - `framework`          — Optional framework name (e.g. "phoenix", "django")
    - `runtime`            — Optional runtime hint (e.g. "otp-26", "node-20")
    - `agent_id`           — ID of the agent that produced this solution
    - `tags`               — List of string tags for faceted search
    - `verification`       — Map of verification results, e.g. `%{tests_passed: true, lint: :ok}`
    - `trust_score`        — Float 0.0–1.0; higher means more trustworthy
    - `sharing`            — `:local` | `:shared` | `:public` visibility level
    - `inserted_at`        — ISO-8601 UTC string
    - `updated_at`         — ISO-8601 UTC string
  """

  @enforce_keys [:problem_signature, :solution_content, :language]

  defstruct [
    :id,
    :problem_signature,
    :solution_content,
    :language,
    :framework,
    :runtime,
    :agent_id,
    tags: [],
    verification: %{},
    trust_score: 0.0,
    sharing: :local,
    inserted_at: nil,
    updated_at: nil
  ]

  @type sharing :: :local | :shared | :public

  @type t :: %__MODULE__{
          id: String.t() | nil,
          problem_signature: String.t(),
          solution_content: String.t(),
          language: String.t(),
          framework: String.t() | nil,
          runtime: String.t() | nil,
          agent_id: String.t() | nil,
          tags: [String.t()],
          verification: map(),
          trust_score: float(),
          sharing: sharing(),
          inserted_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Build a `%Solution{}` from an attribute map.

  - Generates a UUID when `:id` / `"id"` is absent.
  - Derives `problem_signature` via `signature/3` when absent.
  - Stamps `inserted_at` and `updated_at` when absent.

  Accepts both atom and string keys.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    language = Map.fetch!(attrs, :language)
    framework = Map.get(attrs, :framework)
    solution_content = Map.fetch!(attrs, :solution_content)

    problem_signature =
      Map.get(attrs, :problem_signature) ||
        signature(solution_content, language, framework)

    now = utc_now_iso()

    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      problem_signature: problem_signature,
      solution_content: solution_content,
      language: language,
      framework: framework,
      runtime: Map.get(attrs, :runtime),
      agent_id: Map.get(attrs, :agent_id),
      tags: coerce_tags(Map.get(attrs, :tags, [])),
      verification: coerce_map(Map.get(attrs, :verification, %{})),
      trust_score: coerce_float(Map.get(attrs, :trust_score, 0.0)),
      sharing: coerce_sharing(Map.get(attrs, :sharing, :local)),
      inserted_at: Map.get(attrs, :inserted_at) || now,
      updated_at: Map.get(attrs, :updated_at) || now
    }
  end

  @doc """
  Convert a `%Solution{}` to a plain map suitable for JSON serialisation.

  Tags and verification are kept as-is (lists and maps).
  Sharing is serialised to a string.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = s) do
    %{
      "id" => s.id,
      "problem_signature" => s.problem_signature,
      "solution_content" => s.solution_content,
      "language" => s.language,
      "framework" => s.framework,
      "runtime" => s.runtime,
      "agent_id" => s.agent_id,
      "tags" => s.tags,
      "verification" => stringify_keys(s.verification),
      "trust_score" => s.trust_score,
      "sharing" => to_string(s.sharing),
      "inserted_at" => s.inserted_at,
      "updated_at" => s.updated_at
    }
  end

  @doc """
  Reconstruct a `%Solution{}` from a stored map (atom or string keys).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs = normalize_keys(map)

    %__MODULE__{
      id: Map.get(attrs, :id),
      problem_signature: Map.get(attrs, :problem_signature, ""),
      solution_content: Map.get(attrs, :solution_content, ""),
      language: Map.get(attrs, :language, ""),
      framework: Map.get(attrs, :framework),
      runtime: Map.get(attrs, :runtime),
      agent_id: Map.get(attrs, :agent_id),
      tags: coerce_tags(Map.get(attrs, :tags, [])),
      verification: coerce_map(Map.get(attrs, :verification, %{})),
      trust_score: coerce_float(Map.get(attrs, :trust_score, 0.0)),
      sharing: coerce_sharing(Map.get(attrs, :sharing, :local)),
      inserted_at: Map.get(attrs, :inserted_at),
      updated_at: Map.get(attrs, :updated_at)
    }
  end

  # ---------------------------------------------------------------------------
  # Signature derivation
  # ---------------------------------------------------------------------------

  @doc """
  Derive a deterministic SHA-256 hex digest from a problem description,
  language, and optional framework.

  The input is lowercased and stripped before hashing so that trivially
  different phrasings of the same problem yield the same signature.
  """
  @spec signature(String.t(), String.t(), String.t() | nil) :: String.t()
  def signature(description, language, framework \\ nil) do
    JidoClaw.Solutions.Fingerprint.signature(description, language, framework)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_id do
    <<a::32, b::16, _::4, c::12, _::2, d::30, e::32>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::30, e::32>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ]
      |> Enum.join("-")
    end)
  end

  defp utc_now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @known_keys ~w(id problem_signature solution_content language framework
    runtime agent_id tags verification trust_score sharing inserted_at updated_at)a
              |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {Map.get(@known_keys, k, k), v}
    end)
  end

  defp coerce_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp coerce_tags(_), do: []

  defp coerce_map(map) when is_map(map), do: map

  defp coerce_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp coerce_map(_), do: %{}

  defp coerce_float(v) when is_float(v), do: v
  defp coerce_float(v) when is_integer(v), do: v / 1

  defp coerce_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp coerce_float(_), do: 0.0

  defp coerce_sharing(:local), do: :local
  defp coerce_sharing(:shared), do: :shared
  defp coerce_sharing(:public), do: :public
  defp coerce_sharing("local"), do: :local
  defp coerce_sharing("shared"), do: :shared
  defp coerce_sharing("public"), do: :public
  defp coerce_sharing(_), do: :local

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
