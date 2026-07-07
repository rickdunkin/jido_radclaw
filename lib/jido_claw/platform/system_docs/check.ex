defmodule JidoClaw.SystemDocs.Check do
  @moduledoc """
  Pure validator for the `docs/system/` documentation layer: per-page
  frontmatter + source-map contract, intra-corpus link resolution, the
  README's line-anchored index, and the bidirectional AGENTS.md pointer
  checks that machine-enforce the layer's atomicity rule (a page ships in
  the same change as the AGENTS.md bullet that cites it).

  `problems/1` returns human-readable drift descriptions prefixed with the
  offending file's repo-relative path; `[]` means in sync. Consumed by
  `mix jidoclaw.system_docs.check` (the precommit drift guard) over the
  committed corpus. All document paths are repo-relative
  (`docs/system/<page>.md`); the `:path_exists?` predicate receives
  repo-relative paths too.

  Index and pointer comparisons are name-**set** comparisons, not counts —
  a same-count rename is flagged in both directions. The parsers are public
  so tests can assert directly on what a document declares. Frontmatter
  type checks are deliberate about YAML retyping: an unquoted all-digit
  `verified_sha` parses as an integer, so the `is_binary` + hex-regex check
  mechanically forces quoting.
  """

  @typedoc "A corpus document: repo-relative path + file content."
  @type doc :: %{path: String.t(), content: String.t()}

  @required_keys ~w(type description sources verified)
  @types ~w(subsystem surface contract)

  # Virtual repo root for link containment: link targets are expanded
  # against it so a resolved path that leaves the prefix is an escape,
  # independent of the real filesystem layout.
  @virtual_root "/__jidoclaw_repo__"

  @doc """
  Validate the whole corpus. Options:

    * `:pages` — list of `t:doc/0` for every non-README page (required)
    * `:readme` — the `docs/system/README.md` document (required)
    * `:agents_md` — the full `AGENTS.md` content (required)
    * `:path_exists?` — arity-1 predicate for repo-relative paths
      (default `&File.exists?/1`; inject in tests)

  Runs per-page checks, link resolution over README + pages, the README
  index set-match, and the AGENTS.md pointer checks (both directions:
  every pointer resolves to a page, every page has an inbound pointer;
  the README is exempt from the inbound requirement).
  """
  @spec problems(keyword()) :: [String.t()]
  def problems(opts) do
    pages = Keyword.fetch!(opts, :pages)
    readme = Keyword.fetch!(opts, :readme)
    agents_md = Keyword.fetch!(opts, :agents_md)
    path_exists? = Keyword.get(opts, :path_exists?, &File.exists?/1)

    known_paths = MapSet.new([readme.path | Enum.map(pages, & &1.path)])

    Enum.flat_map(pages, &page_problems(&1, path_exists?)) ++
      Enum.flat_map([readme | pages], &link_problems(&1, known_paths, path_exists?)) ++
      index_problems(readme, pages) ++
      pointer_problems(agents_md, pages, readme)
  end

  @doc """
  Validate a single page: frontmatter present/terminated/parses/is-map
  (each a distinct fail-closed problem), required keys, `type` vocabulary,
  non-empty `description`, `sources` as a non-empty list of repo-relative
  existing paths (absolute/`~`-led and `..`-segment paths rejected),
  `verified` as `YYYY-MM-DD`, `verified_sha` (when present) as a quoted
  hex string, and a `## Source map` section with at least one backticked
  `path[:line]` entry.
  """
  @spec page_problems(doc(), (String.t() -> boolean())) :: [String.t()]
  def page_problems(%{path: path, content: content}, path_exists?) do
    case split_frontmatter(content) do
      {:ok, frontmatter, body} ->
        problems = frontmatter_problems(frontmatter, path_exists?) ++ source_map_problems(body)
        Enum.map(problems, &"#{path}: #{&1}")

      {:error, reason} ->
        ["#{path}: #{frontmatter_error(reason)}"]
    end
  end

  # ---------------------------------------------------------------------------
  # Public parsers (tests assert directly on these)
  # ---------------------------------------------------------------------------

  @doc """
  Split a page into its YAML frontmatter map and markdown body. The first
  line must be exactly `---`; the block runs to the next `---` line. Every
  failure mode is a distinct reason: `:missing`, `:unterminated`,
  `{:invalid_yaml, message}`, `:not_a_map`.
  """
  @spec split_frontmatter(String.t()) ::
          {:ok, map(), String.t()}
          | {:error, :missing | :unterminated | :not_a_map | {:invalid_yaml, String.t()}}
  def split_frontmatter(content) do
    case String.split(content, "\n") do
      ["---" | rest] -> split_frontmatter_block(rest)
      _no_opening -> {:error, :missing}
    end
  end

  @doc """
  Markdown link targets pointing at `.md` files: `http(s)://` URLs and
  pure `#anchor` links are excluded, `#anchor` suffixes are stripped, and
  fenced code blocks / inline code spans are stripped before scanning —
  quoted examples and backticked `path[:line]` source refs are not links.
  Deduplicated, in order of first appearance.
  """
  @spec doc_links(String.t()) :: [String.t()]
  def doc_links(content) do
    ~r/\[[^\]]*\]\(([^()\s]+)\)/
    |> Regex.scan(strip_code(content), capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&String.starts_with?(&1, ["http://", "https://", "#"]))
    |> Enum.map(&hd(String.split(&1, "#", parts: 2)))
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.uniq()
  end

  @doc """
  Page names declared by the README's line-anchored index entries
  (`- [Title](page.md) — description`) under the `## Index` heading.
  A missing heading returns `:error` (the caller fails closed).
  """
  @spec index_entries(String.t()) :: {:ok, [String.t()]} | :error
  def index_entries(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "## Index"))
    |> case do
      [] ->
        :error

      [_heading | rest] ->
        names =
          rest
          |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
          |> Enum.flat_map(&index_entry_name/1)

        {:ok, names}
    end
  end

  @doc """
  All `docs/system/<page>.md` pointer targets (as page basenames) in the
  hand-written region of AGENTS.md — content before
  `<!-- usage-rules-start -->`, or the whole file when the marker is
  absent. The slug pattern admits `README.md` (so the Documentation
  section's hub pointer is itself validated) and kebab-case page names;
  prose placeholders like `docs/system/<X>.md` can never match.
  """
  @spec agents_pointers(String.t()) :: [String.t()]
  def agents_pointers(content) do
    hand_written =
      content
      |> String.split("<!-- usage-rules-start -->", parts: 2)
      |> hd()

    ~r{docs/system/((?:README|[a-z0-9][a-z0-9-]*)\.md)}
    |> Regex.scan(hand_written, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # Fenced blocks first (an inline-span pass would eat fence delimiters),
  # then single-line inline spans. An unterminated fence stays visible to
  # the link scan — failing toward checking, never toward skipping.
  defp strip_code(content) do
    content
    |> String.replace(~r/```.*?```/s, " ")
    |> String.replace(~r/`[^`\n]*`/, " ")
  end

  # ---------------------------------------------------------------------------
  # Frontmatter checks
  # ---------------------------------------------------------------------------

  defp split_frontmatter_block(lines) do
    case Enum.split_while(lines, &(&1 != "---")) do
      {_yaml, []} ->
        {:error, :unterminated}

      {yaml_lines, [_closing | body]} ->
        decode_frontmatter(Enum.join(yaml_lines, "\n"), Enum.join(body, "\n"))
    end
  end

  defp decode_frontmatter(yaml, body) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, frontmatter} when is_map(frontmatter) -> {:ok, frontmatter, body}
      {:ok, _not_a_map} -> {:error, :not_a_map}
      {:error, error} -> {:error, {:invalid_yaml, Exception.message(error)}}
    end
  end

  defp frontmatter_error(:missing), do: "missing frontmatter (file must start with `---`)"
  defp frontmatter_error(:unterminated), do: "unterminated frontmatter (no closing `---`)"
  defp frontmatter_error(:not_a_map), do: "frontmatter is not a mapping"

  defp frontmatter_error({:invalid_yaml, message}),
    do: "frontmatter is not valid YAML: #{message}"

  defp frontmatter_problems(frontmatter, path_exists?) do
    missing_key_problems(frontmatter) ++
      type_problems(frontmatter) ++
      description_problems(frontmatter) ++
      sources_problems(frontmatter, path_exists?) ++
      verified_problems(frontmatter) ++
      verified_sha_problems(frontmatter)
  end

  defp missing_key_problems(frontmatter) do
    for key <- @required_keys, not Map.has_key?(frontmatter, key) do
      "frontmatter missing required key: #{key}"
    end
  end

  defp type_problems(frontmatter) do
    case Map.fetch(frontmatter, "type") do
      :error ->
        []

      {:ok, type} when type in @types ->
        []

      {:ok, other} ->
        [
          "frontmatter `type` must be one of subsystem | surface | contract, got: #{inspect(other)}"
        ]
    end
  end

  defp description_problems(frontmatter) do
    case Map.fetch(frontmatter, "description") do
      :error ->
        []

      {:ok, description} ->
        if valid_description?(description),
          do: [],
          else: ["frontmatter `description` must be a non-empty string"]
    end
  end

  defp valid_description?(description),
    do: is_binary(description) and String.trim(description) != ""

  defp sources_problems(frontmatter, path_exists?) do
    case Map.fetch(frontmatter, "sources") do
      :error ->
        []

      {:ok, sources} when is_list(sources) and sources != [] ->
        Enum.flat_map(sources, &source_path_problems(&1, path_exists?))

      {:ok, _not_a_list} ->
        ["frontmatter `sources` must be a non-empty list of repo-relative paths"]
    end
  end

  defp source_path_problems(source, path_exists?) do
    cond do
      not is_binary(source) ->
        ["frontmatter `sources` entry must be a string: #{inspect(source)}"]

      String.starts_with?(source, ["/", "~"]) ->
        ["frontmatter `sources` path must be repo-relative: #{source}"]

      ".." in Path.split(source) ->
        ["frontmatter `sources` path must not contain `..`: #{source}"]

      not path_exists?.(source) ->
        ["frontmatter `sources` path does not exist: #{source}"]

      true ->
        []
    end
  end

  defp verified_problems(frontmatter) do
    case Map.fetch(frontmatter, "verified") do
      :error ->
        []

      {:ok, verified} ->
        if valid_date?(verified),
          do: [],
          else: ["frontmatter `verified` must be a YYYY-MM-DD date string"]
    end
  end

  defp valid_date?(verified),
    do: is_binary(verified) and Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, verified)

  defp verified_sha_problems(frontmatter) do
    case Map.fetch(frontmatter, "verified_sha") do
      :error ->
        []

      {:ok, sha} ->
        if valid_sha?(sha),
          do: [],
          else: [
            "frontmatter `verified_sha` must be a quoted hex string (7-40 lowercase hex chars)"
          ]
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^[0-9a-f]{7,40}$/, sha)

  # ---------------------------------------------------------------------------
  # Source map check
  # ---------------------------------------------------------------------------

  defp source_map_problems(body) do
    body
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "## Source map"))
    |> case do
      [] ->
        ["missing `## Source map` section"]

      [_heading | rest] ->
        rest
        |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
        |> source_map_entry_problems()
    end
  end

  defp source_map_entry_problems(section_lines) do
    if Enum.any?(section_lines, &source_map_entry?/1) do
      []
    else
      ["`## Source map` section has no backticked `path[:line]` entries"]
    end
  end

  # A backticked token containing a `/` (optionally suffixed `:line`) is
  # the evidence floor — the heading alone is not evidence.
  defp source_map_entry?(line), do: Regex.match?(~r{`[^`\s]*/[^`\s]*`}, line)

  # ---------------------------------------------------------------------------
  # Link resolution
  # ---------------------------------------------------------------------------

  defp link_problems(doc, known_paths, path_exists?) do
    doc.content
    |> doc_links()
    |> Enum.flat_map(&link_problem(doc, &1, known_paths, path_exists?))
  end

  defp link_problem(doc, target, known_paths, path_exists?) do
    resolved = Path.expand(target, Path.join(@virtual_root, Path.dirname(doc.path)))

    case strip_virtual_root(resolved) do
      :escape ->
        ["#{doc.path}: link escapes the repo root: #{target}"]

      {:ok, repo_path} ->
        resolved_link_problem(doc, target, repo_path, known_paths, path_exists?)
    end
  end

  defp strip_virtual_root(resolved) do
    prefix = @virtual_root <> "/"

    if String.starts_with?(resolved, prefix) do
      {:ok, String.replace_prefix(resolved, prefix, "")}
    else
      :escape
    end
  end

  defp resolved_link_problem(doc, target, repo_path, known_paths, path_exists?) do
    cond do
      not String.starts_with?(repo_path, "docs/system/") ->
        if path_exists?.(repo_path),
          do: [],
          else: ["#{doc.path}: broken link: #{target} (file does not exist)"]

      MapSet.member?(known_paths, repo_path) ->
        []

      true ->
        ["#{doc.path}: broken link: #{target} (no such page in docs/system/)"]
    end
  end

  # ---------------------------------------------------------------------------
  # Index set-match (names, not counts — a same-count rename yields both)
  # ---------------------------------------------------------------------------

  defp index_problems(readme, pages) do
    case index_entries(readme.content) do
      :error ->
        ["#{readme.path}: missing `## Index` heading"]

      {:ok, listed} ->
        page_names =
          pages
          |> Enum.map(&Path.basename(&1.path))
          |> Enum.sort()

        listed = Enum.sort(listed)

        missing_problem(readme, page_names -- listed) ++
          unexpected_problem(readme, listed -- page_names)
    end
  end

  defp missing_problem(_readme, []), do: []

  defp missing_problem(readme, names),
    do: ["#{readme.path}: index missing: #{Enum.join(names, ", ")}"]

  defp unexpected_problem(_readme, []), do: []

  defp unexpected_problem(readme, names),
    do: ["#{readme.path}: index unexpected: #{Enum.join(names, ", ")}"]

  defp index_entry_name(line) do
    case Regex.run(~r/^- \[[^\]]+\]\(([^)]+\.md)\) — /u, line, capture: :all_but_first) do
      [name] -> [name]
      nil -> []
    end
  end

  # ---------------------------------------------------------------------------
  # AGENTS.md pointer checks (both directions — the machine-enforced
  # atomicity rule: a shrunk bullet without its page breaks direction one,
  # a page without its shrunk bullet breaks direction two)
  # ---------------------------------------------------------------------------

  defp pointer_problems(agents_md, pages, readme) do
    pointers = agents_pointers(agents_md)
    known = [Path.basename(readme.path) | Enum.map(pages, &Path.basename(&1.path))]

    broken =
      for target <- pointers, target not in known do
        "AGENTS.md: pointer to nonexistent page: docs/system/#{target}"
      end

    unreferenced =
      for page <- pages, Path.basename(page.path) not in pointers do
        "#{page.path}: page never referenced from AGENTS.md"
      end

    broken ++ unreferenced
  end
end
