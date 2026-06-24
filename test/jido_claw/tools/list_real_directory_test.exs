defmodule JidoClaw.Tools.ListRealDirectoryTest do
  # AR-8b-2 F3: read-only listing of the REAL project tree from a sketch worker.
  # Mirrors list_directory_test's "AR-8b sketch jail" block; the jail target is the
  # real base (two levels up from the `.prototypes/<uuid>/` sandbox). No size-cap
  # assertion — `list_real_directory` reuses `list_directory`'s core.
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.ListRealDirectory
  alias JidoClaw.VFS.Sandbox

  setup do
    base = Path.join(System.tmp_dir!(), "jido_list_real_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, proto: proto}
  end

  defp sandbox_ctx(proto), do: %{tool_context: %{project_dir: proto, sandbox: :prototype}}

  describe "lists the real tree (read-only)" do
    test "lists a real-tree directory (two levels up from the sandbox)", %{
      base: base,
      proto: proto
    } do
      File.write!(Path.join(base, "real_file.ex"), "")

      assert {:ok, result} = ListRealDirectory.run(%{path: base}, sandbox_ctx(proto))
      assert result.entries =~ "real_file.ex"
    end
  end

  describe "fails closed off the sketch path" do
    test "a non-sandbox context refuses to list the real tree", %{base: base} do
      assert {:error, _} =
               ListRealDirectory.run(%{path: base}, %{tool_context: %{project_dir: base}})
    end

    test "a sandbox context with no project_dir fails closed" do
      assert {:error, _} =
               ListRealDirectory.run(%{path: "."}, %{tool_context: %{sandbox: :prototype}})
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{base: base} do
      assert {:error, _} =
               ListRealDirectory.run(
                 %{path: base},
                 %{tool_context: %{project_dir: base, sandbox: :prototype}}
               )
    end
  end

  describe "jailed to the real root" do
    test "rejects an absolute path outside the real base", %{proto: proto} do
      outside =
        Path.join(System.tmp_dir!(), "jido_list_real_out_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, _} = ListRealDirectory.run(%{path: outside}, sandbox_ctx(proto))
    end
  end

  describe "forbids remote schemes" do
    test "rejects a github:// path via the remote-branch guard", %{proto: proto} do
      assert {:error, %{message: message}} =
               ListRealDirectory.run(%{path: "github://o/r/dir"}, sandbox_ctx(proto))

      assert message =~ "remote schemes are forbidden in the sketch sandbox"
    end
  end
end
