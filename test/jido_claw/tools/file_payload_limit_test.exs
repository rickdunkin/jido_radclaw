defmodule JidoClaw.Tools.FilePayloadLimitTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Tools.FilePayloadLimit

  @cap FilePayloadLimit.max_bytes()

  describe "validate_read_content/2 boundary" do
    test "content at exactly the cap is allowed" do
      assert :ok = FilePayloadLimit.validate_read_content("at_cap.bin", :binary.copy("x", @cap))
    end

    test "content one byte over the cap is refused with a structured error" do
      content = :binary.copy("x", @cap + 1)

      assert {:error, %{message: message, details: details}} =
               FilePayloadLimit.validate_read_content("big.bin", content)

      assert message =~ "read cap"
      assert details == %{path: "big.bin", size: @cap + 1, max_bytes: @cap}
    end
  end

  describe "validate_read/2" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "file_payload_limit_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "stats an over-cap local file without reading it", %{dir: dir} do
      path = Path.join(dir, "big.bin")
      File.write!(path, :binary.copy("x", @cap + 1))

      assert {:error, %{message: message}} =
               FilePayloadLimit.validate_read(path, project_dir: dir)

      assert message =~ "read cap"
    end

    test "is :ok for an under-cap local file", %{dir: dir} do
      path = Path.join(dir, "small.txt")
      File.write!(path, "tiny")

      assert :ok = FilePayloadLimit.validate_read(path, project_dir: dir)
    end

    test "falls through to :ok when the path does not resolve locally", %{dir: dir} do
      # Missing file: local_path's realpath fails — the read itself
      # must surface the real error, not the cap guard.
      assert :ok = FilePayloadLimit.validate_read(Path.join(dir, "ghost.txt"), project_dir: dir)

      # Remote URI: jailed local resolution fails — covered by the
      # post-read guard instead.
      assert :ok =
               FilePayloadLimit.validate_read("github://owner/repo/file.txt", project_dir: dir)
    end
  end
end
