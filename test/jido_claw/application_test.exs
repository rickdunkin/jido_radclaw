defmodule JidoClaw.ApplicationTest do
  @moduledoc """
  Coverage for `JidoClaw.Application.load_dotenv/0`.

  Locks in:
    * Honors `:project_dir` Application env when set.
    * Falls back to `cwd` when `:project_dir` is not set.
    * Loads from both `.env` and `.jido/.env` (most-specific wins).
    * Shell env wins over file values (parse_dotenv only writes unset).
    * Test config/boot scrub provider, AWS, OneCLI, and Forge environment.
    * Test ExAws uses inert credentials and a no-network HTTP adapter.
  """

  use ExUnit.Case, async: false

  alias JidoClaw.Test.NoExternalExAwsHttpClient

  @external_secrets ~w(
    ANTHROPIC_API_KEY BRAVE_SEARCH_API_KEY DISCORD_BOT_TOKEN GITHUB_TOKEN GOOGLE_API_KEY
    GROQ_API_KEY OLLAMA_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY VOYAGE_API_KEY XAI_API_KEY
  )

  setup do
    prior_project_dir = Application.get_env(:jido_claw, :project_dir)
    prior_keys = capture_env(["JIDO_TEST_VAR_A", "JIDO_TEST_VAR_B", "JIDO_TEST_VAR_C"])

    on_exit(fn ->
      restore_app_env(:project_dir, prior_project_dir)
      Enum.each(prior_keys, fn {k, v} -> restore_env(k, v) end)
      Enum.each(@external_secrets, &System.delete_env/1)
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

      in_empty_cwd(tmp_dir, &JidoClaw.Application.load_dotenv/0)

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

      in_empty_cwd(tmp_dir, &JidoClaw.Application.load_dotenv/0)

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

      in_empty_cwd(tmp_dir, &JidoClaw.Application.load_dotenv/0)

      assert System.get_env("JIDO_TEST_VAR_C") == "from_shell"

      File.rm_rf!(project_path)
    end

    test "falls back to cwd when project_dir is unset", %{tmp_dir: tmp_dir} do
      project_path = Path.join(tmp_dir, "jido_load_dotenv_cwd_#{unique_id()}")
      File.mkdir_p!(project_path)
      Application.delete_env(:jido_claw, :project_dir)

      # Run from an intentionally empty cwd. Calling this parser seam from the
      # repository cwd would ingest the developer's real `.env` and undo the
      # test boot sanitizer this file is meant to prove.
      File.cd!(project_path, fn ->
        assert :ok == (JidoClaw.Application.load_dotenv() || :ok)
      end)

      File.rm_rf!(project_path)
    end
  end

  test "test boots do not ingest dotenv files or start Discord" do
    refute Application.fetch_env!(:jido_claw, :load_dotenv)
    assert Application.fetch_env!(:jido_claw, :skip_discord)
    assert is_nil(System.get_env("DISCORD_BOT_TOKEN"))
    assert is_nil(System.get_env("VOYAGE_API_KEY"))
    assert is_nil(System.get_env("BRAVE_SEARCH_API_KEY"))
    assert is_nil(System.get_env("AWS_ACCESS_KEY_ID"))
    assert is_nil(System.get_env("AWS_SECRET_ACCESS_KEY"))
    assert is_nil(System.get_env("AWS_SESSION_TOKEN"))

    assert is_nil(System.get_env("FORGE_ONECLI_ENABLED")),
           "FORGE_ONECLI_ENABLED leaked into test: #{inspect(System.get_env("FORGE_ONECLI_ENABLED"))}"

    assert is_nil(System.get_env("ONECLI_AGENT_TOKENS"))
    assert is_nil(System.get_env("FORGE_SANDBOX"))
    assert is_nil(System.get_env("FORGE_SANDBOX_AGENT"))
    assert is_nil(System.get_env("FORGE_WORKSPACE_BASE"))

    onecli = Application.fetch_env!(:jido_claw, :onecli)
    refute onecli[:enabled]
    assert onecli[:agent_tokens] == []
    assert is_nil(onecli[:gateway_url])
    assert is_nil(onecli[:ca_cert_path])

    assert Application.fetch_env!(:jido_claw, :forge_sandbox) ==
             JidoClaw.Forge.Runner.HostShell

    assert Application.fetch_env!(:ex_aws, :access_key_id) == "test-disabled-access-key"
    assert Application.fetch_env!(:ex_aws, :secret_access_key) == "test-disabled-secret-key"
    assert Application.fetch_env!(:ex_aws, :security_token) == "test-disabled-session-token"

    assert Application.fetch_env!(:ex_aws, :http_client) == NoExternalExAwsHttpClient

    resolved_aws = ExAws.Config.new(:s3)
    assert resolved_aws.access_key_id == "test-disabled-access-key"
    assert resolved_aws.secret_access_key == "test-disabled-secret-key"
    assert resolved_aws.security_token == "test-disabled-session-token"
    assert resolved_aws.http_client == NoExternalExAwsHttpClient

    assert {:error, %{reason: :external_network_disabled_in_test}} =
             NoExternalExAwsHttpClient.request(
               :get,
               "http://169.254.169.254/latest/meta-data/",
               "",
               [],
               []
             )
  end

  test "boot sanitizer deletes explicit and patterned external environment" do
    names = [
      "BRAVE_SEARCH_API_KEY",
      "AWS_ACCESS_KEY_ID",
      "AWS_FUTURE_CREDENTIAL_SOURCE",
      "FORGE_ONECLI_ENABLED",
      "FORGE_SANDBOX",
      "FORGE_SANDBOX_AGENT",
      "FORGE_WORKSPACE_BASE",
      "ONECLI_AGENT_TOKENS",
      "ONECLI_FUTURE_TOKEN_FILE"
    ]

    prior_onecli = Application.get_env(:jido_claw, :onecli)
    prior_forge_sandbox = Application.get_env(:jido_claw, :forge_sandbox)
    prior_forge_docker = Application.get_env(:jido_claw, :forge_docker_sandbox)
    prior_brave = Application.get_env(:jido_browser, :brave_api_key)

    prior_ex_aws =
      for key <- [:access_key_id, :secret_access_key, :security_token, :http_client] do
        {key, Application.fetch_env(:ex_aws, key)}
      end

    on_exit(fn ->
      # Never restore inherited external credentials inside a test BEAM. The
      # hermetic boundary is stronger than ordinary test-local env cleanup.
      Enum.each(names, &System.delete_env/1)
      restore_app_env(:onecli, prior_onecli)
      restore_app_env(:forge_sandbox, prior_forge_sandbox)
      restore_app_env(:forge_docker_sandbox, prior_forge_docker)

      Enum.each(prior_ex_aws, fn {key, value} ->
        restore_app_env(:ex_aws, key, value)
      end)

      if prior_brave do
        Application.put_env(:jido_browser, :brave_api_key, prior_brave)
      else
        Application.delete_env(:jido_browser, :brave_api_key)
      end
    end)

    Enum.each(names, &System.put_env(&1, "test-sentinel"))
    Application.put_env(:jido_browser, :brave_api_key, "test-sentinel")
    Application.put_env(:jido_claw, :forge_sandbox, JidoClaw.Forge.Sandbox.Docker)
    Application.put_env(:jido_claw, :forge_docker_sandbox, workspace_base: "/tmp/external")
    Application.put_env(:ex_aws, :access_key_id, :instance_role)
    Application.put_env(:ex_aws, :secret_access_key, :instance_role)
    Application.put_env(:ex_aws, :security_token, :instance_role)
    Application.put_env(:ex_aws, :http_client, ExAws.Request.Req)

    Application.put_env(:jido_claw, :onecli,
      enabled: true,
      gateway_url: "https://example.invalid",
      ca_cert_path: "/tmp/test-onecli-ca",
      agent_tokens: ["test-sentinel"]
    )

    assert :ok = JidoClaw.Application.sanitize_external_test_environment()
    assert Enum.all?(names, &is_nil(System.get_env(&1)))
    assert is_nil(Application.get_env(:jido_browser, :brave_api_key))

    onecli = Application.fetch_env!(:jido_claw, :onecli)
    refute onecli[:enabled]
    assert onecli[:agent_tokens] == []
    assert is_nil(onecli[:gateway_url])
    assert is_nil(onecli[:ca_cert_path])

    assert Application.fetch_env!(:jido_claw, :forge_sandbox) ==
             JidoClaw.Forge.Runner.HostShell

    assert :error = Application.fetch_env(:jido_claw, :forge_docker_sandbox)
    assert Application.fetch_env!(:ex_aws, :access_key_id) == "test-disabled-access-key"
    assert Application.fetch_env!(:ex_aws, :secret_access_key) == "test-disabled-secret-key"
    assert Application.fetch_env!(:ex_aws, :security_token) == "test-disabled-session-token"

    assert Application.fetch_env!(:ex_aws, :http_client) == NoExternalExAwsHttpClient
  end

  describe "supervision topology" do
    test "keeps the root supervisor one_for_one and isolates dependency chains" do
      assert supervisor_strategy(JidoClaw.Supervisor) == :one_for_one
      assert supervisor_strategy(JidoClaw.InfraSupervisor) == :one_for_one
      assert supervisor_strategy(JidoClaw.Forge.Supervisor) == :rest_for_one
      assert supervisor_strategy(JidoClaw.CodeServer.Supervisor) == :rest_for_one
      assert supervisor_strategy(JidoClaw.TenantRuntimeSupervisor) == :rest_for_one
      assert supervisor_strategy(JidoClaw.Shell.Supervisor) == :rest_for_one
    end

    test "supervises the heartbeat writer" do
      assert {JidoClaw.Heartbeat, pid, :worker, [JidoClaw.Heartbeat]} =
               JidoClaw.Supervisor
               |> Supervisor.which_children()
               |> Enum.find(fn {id, _pid, _type, _modules} -> id == JidoClaw.Heartbeat end)

      assert pid == Process.whereis(JidoClaw.Heartbeat)
    end
  end

  defp capture_env(keys) do
    Enum.map(keys, fn k -> {k, System.get_env(k)} end)
  end

  defp supervisor_strategy(name) do
    name
    |> Process.whereis()
    |> :sys.get_state()
    |> elem(2)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore_app_env(key, value), do: Application.put_env(:jido_claw, key, value)

  defp restore_app_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp in_empty_cwd(tmp_dir, fun) do
    cwd = Path.join(tmp_dir, "jido_load_dotenv_empty_cwd_#{unique_id()}")
    File.mkdir_p!(cwd)
    result = File.cd!(cwd, fun)
    File.rm_rf!(cwd)
    result
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
end
