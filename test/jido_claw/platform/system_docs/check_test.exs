defmodule JidoClaw.SystemDocs.CheckTest do
  use ExUnit.Case, async: true

  alias JidoClaw.SystemDocs.Check

  defp always_exists(_path), do: true

  defp replace_in(%{path: path, content: content}, old, new),
    do: %{path: path, content: String.replace(content, old, new)}

  # The clean loop-guard page carries every link class on purpose: an
  # intra-system link with an anchor, a repo-relative link above
  # docs/system/, an https URL, a pure-anchor link, and a backticked
  # source ref — so the clean-corpus test proves the exclusions.
  defp clean_loop_guard do
    %{
      path: "docs/system/loop-guard.md",
      content: """
      ---
      type: subsystem
      description: Doom-loop detection for tool calls.
      sources:
        - lib/jido_claw/agent/loop_guard.ex
      verified: 2026-07-07
      verified_sha: "1c90e385"
      ---

      # Loop Guard

      ## What & why

      Blocks doomed tool calls. Shaping is upstream: [Output Shaping](output-shaping.md#mechanics),
      broader map in [ARCHITECTURE](../ARCHITECTURE.md), upstream port at
      [osa](https://example.com/osa.md), details [below](#source-map).

      ## Source map

      - `lib/jido_claw/agent/loop_guard.ex:42` — detection windows
      """
    }
  end

  # No verified_sha — the clean corpus doubles as the absent-key-clean proof.
  defp clean_output_shaping do
    %{
      path: "docs/system/output-shaping.md",
      content: """
      ---
      type: subsystem
      description: Format-aware compression of verbose tool output.
      sources:
        - lib/jido_claw/tools/output_shaper.ex
      verified: 2026-07-07
      ---

      # Output Shaping

      ## What & why

      Compress the green, never the red.

      ## Source map

      - `lib/jido_claw/tools/output_shaper.ex` — the shaper
      """
    }
  end

  defp clean_readme do
    %{
      path: "docs/system/README.md",
      content: """
      # System Docs — Conventions & Index

      Review rubric: [TRUST-BOUNDARIES](../TRUST-BOUNDARIES.md).

      ## Index

      - [Loop Guard](loop-guard.md) — doom-loop detection
      - [Output Shaping](output-shaping.md) — tool output compression
      """
    }
  end

  # Carries a `docs/system/<X>.md` placeholder (must never match) and a
  # pointer inside the usage-rules region (must never be scanned).
  defp clean_agents_md do
    """
    # JidoClaw

    Deep subsystem truth lives in docs/system/README.md; a change touching
    subsystem X updates docs/system/<X>.md in the same change.

    - **Loop Guard**: halts doom loops → docs/system/loop-guard.md
    - **Output Shaping**: compresses output → docs/system/output-shaping.md

    <!-- usage-rules-start -->
    managed region — docs/system/only-in-managed-region.md must be ignored
    <!-- usage-rules-end -->
    """
  end

  defp clean_opts(overrides \\ []) do
    Keyword.merge(
      [
        pages: [clean_loop_guard(), clean_output_shaping()],
        readme: clean_readme(),
        agents_md: clean_agents_md(),
        path_exists?: &always_exists/1
      ],
      overrides
    )
  end

  describe "problems/1" do
    test "clean corpus yields no problems" do
      assert Check.problems(clean_opts()) == []
    end

    test "empty corpus with scaffold README and hub pointer is clean" do
      readme = %{path: "docs/system/README.md", content: "# System Docs\n\n## Index\n"}

      agents =
        "Hub: docs/system/README.md\n<!-- usage-rules-start -->\n<!-- usage-rules-end -->\n"

      assert Check.problems(
               pages: [],
               readme: readme,
               agents_md: agents,
               path_exists?: &always_exists/1
             ) == []
    end
  end

  describe "page_problems/2 — frontmatter structure" do
    test "missing frontmatter is flagged" do
      page = %{path: "docs/system/loop-guard.md", content: "# No frontmatter\n"}

      assert Check.page_problems(page, &always_exists/1) ==
               ["docs/system/loop-guard.md: missing frontmatter (file must start with `---`)"]
    end

    test "unterminated frontmatter is flagged" do
      page = %{path: "docs/system/loop-guard.md", content: "---\ntype: subsystem\n"}

      assert Check.page_problems(page, &always_exists/1) ==
               ["docs/system/loop-guard.md: unterminated frontmatter (no closing `---`)"]
    end

    test "non-map frontmatter is flagged" do
      page = %{path: "docs/system/loop-guard.md", content: "---\nscalar only\n---\nbody\n"}

      assert Check.page_problems(page, &always_exists/1) ==
               ["docs/system/loop-guard.md: frontmatter is not a mapping"]
    end

    test "malformed YAML frontmatter is flagged" do
      page = %{path: "docs/system/loop-guard.md", content: "---\n: {[bad\n---\nbody\n"}

      assert [problem] = Check.page_problems(page, &always_exists/1)
      assert problem =~ "docs/system/loop-guard.md: frontmatter is not valid YAML:"
    end

    test "each missing required key is flagged" do
      removals = [
        {"type", "type: subsystem\n"},
        {"description", "description: Doom-loop detection for tool calls.\n"},
        {"sources", "sources:\n  - lib/jido_claw/agent/loop_guard.ex\n"},
        {"verified", "verified: 2026-07-07\n"}
      ]

      for {key, line} <- removals do
        page = replace_in(clean_loop_guard(), line, "")

        assert Check.page_problems(page, &always_exists/1) ==
                 ["docs/system/loop-guard.md: frontmatter missing required key: #{key}"],
               "expected exactly the missing-key problem for #{key}"
      end
    end
  end

  describe "page_problems/2 — field contracts" do
    test "type outside the vocabulary is flagged" do
      page = replace_in(clean_loop_guard(), "type: subsystem", "type: gizmo")

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `type` must be one of " <>
                   "subsystem | surface | contract, got: \"gizmo\""
               ]
    end

    test "every vocabulary type is clean" do
      for type <- ["subsystem", "surface", "contract"] do
        page = replace_in(clean_loop_guard(), "type: subsystem", "type: #{type}")
        assert Check.page_problems(page, &always_exists/1) == [], "type #{type} should be clean"
      end
    end

    test "blank or non-string description is flagged" do
      message = "docs/system/loop-guard.md: frontmatter `description` must be a non-empty string"
      original = "description: Doom-loop detection for tool calls."

      nil_page = replace_in(clean_loop_guard(), original, "description:")
      assert Check.page_problems(nil_page, &always_exists/1) == [message]

      blank_page = replace_in(clean_loop_guard(), original, ~s(description: "  "))
      assert Check.page_problems(blank_page, &always_exists/1) == [message]
    end

    test "sources as a scalar is flagged" do
      page =
        replace_in(
          clean_loop_guard(),
          "sources:\n  - lib/jido_claw/agent/loop_guard.ex",
          "sources: lib/jido_claw/agent/loop_guard.ex"
        )

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` must be a non-empty list " <>
                   "of repo-relative paths"
               ]
    end

    test "empty sources list is flagged" do
      page =
        replace_in(
          clean_loop_guard(),
          "sources:\n  - lib/jido_claw/agent/loop_guard.ex",
          "sources: []"
        )

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` must be a non-empty list " <>
                   "of repo-relative paths"
               ]
    end

    test "absolute and ~-led source paths are rejected" do
      absolute =
        replace_in(
          clean_loop_guard(),
          "- lib/jido_claw/agent/loop_guard.ex",
          "- /Users/x/lib/loop_guard.ex"
        )

      assert Check.page_problems(absolute, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` path must be " <>
                   "repo-relative: /Users/x/lib/loop_guard.ex"
               ]

      home_led =
        replace_in(
          clean_loop_guard(),
          "- lib/jido_claw/agent/loop_guard.ex",
          ~s(- "~/lib/loop_guard.ex")
        )

      assert Check.page_problems(home_led, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` path must be " <>
                   "repo-relative: ~/lib/loop_guard.ex"
               ]
    end

    test "source path with a .. segment is rejected" do
      page =
        replace_in(
          clean_loop_guard(),
          "- lib/jido_claw/agent/loop_guard.ex",
          "- lib/../secrets.env"
        )

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` path must not " <>
                   "contain `..`: lib/../secrets.env"
               ]
    end

    test "non-string source entry (YAML-retyped) is flagged" do
      page = replace_in(clean_loop_guard(), "- lib/jido_claw/agent/loop_guard.ex", "- 42")

      assert Check.page_problems(page, &always_exists/1) ==
               ["docs/system/loop-guard.md: frontmatter `sources` entry must be a string: 42"]
    end

    test "nonexistent source path is flagged" do
      missing = fn path -> path != "lib/jido_claw/agent/loop_guard.ex" end

      assert Check.page_problems(clean_loop_guard(), missing) ==
               [
                 "docs/system/loop-guard.md: frontmatter `sources` path does not exist: " <>
                   "lib/jido_claw/agent/loop_guard.ex"
               ]
    end

    test "non-YYYY-MM-DD verified value is flagged" do
      page = replace_in(clean_loop_guard(), "verified: 2026-07-07", "verified: July 7, 2026")

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `verified` must be a YYYY-MM-DD date string"
               ]
    end

    test "unquoted all-digit verified_sha (YAML integer) is flagged" do
      page =
        replace_in(clean_loop_guard(), ~s(verified_sha: "1c90e385"), "verified_sha: 1234567")

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: frontmatter `verified_sha` must be a quoted " <>
                   "hex string (7-40 lowercase hex chars)"
               ]
    end

    test "non-hex and empty verified_sha are flagged; absent is clean" do
      message =
        "docs/system/loop-guard.md: frontmatter `verified_sha` must be a quoted " <>
          "hex string (7-40 lowercase hex chars)"

      non_hex =
        replace_in(clean_loop_guard(), ~s(verified_sha: "1c90e385"), ~s(verified_sha: "xyz9999"))

      assert Check.page_problems(non_hex, &always_exists/1) == [message]

      empty = replace_in(clean_loop_guard(), ~s(verified_sha: "1c90e385"), ~s(verified_sha: ""))
      assert Check.page_problems(empty, &always_exists/1) == [message]

      assert Check.page_problems(clean_output_shaping(), &always_exists/1) == []
    end
  end

  describe "page_problems/2 — source map" do
    test "missing Source map section is flagged" do
      page = replace_in(clean_loop_guard(), "## Source map", "## Sources")

      assert Check.page_problems(page, &always_exists/1) ==
               ["docs/system/loop-guard.md: missing `## Source map` section"]
    end

    test "Source map without a backticked path entry is flagged" do
      page =
        replace_in(
          clean_loop_guard(),
          "- `lib/jido_claw/agent/loop_guard.ex:42` — detection windows",
          "- prose without a ref"
        )

      assert Check.page_problems(page, &always_exists/1) ==
               [
                 "docs/system/loop-guard.md: `## Source map` section has no backticked " <>
                   "`path[:line]` entries"
               ]
    end
  end

  describe "problems/1 — link resolution" do
    test "broken intra-system link is flagged" do
      broken = replace_in(clean_loop_guard(), "(output-shaping.md#mechanics)", "(ghost.md)")

      assert Check.problems(clean_opts(pages: [broken, clean_output_shaping()])) ==
               ["docs/system/loop-guard.md: broken link: ghost.md (no such page in docs/system/)"]
    end

    test "link escaping the repo root is flagged" do
      # docs/system/ sits two levels deep, so escape needs three `..`s; a
      # two-`..` target lands at the repo root and rides the existence check.
      escaping =
        replace_in(clean_loop_guard(), "(../ARCHITECTURE.md)", "(../../../escape.md)")

      assert Check.problems(clean_opts(pages: [escaping, clean_output_shaping()])) ==
               ["docs/system/loop-guard.md: link escapes the repo root: ../../../escape.md"]
    end

    test "repo-relative link outside docs/system must exist" do
      outside = replace_in(clean_loop_guard(), "(../ARCHITECTURE.md)", "(../../outside.md)")
      exists = fn path -> path != "outside.md" end

      assert Check.problems(
               clean_opts(pages: [outside, clean_output_shaping()], path_exists?: exists)
             ) ==
               ["docs/system/loop-guard.md: broken link: ../../outside.md (file does not exist)"]
    end
  end

  describe "problems/1 — index set-match" do
    test "page missing from the index is flagged" do
      readme =
        replace_in(
          clean_readme(),
          "- [Output Shaping](output-shaping.md) — tool output compression\n",
          ""
        )

      assert Check.problems(clean_opts(readme: readme)) ==
               ["docs/system/README.md: index missing: output-shaping.md"]
    end

    test "index row without a page is flagged (its link is broken too)" do
      readme =
        replace_in(
          clean_readme(),
          "- [Loop Guard](loop-guard.md) — doom-loop detection",
          "- [Loop Guard](loop-guard.md) — doom-loop detection\n- [Ghost](ghost.md) — no such page"
        )

      assert Enum.sort(Check.problems(clean_opts(readme: readme))) ==
               [
                 "docs/system/README.md: broken link: ghost.md (no such page in docs/system/)",
                 "docs/system/README.md: index unexpected: ghost.md"
               ]
    end

    test "same-count rename yields both missing and unexpected" do
      readme = replace_in(clean_readme(), "(output-shaping.md)", "(gamma.md)")
      problems = Check.problems(clean_opts(readme: readme))

      assert "docs/system/README.md: index missing: output-shaping.md" in problems
      assert "docs/system/README.md: index unexpected: gamma.md" in problems
    end

    test "missing ## Index heading fails closed" do
      readme = replace_in(clean_readme(), "## Index", "## Pages")

      assert Check.problems(clean_opts(readme: readme)) ==
               ["docs/system/README.md: missing `## Index` heading"]
    end
  end

  describe "problems/1 — AGENTS.md pointers" do
    test "pointer to a nonexistent page is flagged" do
      agents =
        String.replace(
          clean_agents_md(),
          "- **Loop Guard**:",
          "See docs/system/ghost.md.\n- **Loop Guard**:"
        )

      assert Check.problems(clean_opts(agents_md: agents)) ==
               ["AGENTS.md: pointer to nonexistent page: docs/system/ghost.md"]
    end

    test "page never referenced from AGENTS.md is flagged" do
      agents = String.replace(clean_agents_md(), " → docs/system/output-shaping.md", "")

      assert Check.problems(clean_opts(agents_md: agents)) ==
               ["docs/system/output-shaping.md: page never referenced from AGENTS.md"]
    end

    test "pointer occurrences inside the usage-rules region are ignored" do
      # The clean fixture plants docs/system/only-in-managed-region.md inside
      # the region — scanned, it would be a broken pointer.
      assert Check.problems(clean_opts()) == []
      refute "only-in-managed-region.md" in Check.agents_pointers(clean_agents_md())
    end
  end

  describe "split_frontmatter/1" do
    test "splits map frontmatter from body" do
      assert {:ok, %{"type" => "subsystem"}, body} =
               Check.split_frontmatter("---\ntype: subsystem\n---\n\n# Title\n")

      assert body =~ "# Title"
    end

    test "distinct error reasons per failure mode" do
      assert Check.split_frontmatter("# no frontmatter\n") == {:error, :missing}
      assert Check.split_frontmatter("---\ntype: x\n") == {:error, :unterminated}
      assert Check.split_frontmatter("---\nscalar only\n---\nbody") == {:error, :not_a_map}
      assert {:error, {:invalid_yaml, _}} = Check.split_frontmatter("---\n: {[bad\n---\nbody")
    end
  end

  describe "doc_links/1" do
    test "extracts .md targets, strips anchors, excludes URLs/anchors/backticked refs" do
      content = """
      [a](one.md) [b](one.md#sec) [c](../two.md) [d](https://x.io/three.md)
      [e](#anchor) [f](http://x.io/four.md) `lib/foo.ex:12` [g](image.png)
      """

      assert Check.doc_links(content) == ["one.md", "../two.md"]
    end

    test "links quoted in code fences or inline code spans are not links" do
      content = """
      Index rows look like `- [Title](fenced-example.md) — hook`.

      ```markdown
      - [Another](another-example.md) — inside a fence
      ```

      A real [link](real.md) still counts.
      """

      assert Check.doc_links(content) == ["real.md"]
    end
  end

  describe "index_entries/1" do
    test "returns row targets under ## Index; malformed rows are skipped" do
      content = """
      ## Index

      - [A](a.md) — first
      - [B](b.md) missing separator
      - not a row
      - [C](c.md) — third
      """

      assert Check.index_entries(content) == {:ok, ["a.md", "c.md"]}
    end

    test "stops at the next h2 heading" do
      content = """
      ## Index

      - [A](a.md) — first

      ## Notes

      - [B](b.md) — not an index row
      """

      assert Check.index_entries(content) == {:ok, ["a.md"]}
    end

    test "returns :error without the heading" do
      assert Check.index_entries("# Nope\n") == :error
    end
  end

  describe "committed corpus" do
    # The jido_md round-trip analog: the real docs/system/ corpus + AGENTS.md
    # must pass the check that guards them in precommit.
    test "docs/system pages, README index, and AGENTS.md pointers are self-consistent" do
      docs =
        "docs/system"
        |> Path.join("*.md")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&%{path: &1, content: File.read!(&1)})

      {[readme], pages} = Enum.split_with(docs, &(Path.basename(&1.path) == "README.md"))

      assert Check.problems(pages: pages, readme: readme, agents_md: File.read!("AGENTS.md")) ==
               []
    end
  end

  describe "agents_pointers/1" do
    test "extracts deduped page names incl. README; placeholders never match" do
      content = """
      Hub: docs/system/README.md and docs/system/loop-guard.md, again
      docs/system/loop-guard.md; placeholder docs/system/<X>.md never.
      <!-- usage-rules-start -->
      docs/system/managed-only.md
      <!-- usage-rules-end -->
      """

      assert Check.agents_pointers(content) == ["README.md", "loop-guard.md"]
    end

    test "scans the whole file when the marker is absent" do
      assert Check.agents_pointers("see docs/system/a.md") == ["a.md"]
    end
  end
end
