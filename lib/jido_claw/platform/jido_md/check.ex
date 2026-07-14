defmodule JidoClaw.JidoMd.Check do
  @moduledoc """
  Pure validator for a `.jido/JIDO.md` document against the platform's
  registered truth (version, tool names, template names, skill names).

  `problems/2` returns human-readable drift descriptions; `[]` means in sync.
  Consumed by `mix jidoclaw.jido_md.check` (the precommit drift guard for the
  committed `.jido/JIDO.md`) and by the generator round-trip test, which pins
  the invariant that fresh `JidoClaw.JidoMd.generate/1` output always passes.

  All comparisons over lists are name-**set** comparisons, not counts — a
  same-count rename or paired add/remove is still flagged. The parsers are
  public so tests can assert directly on what a document declares.
  """

  @doc """
  Validate `content` (JIDO.md text) against expected values.

  Options (all required except `:path_exists?`):

    * `:version` — expected `- **Version**:` value
    * `:tool_names` — expected tool name set (the `## Tools` section)
    * `:template_names` — expected template detail-header set (all templates)
    * `:spawnable_names` — expected names on the `Available template names:` line(s)
    * `:skill_names` — expected built-in skill name set (the `## Skills` section)
    * `:framework_names` — expected `- **Frameworks**:` label set (derive via
      `JidoClaw.JidoMd.framework_names/1`; `[]` means the line must be absent)
    * `:custom_skills_fragment` — the generator's `### Custom Skills` section
      (`JidoClaw.JidoMd.custom_skills_section/0`), byte-compared against the
      document's section (trailing blank lines trimmed on both sides) — the
      `system_prompt.check` precedent, scoped to the generated FRAGMENT only
      so the operator-editable Architecture/Conventions sections stay free
    * `:path_exists?` — arity-1 predicate for Entry points paths
      (default `&File.exists?/1`; inject to bind paths to a tmp dir in tests)
  """
  @spec problems(String.t(), keyword()) :: [String.t()]
  def problems(content, opts) do
    tool_names = Keyword.fetch!(opts, :tool_names)

    []
    |> check_version(content, Keyword.fetch!(opts, :version))
    |> check_tool_count(content, tool_names)
    |> check_name_set(tool_names_in_section(content), tool_names, "Tools section")
    |> check_name_set(
      template_names_in_detail(content),
      Keyword.fetch!(opts, :template_names),
      "Agent Templates detail headers"
    )
    |> check_name_set(
      template_names_in_summary(content),
      Keyword.fetch!(opts, :spawnable_names),
      "Available template names line"
    )
    |> check_name_set(
      skill_names_in_section(content),
      Keyword.fetch!(opts, :skill_names),
      "Skills section"
    )
    |> check_name_set(
      framework_names_in_doc(content),
      Keyword.fetch!(opts, :framework_names),
      "Frameworks line"
    )
    |> check_custom_skills_fragment(content, Keyword.fetch!(opts, :custom_skills_fragment))
    |> check_no_machine_path(content)
    |> check_entry_points(content, Keyword.get(opts, :path_exists?, &File.exists?/1))
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Public parsers (tests assert directly on these)
  # ---------------------------------------------------------------------------

  @doc """
  Tool names declared in the `## Tools (N total)` section: the first
  backticked token of each line-anchored entry (`- \`name\`` bullet or
  `| \`name\` |` table row). Scope ends at the next `## ` heading — `###`
  subsections inside the section do not end it.
  """
  @spec tool_names_in_section(String.t()) :: [String.t()]
  def tool_names_in_section(content) do
    content
    |> section_lines(&String.starts_with?(&1, "## Tools ("))
    |> Enum.flat_map(&first_backticked_token/1)
  end

  @doc """
  Template names declared as detail headers (`### \`name\``) inside the
  `## Agent Templates` section.
  """
  @spec template_names_in_detail(String.t()) :: [String.t()]
  def template_names_in_detail(content) do
    content
    |> section_lines(&(&1 == "## Agent Templates"))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^### `([a-z0-9_]+)`$/, line, capture: :all_but_first) do
        [name] -> [name]
        nil -> []
      end
    end)
  end

  @doc """
  Template names on the `Available template names:` line — including wrapped
  continuation lines (the pre-fix generator wrapped the list), stopping at a
  blank line or the `Composer-internal` line.
  """
  @spec template_names_in_summary(String.t()) :: [String.t()]
  def template_names_in_summary(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "Available template names:")))
    |> Enum.take_while(&(&1 != "" and not String.starts_with?(&1, "Composer-internal")))
    |> Enum.flat_map(&scan_backticked/1)
  end

  @doc """
  Skill names declared in the `## Skills` section: the first backticked token
  of each line-anchored entry (bullet or table row).
  """
  @spec skill_names_in_section(String.t()) :: [String.t()]
  def skill_names_in_section(content) do
    content
    |> section_lines(&(&1 == "## Skills"))
    |> Enum.flat_map(&first_backticked_token/1)
  end

  @doc """
  Framework labels on the `- **Frameworks**:` line, comma-split. `[]` when
  the line is absent — set comparison then treats a non-empty expectation as
  all-missing (and an empty one as clean).
  """
  @spec framework_names_in_doc(String.t()) :: [String.t()]
  def framework_names_in_doc(content) do
    case Regex.run(~r/^- \*\*Frameworks\*\*:\s*(.+)$/m, content, capture: :all_but_first) do
      [labels] -> Enum.map(String.split(labels, ","), &String.trim/1)
      nil -> []
    end
  end

  @doc """
  The document's `### Custom Skills` section: lines from the heading up to
  (exclusive) the next `---` separator, trailing blank lines dropped —
  the byte-comparison scope for the `:custom_skills_fragment` check.
  `nil` when the heading is absent.
  """
  @spec custom_skills_fragment_in_doc(String.t()) :: String.t() | nil
  def custom_skills_fragment_in_doc(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "### Custom Skills"))
    |> case do
      [] ->
        nil

      section ->
        section
        |> Enum.take_while(&(&1 != "---"))
        |> drop_trailing_blanks()
        |> Enum.join("\n")
    end
  end

  @doc """
  Backticked paths listed as bullets under `- **Entry points**:`.
  """
  @spec entry_point_paths(String.t()) :: [String.t()]
  def entry_point_paths(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "- **Entry points**:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "  - "))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^  - `([^`]+)`/, line, capture: :all_but_first) do
        [path] -> [path]
        nil -> []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Checks
  # ---------------------------------------------------------------------------

  defp check_version(problems, content, expected) do
    case Regex.run(~r/^- \*\*Version\*\*:\s*(.+)$/m, content, capture: :all_but_first) do
      [^expected] -> problems
      [actual] -> ["Version is #{actual}, expected #{expected}" | problems]
      nil -> ["missing `- **Version**:` line" | problems]
    end
  end

  defp check_tool_count(problems, content, tool_names) do
    expected = length(tool_names)

    case Regex.run(~r/^## Tools \((\d+) total\)$/m, content, capture: :all_but_first) do
      [count] ->
        if String.to_integer(count) == expected do
          problems
        else
          ["Tools heading count is #{count}, expected #{expected}" | problems]
        end

      nil ->
        ["missing `## Tools (N total)` heading" | problems]
    end
  end

  defp check_name_set(problems, actual, expected, label) do
    actual_sorted = Enum.sort(actual)
    expected_sorted = Enum.sort(expected)

    diffs = [
      {"missing", expected_sorted -- actual_sorted},
      {"unexpected", actual_sorted -- expected_sorted}
    ]

    Enum.reduce(diffs, problems, fn
      {_kind, []}, acc -> acc
      {kind, names}, acc -> ["#{label}: #{kind}: #{Enum.join(names, ", ")}" | acc]
    end)
  end

  defp check_custom_skills_fragment(problems, content, expected) do
    expected_normalized =
      expected
      |> String.split("\n")
      |> drop_trailing_blanks()
      |> Enum.join("\n")

    case custom_skills_fragment_in_doc(content) do
      nil ->
        ["missing `### Custom Skills` section" | problems]

      ^expected_normalized ->
        problems

      _drifted ->
        [
          "Custom Skills section drifted from the generator " <>
            "(splice in JidoClaw.JidoMd.custom_skills_section/0)"
          | problems
        ]
    end
  end

  defp drop_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp check_no_machine_path(problems, content) do
    if Regex.match?(~r{/(Users|home)/\w}, content) do
      ["contains a machine-absolute path (/Users/... or /home/...)" | problems]
    else
      problems
    end
  end

  defp check_entry_points(problems, content, path_exists?) do
    content
    |> entry_point_paths()
    |> Enum.reject(path_exists?)
    |> case do
      [] -> problems
      dead -> ["Entry points reference nonexistent paths: #{Enum.join(dead, ", ")}" | problems]
    end
  end

  # ---------------------------------------------------------------------------
  # Line helpers
  # ---------------------------------------------------------------------------

  # Lines strictly between the heading matched by `heading_matcher` and the
  # next `## ` heading (h3+ subsections stay inside the section).
  defp section_lines(content, heading_matcher) do
    content
    |> String.split("\n")
    |> Enum.drop_while(fn line -> not heading_matcher.(line) end)
    |> case do
      [] -> []
      [_heading | rest] -> Enum.take_while(rest, &(not String.starts_with?(&1, "## ")))
    end
  end

  defp first_backticked_token(line) do
    case Regex.run(~r/^(?:- |\| )`([a-z0-9_]+)`/, line, capture: :all_but_first) do
      [name] -> [name]
      nil -> []
    end
  end

  defp scan_backticked(line) do
    ~r/`([a-z0-9_]+)`/
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
  end
end
