defmodule JidoClaw.CLI.BrandingTest do
  @moduledoc """
  Pins the boot banner's template-count line to the live registry (1.6): it was
  hardcoded "6 agent types". The assertion is wired to `Templates.names/0`, so
  it stays correct as templates are added or removed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias JidoClaw.Agent.Templates
  alias JidoClaw.CLI.Branding

  test "boot banner reports the live template count, not a hardcoded number" do
    tmp = Path.join(System.tmp_dir!(), "branding_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    output = capture_io(fn -> Branding.boot_sequence(tmp) end)

    assert output =~ "#{length(Templates.names())} agent types"
  end
end
