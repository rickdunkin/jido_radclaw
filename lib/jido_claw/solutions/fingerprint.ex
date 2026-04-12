defmodule JidoClaw.Solutions.Fingerprint do
  @moduledoc """
  Pure functional module for creating structured fingerprints from coding problem descriptions.

  A fingerprint captures the structural facets of a problem — domain, target,
  ecosystem, error class — and a SHA-256 signature that enables exact-match
  deduplication. Two fingerprints can be compared with `match_score/2` to
  produce a similarity float suitable for fuzzy matching.
  """

  defstruct [
    :signature,
    :domain,
    :target,
    :error_class,
    :ecosystem,
    :versions,
    :search_terms,
    :raw_description
  ]

  @type t :: %__MODULE__{
          signature: String.t(),
          domain: String.t() | nil,
          target: String.t() | nil,
          error_class: String.t() | nil,
          ecosystem: [String.t()],
          versions: %{String.t() => String.t()},
          search_terms: [String.t()],
          raw_description: String.t()
        }

  @stopwords ~w(
    the a an is are was were be been being have has had do does did
    will would could should can may might shall must need
    in on at to for of with by from as into
    it its this that these those i my me we our
    not no or and but if then else when how what which who where why
  )

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate a `Fingerprint` struct from a problem description.

  ## Options

    * `:language`    - primary language string, e.g. `"elixir"`
    * `:framework`   - framework string, e.g. `"phoenix"`
    * `:error_class` - one of `"runtime"`, `"compile"`, `"type"`, `"logic"`, etc.
    * `:ecosystem`   - list of technology strings, e.g. `["elixir", "phoenix", "ecto"]`
    * `:versions`    - map of component versions, e.g. `%{"elixir" => "1.17"}`
  """
  @spec generate(String.t(), keyword()) :: t()
  def generate(problem_description, opts \\ []) when is_binary(problem_description) do
    language = Keyword.get(opts, :language, "")
    framework = Keyword.get(opts, :framework, nil)
    error_class = Keyword.get(opts, :error_class, nil)
    ecosystem = Keyword.get(opts, :ecosystem, [])
    versions = Keyword.get(opts, :versions, %{})

    %__MODULE__{
      signature: signature(problem_description, language, framework),
      domain: extract_domain(problem_description),
      target: extract_target(problem_description),
      error_class: error_class,
      ecosystem: ecosystem,
      versions: versions,
      search_terms: extract_search_terms(problem_description),
      raw_description: problem_description
    }
  end

  @doc """
  Compute a SHA-256 hex signature for the given description, language, and optional framework.

  The input is normalized (downcased, trimmed, whitespace collapsed) before hashing.
  """
  @spec signature(String.t(), String.t(), String.t() | nil) :: String.t()
  def signature(description, language, framework \\ nil)
      when is_binary(description) and is_binary(language) do
    normalized = normalize(description)
    lang = language |> String.downcase() |> String.trim()
    fw = (framework || "") |> String.downcase() |> String.trim()
    data = "#{normalized}|#{lang}|#{fw}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  @doc """
  Infer a broad domain label from the problem description using keyword pattern matching.

  Returns one of: `"web"`, `"database"`, `"api"`, `"cli"`, `"devops"`, `"testing"`, or `nil`.
  """
  @spec extract_domain(String.t()) :: String.t() | nil
  def extract_domain(description) when is_binary(description) do
    lower = String.downcase(description)

    cond do
      contains_any?(lower, ~w(route http request response endpoint cors cookie session)) ->
        "web"

      contains_any?(lower, ~w(query sql migration schema table index join)) ->
        "database"

      contains_any?(lower, ~w(api rest graphql grpc endpoint webhook)) ->
        "api"

      contains_any?(lower, ~w(command terminal argument flag stdin stdout)) ->
        "cli"

      contains_any?(lower, ~w(deploy docker ci pipeline kubernetes terraform)) ->
        "devops"

      contains_any?(lower, ~w(test spec mock assert fixture)) ->
        "testing"

      true ->
        nil
    end
  end

  @doc """
  Infer a specific target area from the problem description using keyword pattern matching.

  Returns a target label string or `nil` when no pattern matches.
  """
  @spec extract_target(String.t()) :: String.t() | nil
  def extract_target(description) when is_binary(description) do
    lower = String.downcase(description)

    cond do
      contains_any?(lower, ~w(login logout signup register password credential token jwt auth)) ->
        "authentication"

      contains_any?(lower, ~w(permission role access authorize policy rbac)) ->
        "authorization"

      contains_any?(lower, ~w(route router routing path redirect plug middleware)) ->
        "routing"

      contains_any?(lower, ~w(deploy deployment release build artifact docker image container)) ->
        "deployment"

      contains_any?(lower, ~w(migration migrate schema alter table column)) ->
        "migrations"

      contains_any?(lower, ~w(cache caching redis memcached ets ttl)) ->
        "caching"

      contains_any?(lower, ~w(test spec mock stub assertion coverage)) ->
        "testing"

      contains_any?(lower, ~w(performance slow timeout latency throughput bottleneck)) ->
        "performance"

      contains_any?(lower, ~w(parse parsing parse json xml yaml csv binary)) ->
        "parsing"

      contains_any?(lower, ~w(connect connection pool socket websocket channel)) ->
        "networking"

      true ->
        nil
    end
  end

  @doc """
  Tokenize a problem description into deduplicated, sorted semantic search terms.

  Stopwords and tokens shorter than 3 characters are removed.
  """
  @spec extract_search_terms(String.t()) :: [String.t()]
  def extract_search_terms(description) when is_binary(description) do
    description
    |> String.downcase()
    |> String.split(~r/[\s\p{P}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Compute a similarity score between two fingerprints in the range `0.0..1.0`.

  An exact signature match returns `1.0` immediately. Otherwise a weighted
  combination of structural facet matches and Jaccard similarities is returned:

    * domain match:              0.20
    * target match:              0.15
    * error_class match:         0.10
    * ecosystem Jaccard:         0.25
    * search_terms Jaccard:      0.30
  """
  @spec match_score(t(), t()) :: float()
  def match_score(%__MODULE__{} = a, %__MODULE__{} = b) do
    if a.signature == b.signature do
      1.0
    else
      domain_score = if a.domain == b.domain and not is_nil(a.domain), do: 0.20, else: 0.0
      target_score = if a.target == b.target and not is_nil(a.target), do: 0.15, else: 0.0

      error_class_score =
        if a.error_class == b.error_class and not is_nil(a.error_class), do: 0.10, else: 0.0

      ecosystem_score = 0.25 * jaccard(a.ecosystem, b.ecosystem)
      terms_score = 0.30 * jaccard(a.search_terms, b.search_terms)

      domain_score + target_score + error_class_score + ecosystem_score + terms_score
    end
  end

  @doc """
  Compute Jaccard similarity between two lists: `|intersection| / |union|`.

  Returns `0.0` when both lists are empty.
  """
  @spec jaccard([term()], [term()]) :: float()
  def jaccard(list1, list2) do
    set1 = MapSet.new(list1)
    set2 = MapSet.new(list2)

    union_size = MapSet.union(set1, set2) |> MapSet.size()

    if union_size == 0 do
      0.0
    else
      intersection_size = MapSet.intersection(set1, set2) |> MapSet.size()
      intersection_size / union_size
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp contains_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end
end
