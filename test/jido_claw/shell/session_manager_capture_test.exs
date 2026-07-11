defmodule JidoClaw.Shell.SessionManagerCaptureTest do
  # async: false — SessionManager.run is a GenServer.call into the app-tree
  # singleton, which executes the command INLINE in handle_call (blocking the
  # one manager for the whole run); concurrent async modules would serialize
  # on its mailbox and risk call timeouts under load.
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.VFS.Workspace

  setup do
    workspace_id = "sm-capture-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = SessionManager.stop_session(workspace_id)
      _ = Workspace.teardown(workspace_id)
    end)

    {:ok, workspace_id: workspace_id}
  end

  test "the :capture_bytes opt raises the non-streaming capture above the legacy cap",
       %{workspace_id: ws} do
    # ~150KB of output — over the legacy 10KB cap, under the requested capture.
    command = "python3 -c \"print('x' * 150000)\""

    assert {:ok, result} =
             SessionManager.run(ws, command, 30_000, capture_bytes: 200_000)

    assert byte_size(result.output) >= 150_000
    refute result.output =~ "output truncated"
  end

  test "output between capture and the 2x valve truncates gracefully with the note",
       %{workspace_id: ws} do
    # 30KB output, 20KB capture: inside the capture..2×capture window,
    # so the run succeeds and finalize truncates at the capture cap.
    command = "python3 -c \"print('x' * 30000)\""

    assert {:ok, result} = SessionManager.run(ws, command, 30_000, capture_bytes: 20_000)

    assert byte_size(result.output) <= 20_000 + byte_size(SessionManager.truncation_note(false))
    assert String.ends_with?(result.output, SessionManager.truncation_note(false))
  end

  test "output past the 2x valve still trips the runaway error", %{workspace_id: ws} do
    command = "python3 -c \"print('x' * 50000)\""

    assert {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}} =
             SessionManager.run(ws, command, 30_000, capture_bytes: 20_000)
  end

  test "without the opt the legacy 10KB cap holds byte-identically", %{workspace_id: ws} do
    command = "python3 -c \"print('x' * 12000)\""

    assert {:ok, result} = SessionManager.run(ws, command, 30_000)

    assert byte_size(result.output) <= 10_000 + byte_size(SessionManager.truncation_note(false))
    assert String.ends_with?(result.output, SessionManager.truncation_note(false))
  end

  # OutputShaper suffix-matches captured output against these exact
  # strings to detect upstream truncation — drift here silently disables
  # that detection, so the literals are pinned.
  test "truncation_note/1 strings are pinned" do
    assert SessionManager.truncation_note(false) == "\n... (output truncated)"

    assert SessionManager.truncation_note(true) ==
             "\n... (output truncated; full output streamed live)\n"
  end
end
