defmodule JidoClaw.Shell.SessionManagerClassifyTest do
  # async: false — classify/2 reads MountTable (global ETS) and the
  # :extra_commands config is application-global.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "test-sm-classify-#{System.unique_integer([:positive])}"

    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_claw_sm_classify_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "x.txt"), "hello")
    {:ok, _pid} = Workspace.ensure_started(workspace_id, tmp)

    # Capture & restore :extra_commands so a test that mutates it doesn't
    # leak into the next run — same pattern as
    # deps/jido_shell/test/jido/shell/guardrails_extension_test.exs:17-23.
    previous_extras = Application.get_env(:jido_shell, :extra_commands)

    on_exit(fn ->
      case previous_extras do
        nil -> Application.delete_env(:jido_shell, :extra_commands)
        value -> Application.put_env(:jido_shell, :extra_commands, value)
      end

      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
      File.rm_rf!(tmp)
    end)

    {:ok, workspace_id: workspace_id, tmp: tmp}
  end

  describe "extension commands" do
    test "routes `jido status` to :vfs", %{workspace_id: ws} do
      assert SessionManager.classify("jido status", ws) == :vfs
    end

    test "routes `jido memory search foo` (variadic query) to :vfs", %{workspace_id: ws} do
      assert SessionManager.classify("jido memory search foo", ws) == :vfs
    end

    test "routes bare `help` to :vfs", %{workspace_id: ws} do
      assert SessionManager.classify("help", ws) == :vfs
    end

    test "routes `help jido` to :vfs", %{workspace_id: ws} do
      assert SessionManager.classify("help jido", ws) == :vfs
    end
  end

  describe "baseline classifier" do
    test "routes `ls` (no absolute path) to :host unchanged", %{workspace_id: ws} do
      assert SessionManager.classify("ls", ws) == :host
    end

    test "routes `cat /project/x.txt` (mounted absolute path) to :vfs", %{workspace_id: ws} do
      assert SessionManager.classify("cat /project/x.txt", ws) == :vfs
    end

    test "routes `rm -rf /` (pipeline meta / unmounted path) to :host", %{workspace_id: ws} do
      # `/` is not a mounted path, so absolute-path check fails -> host.
      assert SessionManager.classify("rm -rf /", ws) == :host
    end

    test "shadowing a built-in via :extra_commands does not reroute baseline routing",
         %{workspace_id: ws} do
      # `commands/0` resolves `ls` to the built-in regardless, but the
      # classifier must not treat `ls` as extension-only — otherwise the
      # absolute-path mount check gets skipped for a shadowed built-in.
      # Module atom here is arbitrary — classification doesn't dispatch.
      current = Application.get_env(:jido_shell, :extra_commands, %{})

      Application.put_env(
        :jido_shell,
        :extra_commands,
        Map.put(current, "ls", JidoClaw.Shell.Commands.Jido)
      )

      assert SessionManager.classify("ls", ws) == :host
      assert SessionManager.classify("ls /unmounted/path", ws) == :host
    end
  end
end
