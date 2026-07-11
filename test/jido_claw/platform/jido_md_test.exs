defmodule JidoClaw.JidoMdTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Templates
  alias JidoClaw.JidoMd
  alias JidoClaw.JidoMd.Check

  # Every test writes through `generate/1`, which unconditionally creates
  # `.jido/` under the given dir — so every test runs in a tmp_dir scaffolded
  # as a minimal Elixir project, never at the repo root (which would clobber
  # the committed .jido/JIDO.md). Pass a mix.exs string to scaffold a
  # dep-carrying project; the helper writes the GIVEN scaffold, so the
  # condition under test survives the generate.

  @dep_less_mix_exs "defmodule Scaffold.MixProject do\nend\n"

  # Phoenix WITHOUT phoenix_live_view — the label-normalization regression
  # condition (the interpolated label used to carry a trailing space that
  # failed the checker's trimmed comma-split parse).
  @phoenix_no_liveview_mix_exs """
  defmodule Scaffold.MixProject do
    defp deps do
      [
        {:phoenix, "~> 1.7"},
        {:ecto_sql, "~> 3.13"}
      ]
    end
  end
  """

  defp generate_in(tmp_dir, mix_exs \\ @dep_less_mix_exs) do
    File.write!(Path.join(tmp_dir, "mix.exs"), mix_exs)
    :ok = JidoMd.generate(tmp_dir)
    File.read!(Path.join([tmp_dir, ".jido", "JIDO.md"]))
  end

  # The full expected-truth opts for `Check.problems/2`; derive AFTER the
  # generate so `framework_names` reads the scaffold actually written.
  defp drift_guard_opts(tmp_dir) do
    tool_names =
      JidoClaw.Agent.tool_modules()
      |> Enum.map(& &1.name())
      |> Enum.sort()

    [
      version: to_string(Application.spec(:jido_claw, :vsn)),
      tool_names: tool_names,
      template_names: Enum.sort(Templates.names()),
      spawnable_names: expected_spawnable_names(),
      skill_names: JidoClaw.Skills.default_skill_names(),
      framework_names: JidoMd.framework_names(tmp_dir),
      path_exists?: &File.exists?(Path.join(tmp_dir, &1))
    ]
  end

  defp expected_spawnable_names do
    Templates.list()
    |> Enum.reject(fn {_name, template} -> Templates.composer_private_template?(template) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  describe "generate/1 template sections (audit §1.12 regression)" do
    @tag :tmp_dir
    test "detail blocks cover every registered template", %{tmp_dir: tmp_dir} do
      content = generate_in(tmp_dir)

      assert Enum.sort(Check.template_names_in_detail(content)) ==
               Enum.sort(Templates.names())
    end

    @tag :tmp_dir
    test "the Available-template-names line lists exactly the spawnable set", %{tmp_dir: tmp_dir} do
      content = generate_in(tmp_dir)

      assert Enum.sort(Check.template_names_in_summary(content)) == expected_spawnable_names()
    end
  end

  describe "generate/1 → Check round-trip" do
    @tag :tmp_dir
    test "fresh generator output passes the drift guard", %{tmp_dir: tmp_dir} do
      content = generate_in(tmp_dir)

      assert Check.problems(content, drift_guard_opts(tmp_dir)) == []
    end

    @tag :tmp_dir
    test "a Phoenix-without-LiveView project passes the drift guard", %{tmp_dir: tmp_dir} do
      content = generate_in(tmp_dir, @phoenix_no_liveview_mix_exs)

      assert Check.problems(content, drift_guard_opts(tmp_dir)) == []
    end
  end

  describe "framework_names/1 (Elixir detection)" do
    @tag :tmp_dir
    test "detects Bandit, Jido, and ash_graphql-implied GraphQL", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule Scaffold.MixProject do
        defp deps do
          [
            {:phoenix, "~> 1.7"},
            {:phoenix_live_view, "~> 1.0"},
            {:ecto_sql, "~> 3.13"},
            {:ash_graphql, "~> 1.9"},
            {:bandit, "~> 1.5"},
            {:jido_ai, "~> 2.0"}
          ]
        end
      end
      """)

      assert JidoMd.framework_names(tmp_dir) == [
               "Phoenix (with LiveView)",
               "Ecto",
               "Absinthe/GraphQL",
               "Bandit HTTP adapter",
               "Jido AI Agent Framework"
             ]
    end

    @tag :tmp_dir
    test "Phoenix without LiveView yields a clean label, no trailing space", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), @phoenix_no_liveview_mix_exs)

      assert JidoMd.framework_names(tmp_dir) == ["Phoenix", "Ecto"]
    end

    @tag :tmp_dir
    test "a dep-less scaffold detects nothing (no Frameworks line generated)", %{
      tmp_dir: tmp_dir
    } do
      content = generate_in(tmp_dir)

      assert JidoMd.framework_names(tmp_dir) == []
      refute content =~ "- **Frameworks**:"
    end
  end

  describe "generate/1 entry points" do
    @tag :tmp_dir
    test "lists a graphql/schema.ex only when the file exists", %{tmp_dir: tmp_dir} do
      without = generate_in(tmp_dir)
      refute without =~ "graphql/schema.ex"

      schema_dir = Path.join([tmp_dir, "lib", "scaffold", "graphql"])
      File.mkdir_p!(schema_dir)
      File.write!(Path.join(schema_dir, "schema.ex"), "defmodule Scaffold.Schema do\nend\n")

      with_schema = generate_in(tmp_dir)
      assert with_schema =~ "- `lib/scaffold/graphql/schema.ex`"
    end
  end

  describe "generate/1 content markers" do
    @tag :tmp_dir
    test "carries Version and Tools markers, no Root line, no machine path", %{tmp_dir: tmp_dir} do
      content = generate_in(tmp_dir)

      assert content =~ ~r/^- \*\*Version\*\*: \d/m
      assert content =~ ~r/^## Tools \(\d+ total\)$/m
      refute content =~ ~r/^- \*\*Root\*\*:/m
      refute content =~ ~r{/(Users|home)/\w}
    end
  end
end
