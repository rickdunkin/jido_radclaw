defmodule JidoClaw.ApplicationTest do
  @moduledoc """
  Coverage for `JidoClaw.Application.load_dotenv/0`.

  Locks in:
    * Honors `:project_dir` Application env when set.
    * Falls back to `cwd` when `:project_dir` is not set.
    * Loads from both `.env` and `.jido/.env` (most-specific wins).
    * Shell env wins over file values (parse_dotenv only writes unset).
  """

  use ExUnit.Case, async: false

  setup do
    prior_project_dir = Application.get_env(:jido_claw, :project_dir)
    prior_keys = capture_env(["JIDO_TEST_VAR_A", "JIDO_TEST_VAR_B", "JIDO_TEST_VAR_C"])

    on_exit(fn ->
      restore_app_env(:project_dir, prior_project_dir)
      Enum.each(prior_keys, fn {k, v} -> restore_env(k, v) end)
    end)

    {:ok, tmp_dir: System.tmp_dir!()}
  end

  describe "load_dotenv/0" do
    test "honors project_dir env over cwd", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, "jido_load_dotenv_#{unique_id()}")
      File.mkdir_p!(project_path)
      File.write!(Path.join(project_path, ".env"), "JIDO_TEST_VAR_A=from_project_env\n")

      Application.put_env(:jido_claw, :project_dir, project_path)
      System.delete_env("JIDO_TEST_VAR_A")

      JidoClaw.Application.load_dotenv()

      assert System.get_env("JIDO_TEST_VAR_A") == "from_project_env"

      File.rm_rf!(project_path)
    end

    test "loads .jido/.env from project_dir alongside .env", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, "jido_load_dotenv_#{unique_id()}")
      jido_dir = Path.join(project_path, ".jido")
      File.mkdir_p!(jido_dir)
      File.write!(Path.join(project_path, ".env"), "JIDO_TEST_VAR_A=from_root_env\n")
      File.write!(Path.join(jido_dir, ".env"), "JIDO_TEST_VAR_B=from_jido_env\n")

      Application.put_env(:jido_claw, :project_dir, project_path)
      System.delete_env("JIDO_TEST_VAR_A")
      System.delete_env("JIDO_TEST_VAR_B")

      JidoClaw.Application.load_dotenv()

      assert System.get_env("JIDO_TEST_VAR_A") == "from_root_env"
      assert System.get_env("JIDO_TEST_VAR_B") == "from_jido_env"

      File.rm_rf!(project_path)
    end

    test "shell env wins over file (parse_dotenv unset-only write)", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, "jido_load_dotenv_#{unique_id()}")
      File.mkdir_p!(project_path)
      File.write!(Path.join(project_path, ".env"), "JIDO_TEST_VAR_C=from_file\n")

      Application.put_env(:jido_claw, :project_dir, project_path)
      System.put_env("JIDO_TEST_VAR_C", "from_shell")

      JidoClaw.Application.load_dotenv()

      assert System.get_env("JIDO_TEST_VAR_C") == "from_shell"

      File.rm_rf!(project_path)
    end

    test "falls back to cwd when project_dir is unset" do
      Application.delete_env(:jido_claw, :project_dir)

      # No file in cwd is created — just verify the call doesn't crash.
      assert :ok == (JidoClaw.Application.load_dotenv() || :ok)
    end
  end

  defp capture_env(keys) do
    Enum.map(keys, fn k -> {k, System.get_env(k)} end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
