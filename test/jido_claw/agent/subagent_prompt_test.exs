defmodule JidoClaw.Agent.SubagentPromptTest do
  @moduledoc """
  Assembly contract for `JidoClaw.Agent.SubagentPrompt` (AR-5). The Block-tier
  cases hit the DB (Scope.resolve + list_blocks_for_scope_chain), so this runs
  `async: false` under a shared sandbox. Block write + scope modeled on
  `prompt_snapshot_test.exs`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Agent.SubagentPrompt
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Memory.Block

  setup do
    project_dir =
      Path.join(System.tmp_dir!(), "subagent_prompt_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(project_dir, ".jido"))
    on_exit(fn -> File.rm_rf(project_dir) end)

    {:ok, project_dir: project_dir}
  end

  describe "build/2 — doctrine + role composition (no scope)" do
    test "coder prompt carries the role, DOCTRINE, and artifacts slice", %{project_dir: dir} do
      prompt = SubagentPrompt.build("coder", %{project_dir: dir})

      assert prompt != ""
      assert prompt =~ "# Role"
      assert prompt =~ "Full-capability coding agent"
      assert prompt =~ "## DOCTRINE"
      assert prompt =~ "Runtime artifacts"
      # Unresolvable scope (no tenant) → no Block tier.
      refute prompt =~ "Memory Blocks"
    end

    test "reviewer prompt carries the reviewer-min slice, not artifacts", %{project_dir: dir} do
      prompt = SubagentPrompt.build("reviewer", %{project_dir: dir})

      assert prompt =~ "## DOCTRINE"
      assert prompt =~ "Review discipline"
      refute prompt =~ "Runtime artifacts"
    end

    test "an unknown template falls back to a generic role line, no crash", %{project_dir: dir} do
      prompt = SubagentPrompt.build("not_a_template", %{project_dir: dir})

      assert prompt =~ "You are a specialized sub-agent"
      # Unmapped template → no DOCTRINE section.
      refute prompt =~ "## DOCTRINE"
    end
  end

  describe "build/2 — Memory Block tier from a resolved scope (DB)" do
    test "a workspace-scoped Block renders into the prompt", %{project_dir: dir} do
      tenant_id = seed_tenant("ar5-blocks")
      {:ok, ws} = seed_workspace(tenant_id, path: dir)

      {:ok, _block} =
        Block.write(
          %{
            scope_kind: :workspace,
            workspace_id: ws.id,
            label: "guideline",
            value: "Always run mix format",
            source: :user
          },
          tenant: tenant_id,
          actor: Actor.system(tenant_id)
        )

      prompt =
        SubagentPrompt.build("coder", %{
          tenant_id: tenant_id,
          workspace_uuid: ws.id,
          project_dir: dir
        })

      assert prompt =~ "Memory Blocks"
      assert prompt =~ "guideline"
      assert prompt =~ "Always run mix format"
    end

    test "a Block written with a raw secret never reaches the prompt unredacted",
         %{project_dir: dir} do
      tenant_id = seed_tenant("ar5-secret")
      {:ok, ws} = seed_workspace(tenant_id, path: dir)

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
          tenant: tenant_id,
          actor: Actor.system(tenant_id)
        )

      prompt =
        SubagentPrompt.build("coder", %{
          tenant_id: tenant_id,
          workspace_uuid: ws.id,
          project_dir: dir
        })

      # Redaction-at-write must carry through PromptSections.blocks_section reuse.
      refute prompt =~ raw_key
      assert prompt =~ "[REDACTED:ANTHROPIC_KEY]"
    end
  end
end
