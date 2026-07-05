defmodule JidoClaw.JidoMd.CheckTest do
  use ExUnit.Case, async: true

  alias JidoClaw.JidoMd.Check

  defp clean_opts do
    [
      version: "1.2.3",
      tool_names: ["alpha_tool", "beta_tool"],
      template_names: ["coder", "sketch_build"],
      spawnable_names: ["coder"],
      skill_names: ["full_review", "sfr_review"],
      path_exists?: fn _ -> true end
    ]
  end

  defp clean_content do
    """
    # JIDO.md — Self-Knowledge for sample

    ## Project

    - **Name**: sample
    - **Type**: Elixir/OTP
    - **Version**: 1.2.3
    - **Entry points**:
      - `mix.exs`
      - `lib/`

    ---

    ## Agent Templates

    Use `spawn_agent` with a template name to create a child agent.

    ### `coder`
    - **Description**: writes code
    - **Tools**: alpha_tool
    - **Max iterations**: 25

    ### `sketch_build`
    - **Description**: sketches a prototype
    - **Tools**: beta_tool
    - **Max iterations**: 10
    - **Composer-internal**: used by the route composer; not spawnable via `spawn_agent`

    ---

    ## Skills

    ### Built-in Skills

    - `full_review` — run tests and review changes
    - `sfr_review` — certificate-backed review

    ### Custom Skills

    Create `.jido/skills/<name>.yaml`.

    Available template names: `coder`
    Composer-internal (not spawnable): `sketch_build`

    ---

    ## Tools (2 total)

    - `alpha_tool`
    - `beta_tool`

    ---
    """
  end

  test "crafted-clean content yields no problems" do
    assert Check.problems(clean_content(), clean_opts()) == []
  end

  test "wrong version is flagged" do
    opts = Keyword.put(clean_opts(), :version, "9.9.9")

    assert Check.problems(clean_content(), opts) == ["Version is 1.2.3, expected 9.9.9"]
  end

  test "wrong tool count in the heading is flagged" do
    content = String.replace(clean_content(), "## Tools (2 total)", "## Tools (3 total)")

    assert Check.problems(content, clean_opts()) == ["Tools heading count is 3, expected 2"]
  end

  test "renamed tool at the same count is flagged" do
    content = String.replace(clean_content(), "- `beta_tool`", "- `gamma_tool`")

    assert Check.problems(content, clean_opts()) == [
             "Tools section: missing: beta_tool",
             "Tools section: unexpected: gamma_tool"
           ]
  end

  test "template detail-header set mismatch is flagged" do
    opts = Keyword.put(clean_opts(), :template_names, ["coder", "fixer", "sketch_build"])

    assert Check.problems(clean_content(), opts) ==
             ["Agent Templates detail headers: missing: fixer"]
  end

  test "spawnable summary-line set mismatch is flagged" do
    opts = Keyword.put(clean_opts(), :spawnable_names, ["coder", "fixer"])

    assert Check.problems(clean_content(), opts) ==
             ["Available template names line: missing: fixer"]
  end

  test "missing skill is flagged" do
    content =
      String.replace(clean_content(), "- `sfr_review` — certificate-backed review\n", "")

    assert Check.problems(content, clean_opts()) == ["Skills section: missing: sfr_review"]
  end

  test "a machine-absolute path is flagged" do
    content = String.replace(clean_content(), "- **Name**: sample", "- **Root**: /Users/x/proj")

    assert Check.problems(content, clean_opts()) ==
             ["contains a machine-absolute path (/Users/... or /home/...)"]
  end

  test "dead entry-point paths are flagged via the injected predicate" do
    opts = Keyword.put(clean_opts(), :path_exists?, fn _ -> false end)

    assert Check.problems(clean_content(), opts) ==
             ["Entry points reference nonexistent paths: mix.exs, lib/"]
  end

  test "the summary parser follows wrapped continuation lines (pre-fix generator shape)" do
    wrapped = """
    Available template names: `coder`, `test_runner`, `reviewer`, `docs_writer`,
    `researcher`, `refactorer`

    ---
    """

    assert Check.template_names_in_summary(wrapped) ==
             ["coder", "test_runner", "reviewer", "docs_writer", "researcher", "refactorer"]
  end
end
