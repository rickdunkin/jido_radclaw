defmodule JidoClaw.Tools.ReadRealFileTest do
  # AR-8b-2 F3: read-only access to the REAL project tree from a sketch worker.
  # Mirrors read_file_test's "AR-8b sketch jail" block, but the jail target is the
  # real base (two levels up from the `.prototypes/<uuid>/` sandbox).
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.ReadRealFile
  alias JidoClaw.VFS.Sandbox

  @read_cap 5 * 1024 * 1024

  setup do
    base = Path.join(System.tmp_dir!(), "jido_read_real_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, proto: proto}
  end

  defp sandbox_ctx(proto), do: %{tool_context: %{project_dir: proto, sandbox: :prototype}}

  describe "reads the real tree (read-only)" do
    test "reads a file two levels up from the sandbox (the real base)", %{
      base: base,
      proto: proto
    } do
      path = Path.join(base, "real.txt")
      File.write!(path, "from the real tree\nsecond line")

      assert {:ok, result} = ReadRealFile.run(%{path: path}, sandbox_ctx(proto))
      assert result.content =~ "from the real tree"
      assert result.content =~ "   1 │ "
      assert result.total_lines == 2
    end
  end

  describe "fails closed off the sketch path" do
    test "a non-sandbox context refuses to read the real tree", %{base: base} do
      File.write!(Path.join(base, "real.txt"), "secret")

      assert {:error, _} =
               ReadRealFile.run(
                 %{path: Path.join(base, "real.txt")},
                 %{tool_context: %{project_dir: base}}
               )
    end

    test "a sandbox context with no project_dir fails closed", %{base: base} do
      File.write!(Path.join(base, "real.txt"), "secret")

      assert {:error, _} =
               ReadRealFile.run(
                 %{path: Path.join(base, "real.txt")},
                 %{tool_context: %{sandbox: :prototype}}
               )
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{base: base} do
      File.write!(Path.join(base, "real.txt"), "secret")

      assert {:error, _} =
               ReadRealFile.run(
                 %{path: Path.join(base, "real.txt")},
                 %{tool_context: %{project_dir: base, sandbox: :prototype}}
               )
    end
  end

  describe "jailed to the real root" do
    test "rejects an absolute path outside the real base", %{proto: proto} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "jido_real_outside_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(outside, "outside")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, _} = ReadRealFile.run(%{path: outside}, sandbox_ctx(proto))
    end

    test "rejects a parent-traversal escape", %{base: base, proto: proto} do
      assert {:error, _} =
               ReadRealFile.run(%{path: Path.join(base, "../escape.txt")}, sandbox_ctx(proto))
    end
  end

  describe "forbids remote schemes" do
    test "rejects a github:// path", %{proto: proto} do
      assert {:error, _} = ReadRealFile.run(%{path: "github://o/r/f"}, sandbox_ctx(proto))
    end
  end

  describe "read cap parity with read_file (FilePayloadLimit)" do
    test "refuses a real-tree file over the 5 MB cap", %{base: base, proto: proto} do
      path = Path.join(base, "big.bin")
      File.write!(path, :binary.copy("x", @read_cap + 1))

      assert {:error, %{message: message}} = ReadRealFile.run(%{path: path}, sandbox_ctx(proto))
      assert message =~ "read cap"
    end
  end

  describe "no write counterpart (mutation is structurally impossible)" do
    test "there is no write_real_file / edit_real_file tool" do
      refute Code.ensure_loaded?(JidoClaw.Tools.WriteRealFile)
      refute Code.ensure_loaded?(JidoClaw.Tools.EditRealFile)
    end
  end
end
