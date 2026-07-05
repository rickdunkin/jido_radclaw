defmodule JidoClaw.JidoMdTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Templates
  alias JidoClaw.JidoMd
  alias JidoClaw.JidoMd.Check

  # Every test writes through `generate/1`, which unconditionally creates
  # `.jido/` under the given dir — so every test runs in a tmp_dir scaffolded
  # as a minimal Elixir project, never at the repo root (which would clobber
  # the committed .jido/JIDO.md).

  defp generate_in(tmp_dir) do
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Scaffold.MixProject do\nend\n")
    :ok = JidoMd.generate(tmp_dir)
    File.read!(Path.join([tmp_dir, ".jido", "JIDO.md"]))
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

      tool_names =
        JidoClaw.Agent.tool_modules()
        |> Enum.map(& &1.name())
        |> Enum.sort()

      opts = [
        version: to_string(Application.spec(:jido_claw, :vsn)),
        tool_names: tool_names,
        template_names: Enum.sort(Templates.names()),
        spawnable_names: expected_spawnable_names(),
        skill_names: JidoClaw.Skills.default_skill_names(),
        path_exists?: &File.exists?(Path.join(tmp_dir, &1))
      ]

      assert Check.problems(content, opts) == []
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
