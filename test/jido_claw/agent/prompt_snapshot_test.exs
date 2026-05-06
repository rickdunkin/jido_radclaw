defmodule JidoClaw.Agent.PromptSnapshotTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Agent.Prompt
  alias JidoClaw.Workspaces.Resolver, as: WorkspaceResolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :auto)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.mode(JidoClaw.Repo, :manual)
    end)

    project_dir =
      Path.join(System.tmp_dir!(), "snapshot_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(Path.join(project_dir, ".jido"))

    on_exit(fn -> File.rm_rf(project_dir) end)

    {:ok, project_dir: project_dir}
  end

  test "build/1 returns a non-empty prompt with no scope", %{project_dir: dir} do
    prompt = Prompt.build(dir)
    assert is_binary(prompt)
    assert byte_size(prompt) > 0
    refute prompt =~ "Memory Blocks"
  end

  test "build_snapshot/2 with nil scope renders no Block tier", %{project_dir: dir} do
    prompt = Prompt.build_snapshot(dir, nil)
    refute prompt =~ "Memory Blocks"
  end

  test "build_snapshot/2 with a workspace scope renders the Block-tier when blocks exist",
       %{project_dir: dir} do
    {:ok, ws} = WorkspaceResolver.ensure_workspace("default", dir)

    {:ok, _block} =
      JidoClaw.Memory.Block.write(%{
        tenant_id: "default",
        scope_kind: :workspace,
        workspace_id: ws.id,
        label: "guideline",
        value: "Always run mix format",
        source: :user
      })

    scope = %{
      tenant_id: "default",
      scope_kind: :workspace,
      workspace_id: ws.id,
      user_id: nil,
      project_id: nil,
      session_id: nil
    }

    prompt = Prompt.build_snapshot(dir, scope)
    assert prompt =~ "Memory Blocks"
    assert prompt =~ "guideline"
    assert prompt =~ "Always run mix format"
  end

  test "snapshot is byte-stable across reads", %{project_dir: dir} do
    {:ok, ws} = WorkspaceResolver.ensure_workspace("default", dir)

    scope = %{
      tenant_id: "default",
      scope_kind: :workspace,
      workspace_id: ws.id,
      user_id: nil,
      project_id: nil,
      session_id: nil
    }

    a = Prompt.build_snapshot(dir, scope)
    b = Prompt.build_snapshot(dir, scope)
    assert a == b
  end
end
