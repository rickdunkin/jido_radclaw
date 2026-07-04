defmodule JidoClaw.Core.DependencyPatchesTest do
  @moduledoc """
  Guards the single-source patch inventory (1.4). The release-relocation
  compile task must relocate the SAME modules `DependencyPatches` force-loads at
  boot — otherwise a patch (e.g. the jido_mcp STDIO env-scrub) can be
  force-loaded in dev yet ship un-relocated in a prod release (two BEAMs for the
  module). Env-independent: reads the two accessors, not the prod-gated `run/1`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Core.DependencyPatches
  alias Mix.Tasks.Compile.JidoclawReleasePatches

  test "the STDIO transport patch is in the canonical inventory" do
    assert {Jido.MCP.Transport.STDIO, :jido_mcp} in DependencyPatches.patched_modules()
  end

  test "the release task's beam list reads the same single source" do
    assert JidoclawReleasePatches.patched_beams() == DependencyPatches.patched_modules()
  end
end
