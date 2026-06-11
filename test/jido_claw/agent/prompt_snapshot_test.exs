defmodule JidoClaw.Agent.PromptSnapshotTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Agent.Prompt
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Memory.Block
  alias JidoClaw.Workspaces.Resolver, as: WorkspaceResolver

  setup do
    :ok = Sandbox.checkout(JidoClaw.Repo)
    :ok = Sandbox.mode(JidoClaw.Repo, :auto)

    on_exit(fn ->
      :ok = Sandbox.mode(JidoClaw.Repo, :manual)
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
      Block.write(
        %{
          scope_kind: :workspace,
          workspace_id: ws.id,
          label: "guideline",
          value: "Always run mix format",
          source: :user
        },
        tenant: "default",
        actor: Actor.system("default")
      )

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

  test "a block written with a raw secret never reaches the prompt unredacted",
       %{project_dir: dir} do
    {:ok, ws} = WorkspaceResolver.ensure_workspace("default", dir)

    raw_key = "sk-ant-aaaabbbbccccddddeeeeffff"

    {:ok, _block} =
      Block.write(
        %{
          scope_kind: :workspace,
          workspace_id: ws.id,
          label: "leaky",
          value: "anthropic key is #{raw_key}",
          description: "also holds #{raw_key}",
          source: :user
        },
        tenant: "default",
        actor: Actor.system("default")
      )

    prompt =
      Prompt.build_snapshot(dir, %{
        tenant_id: "default",
        scope_kind: :workspace,
        workspace_id: ws.id,
        user_id: nil,
        project_id: nil,
        session_id: nil
      })

    # Blocks render verbatim into the system prompt — the only thing
    # standing between a pasted secret and the LLM is the :write-time
    # redaction this pins.
    refute prompt =~ raw_key
    assert prompt =~ "[REDACTED:ANTHROPIC_KEY]"
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
