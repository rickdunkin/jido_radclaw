defmodule JidoClaw.Platform.ApprovalTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Platform.Approval

  setup do
    old_mode = Application.get_env(:jido_claw, :tool_approval_mode)
    Application.put_env(:jido_claw, :tool_approval_mode, :on_miss)

    on_exit(fn ->
      case old_mode do
        nil -> Application.delete_env(:jido_claw, :tool_approval_mode)
        mode -> Application.put_env(:jido_claw, :tool_approval_mode, mode)
      end
    end)
  end

  test "on_miss approves tools allowed from another process" do
    session_id = "session-#{System.unique_integer([:positive])}"
    tool_name = "read_file"

    Approval.allow(session_id, tool_name)
    Approval.pending()

    task = Task.async(fn -> Approval.check(session_id, tool_name, %{}) end)

    assert Task.await(task, 500) == :approved
  end
end
