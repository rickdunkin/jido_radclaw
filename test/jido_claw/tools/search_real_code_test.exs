defmodule JidoClaw.Tools.SearchRealCodeTest do
  # AR-8b-2 F3: read-only grep over the REAL project tree from a sketch worker.
  # Mirrors search_code_test's "AR-8b sketch jail" block; the jail target is the
  # real base (two levels up from the `.prototypes/<uuid>/` sandbox). No size-cap
  # assertion — `search_real_code` reuses `search_code`'s uncapped read core.
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.SearchRealCode
  alias JidoClaw.VFS.Sandbox

  setup do
    base = Path.join(System.tmp_dir!(), "jido_search_real_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, proto: proto}
  end

  defp sandbox_ctx(proto), do: %{tool_context: %{project_dir: proto, sandbox: :prototype}}

  describe "searches the real tree (read-only)" do
    test "matches a pattern in a real-tree file (two levels up from the sandbox)", %{
      base: base,
      proto: proto
    } do
      File.write!(Path.join(base, "real.ex"), "defmodule RealThing do\nend\n")

      assert {:ok, result} =
               SearchRealCode.run(%{pattern: "defmodule Real", path: base}, sandbox_ctx(proto))

      assert result.total_matches >= 1
      assert result.matches =~ "real.ex"
    end
  end

  describe "fails closed off the sketch path" do
    test "a non-sandbox context refuses to search the real tree", %{base: base} do
      File.write!(Path.join(base, "real.ex"), "defmodule Secret do\nend\n")

      assert {:error, _} =
               SearchRealCode.run(
                 %{pattern: "defmodule", path: base},
                 %{tool_context: %{project_dir: base}}
               )
    end

    test "a sandbox context with no project_dir fails closed" do
      assert {:error, _} =
               SearchRealCode.run(
                 %{pattern: "defmodule"},
                 %{tool_context: %{sandbox: :prototype}}
               )
    end

    test "a sandbox context with a non-.prototypes project_dir is rejected", %{base: base} do
      assert {:error, _} =
               SearchRealCode.run(
                 %{pattern: "defmodule", path: base},
                 %{tool_context: %{project_dir: base, sandbox: :prototype}}
               )
    end
  end

  describe "jailed to the real root" do
    test "rejects an absolute search path outside the real base", %{proto: proto} do
      outside =
        Path.join(System.tmp_dir!(), "jido_search_real_out_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "leak.ex"), "defmodule Leak do\nend\n")
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:error, _} =
               SearchRealCode.run(%{pattern: "defmodule", path: outside}, sandbox_ctx(proto))
    end
  end

  describe "forbids remote schemes" do
    test "rejects a github:// search path", %{proto: proto} do
      assert {:error, _} =
               SearchRealCode.run(%{pattern: "x", path: "github://o/r/dir"}, sandbox_ctx(proto))
    end
  end
end
