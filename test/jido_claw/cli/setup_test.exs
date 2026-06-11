defmodule JidoClaw.CLI.SetupTest do
  use ExUnit.Case, async: true
  # async: persist_env_var/3 is pure file IO against isolated tmp dirs.

  alias JidoClaw.CLI.Setup

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_setup_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "persist_env_var/3" do
    test "creates .env at mode 0600 with the key line and no tmp leftovers", %{tmp_dir: dir} do
      assert :ok = Setup.persist_env_var(dir, "ANTHROPIC_API_KEY", "sk-test-value")

      env_path = Path.join(dir, ".env")
      assert File.read!(env_path) == "ANTHROPIC_API_KEY=sk-test-value\n"

      {:ok, %{mode: mode}} = File.stat(env_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert Path.wildcard(Path.join(dir, "*.tmp")) == []
    end

    test "upserts into an existing world-readable .env and tightens it to 0600", %{tmp_dir: dir} do
      env_path = Path.join(dir, ".env")

      File.write!(env_path, """
      # provider credentials
      OPENAI_API_KEY=old-value

      OTHER_VAR=untouched
      """)

      File.chmod!(env_path, 0o644)

      assert :ok = Setup.persist_env_var(dir, "OPENAI_API_KEY", "new-value")

      assert File.read!(env_path) == """
             # provider credentials
             OPENAI_API_KEY=new-value

             OTHER_VAR=untouched
             """

      {:ok, %{mode: mode}} = File.stat(env_path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Path.wildcard(Path.join(dir, "*.tmp")) == []
    end

    test "on rename failure the tmp file is removed and a non-file at .env keeps its mode",
         %{tmp_dir: dir} do
      env_path = Path.join(dir, ".env")
      File.mkdir_p!(env_path)
      File.chmod!(env_path, 0o755)

      assert_raise File.RenameError, fn ->
        Setup.persist_env_var(dir, "SOME_KEY", "value")
      end

      assert Path.wildcard(Path.join(dir, "*.tmp")) == []

      # The defensive chmod must not touch a directory sitting at .env.
      {:ok, %{type: :directory, mode: mode}} = File.lstat(env_path)
      assert Bitwise.band(mode, 0o777) == 0o755
    end
  end
end
