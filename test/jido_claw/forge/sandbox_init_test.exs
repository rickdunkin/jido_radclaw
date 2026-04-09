defmodule JidoClaw.Forge.SandboxInitTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias JidoClaw.Forge.SandboxInit

  describe "run/0" do
    test "does not crash when sbx is not available" do
      # SandboxInit.run/0 should handle missing sbx gracefully
      capture_log(fn ->
        SandboxInit.run()
      end)
    end
  end

  describe "cleanup_orphaned_sandboxes/0" do
    test "does not crash when sbx ls fails" do
      # If sbx is not installed or not authenticated, cleanup should
      # log a warning and return without crashing
      log =
        capture_log(fn ->
          SandboxInit.cleanup_orphaned_sandboxes()
        end)

      # Should either clean up successfully or warn about the failure
      assert is_binary(log)
    end
  end
end
