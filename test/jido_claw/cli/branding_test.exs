defmodule JidoClaw.CLI.BrandingTest do
  @moduledoc """
  Pins the boot banner's template-count line to the live registry (1.6): it was
  hardcoded "6 agent types". The assertion is wired to `Templates.names/0`, so
  it stays correct as templates are added or removed.

  Also pins the `/help` box entries for the routed-but-once-undocumented
  commands (`/gates`, `/profile`, `/workspace`) plus a light width-parity
  guard against their section neighbors — the box is pre-existingly ragged,
  so a strict all-lines-equal invariant must wait for the full realignment.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.Agent.Templates
  alias JidoClaw.CLI.Branding
  alias JidoClaw.Security.Redaction.Ansi

  test "boot banner reports the live template count, not a hardcoded number" do
    tmp = Path.join(System.tmp_dir!(), "branding_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    output = capture_io(fn -> Branding.boot_sequence(tmp) end)

    assert output =~ "#{length(Templates.names())} agent types"
  end

  describe "help_text/0" do
    test "documents /gates, /profile, and /workspace" do
      help = Branding.help_text()

      assert help =~ "/gates"
      assert help =~ "/profile"
      assert help =~ "/workspace"
    end

    test "each new entry's visible width matches a sibling command line in its section" do
      lines = String.split(Branding.help_text(), "\n")

      # {new command, sampled pre-existing sibling in the same section}
      pairs = [
        {"/gates", "/channels"},
        {"/profile", "/servers test"},
        {"/workspace", "/memory forget"}
      ]

      for {new_cmd, sibling_cmd} <- pairs do
        new_line = Enum.find(lines, &String.contains?(&1, new_cmd))
        sibling_line = Enum.find(lines, &String.contains?(&1, sibling_cmd))

        assert new_line, "expected a help line for #{new_cmd}"
        assert sibling_line, "expected a help line for #{sibling_cmd}"

        assert visible_width(new_line) == visible_width(sibling_line),
               "#{new_cmd} width #{visible_width(new_line)} != " <>
                 "#{sibling_cmd} width #{visible_width(sibling_line)}"
      end
    end
  end

  defp visible_width(line), do: String.length(Ansi.strip(line))
end
