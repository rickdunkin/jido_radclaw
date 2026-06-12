defmodule JidoClaw.Tools.GitDiffTest do
  use ExUnit.Case, async: false

  import JidoClaw.TenantCase, only: [seed_full: 1, actor_for: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Tools.FetchOutput
  alias JidoClaw.Tools.GitDiff

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_git_diff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    scrubbed = Env.scrubbed_cmd_env()

    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir, env: scrubbed)

    {_, 0} =
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir, env: scrubbed)

    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir, env: scrubbed)

    File.write!(Path.join(dir, "big.txt"), Enum.map_join(1..900, "\n", &"original line #{&1}"))
    {_, 0} = System.cmd("git", ["add", "."], cd: dir, env: scrubbed)
    {_, 0} = System.cmd("git", ["commit", "-qm", "seed"], cd: dir, env: scrubbed)

    # ~25KB of changed lines: over the legacy 15KB slice AND over
    # min_shape_bytes, so both modes are observable.
    File.write!(Path.join(dir, "big.txt"), Enum.map_join(1..900, "\n", &"changed line #{&1}!!"))

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "shaping off keeps the legacy 15KB head slice", %{dir: dir} do
    assert {:ok, %{diff: diff}} =
             GitDiff.run(%{}, %{tool_context: %{project_dir: dir}})

    assert diff =~ "diff --git a/big.txt b/big.txt"
    assert diff =~ "(diff truncated)"
    assert byte_size(diff) <= 16_000
    refute diff =~ "changed line 900"
  end

  test "shaping on returns a stat header, budgeted body, and fetchable ref", %{dir: dir} do
    original = Application.get_env(:jido_claw, :output_shaping, [])
    Application.put_env(:jido_claw, :output_shaping, Keyword.merge(original, enabled?: true))

    sandbox_pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)

    on_exit(fn ->
      Application.put_env(:jido_claw, :output_shaping, original)
      Sandbox.stop_owner(sandbox_pid)
    end)

    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "git-diff")

    context = %{
      tool_context: %{
        tenant_id: tenant_id,
        session_uuid: session.id,
        actor: actor_for(tenant_id),
        project_dir: dir
      }
    }

    assert {:ok, result} = GitDiff.run(%{}, context)

    assert result.shaped
    assert result.output_ref =~ ~r/^out_/
    assert result.diff =~ "git diff — 1 files changed, +900/−900"
    assert result.diff =~ "big.txt | +900 −900"
    assert result.summary.files_changed == 1

    # Reversibility: the tail of the diff that the legacy slice dropped
    # is reachable through the ref.
    assert {:ok, fetched} =
             FetchOutput.run(%{ref: result.output_ref, grep: "changed line 900"}, context)

    assert fetched.returned_lines >= 1
  end
end
