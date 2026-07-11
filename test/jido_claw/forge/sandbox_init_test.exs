defmodule JidoClaw.Forge.SandboxInitTest do
  use ExUnit.Case, async: true

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

  describe "reap_orphaned_workspace_dirs/1" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "sandbox_init_reap_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      %{base: base}
    end

    test "removes forge-* directories and keeps everything else", %{base: base} do
      File.mkdir_p!(Path.join(base, "forge-1"))
      File.write!(Path.join(base, "forge-1/.forge_env"), "SECRET=stranded\n")
      File.mkdir_p!(Path.join(base, "forge-2"))
      File.mkdir_p!(Path.join(base, "keepme"))
      # forge- named symlink: must be skipped entirely, never followed
      File.ln_s!(Path.join(base, "keepme"), Path.join(base, "forge-link"))

      capture_log(fn -> assert :ok = SandboxInit.reap_orphaned_workspace_dirs(base) end)

      refute File.exists?(Path.join(base, "forge-1"))
      refute File.exists?(Path.join(base, "forge-2"))
      assert File.dir?(Path.join(base, "keepme"))
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(base, "forge-link"))
    end

    test "returns :ok for a nonexistent base" do
      missing = "/nonexistent/reap_base_#{:erlang.unique_integer([:positive])}"

      capture_log(fn -> assert :ok = SandboxInit.reap_orphaned_workspace_dirs(missing) end)
    end

    test "skips a symlinked base without touching its target", %{base: base} do
      File.mkdir_p!(Path.join(base, "forge-real"))
      link = base <> "_link"
      File.ln_s!(base, link)
      on_exit(fn -> File.rm(link) end)

      capture_log(fn -> assert :ok = SandboxInit.reap_orphaned_workspace_dirs(link) end)

      assert File.dir?(Path.join(base, "forge-real")),
             "target of a symlinked base must be untouched"
    end
  end
end
