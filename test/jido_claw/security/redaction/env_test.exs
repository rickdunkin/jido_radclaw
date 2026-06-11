defmodule JidoClaw.Security.Redaction.EnvTest do
  # async: false — the scrubbed_* tests enumerate and mutate the global
  # process env via System.put_env/get_env, which races concurrent tests.
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.Env

  describe "sensitive_key?/1" do
    test "matches _KEY/_TOKEN/_SECRET/_PASSWORD/_PASS/_PAT suffixes case-insensitively" do
      for suffix <- ~w(KEY TOKEN SECRET PASSWORD PASS PAT) do
        assert Env.sensitive_key?("MY_#{suffix}")
        assert Env.sensitive_key?(String.downcase("my_#{suffix}"))
        assert Env.sensitive_key?("Name_#{String.capitalize(suffix)}")
      end
    end

    test "matches AWS_SECRET_* / AWS_SESSION_TOKEN / DATABASE_URL / DB_URL" do
      assert Env.sensitive_key?("AWS_SECRET_ACCESS_KEY")
      assert Env.sensitive_key?("AWS_SECRET_ANYTHING")
      assert Env.sensitive_key?("AWS_SESSION_TOKEN")
      assert Env.sensitive_key?("DATABASE_URL")
      assert Env.sensitive_key?("DB_URL")
    end

    test "matches bare password/secret/token/authorization/credential exactly (case-insensitive)" do
      for key <- ~w(password secret token authorization credential) do
        assert Env.sensitive_key?(key)
        assert Env.sensitive_key?(String.upcase(key))
        assert Env.sensitive_key?(String.capitalize(key))
      end
    end

    test "bare-key match is exact, not substring — tokenizer/session_id/description stay safe" do
      refute Env.sensitive_key?("tokenizer")
      refute Env.sensitive_key?("session_id")
      refute Env.sensitive_key?("description")
    end

    test "does not match SESSION_ID / USER_ID / CLIENT_ID (documented false negatives)" do
      refute Env.sensitive_key?("SESSION_ID")
      refute Env.sensitive_key?("USER_ID")
      refute Env.sensitive_key?("CLIENT_ID")
    end

    test "does not match HOME / PATH / shell ergonomic names" do
      refute Env.sensitive_key?("HOME")
      refute Env.sensitive_key?("PATH")
      refute Env.sensitive_key?("TERM")
    end

    test "matches unconventionally-named secrets and credential suffixes" do
      assert Env.sensitive_key?("SECRET_KEY_BASE")
      assert Env.sensitive_key?("ONECLI_AGENT_TOKENS")
      assert Env.sensitive_key?("AWS_ACCESS_KEY_ID")
      assert Env.sensitive_key?("MY_CREDENTIALS")
      assert Env.sensitive_key?("MY_CREDENTIAL")
    end

    test "no blanket _BASE suffix — URL_BASE/API_BASE stay safe" do
      refute Env.sensitive_key?("URL_BASE")
      refute Env.sensitive_key?("API_BASE")
    end

    test "no blanket _TOKENS suffix — LLM usage counters stay safe" do
      refute Env.sensitive_key?("input_tokens")
      refute Env.sensitive_key?("output_tokens")
      refute Env.sensitive_key?("total_tokens")
    end
  end

  describe "redact_value/2" do
    test "masks whole value when key name is sensitive" do
      assert Env.redact_value("AWS_SECRET_ACCESS_KEY", "AKIASMOKETEST1234567") == "[REDACTED]"
      assert Env.redact_value("MY_TOKEN", "anything") == "[REDACTED]"
      assert Env.redact_value("DATABASE_PASSWORD", "prod-cluster-01") == "[REDACTED]"
    end

    test "masks DATABASE_URL entirely because user/host can be sensitive" do
      assert Env.redact_value("DATABASE_URL", "postgres://u:p@host:5432/db") == "[REDACTED]"
    end

    test "URL credentials masked with scheme/user/host preserved" do
      # Key name isn't sensitive so we fall into the URL-credential branch
      assert Env.redact_value("CONN", "postgres://alice:hunter2@localhost/db") ==
               "postgres://alice:[REDACTED]@localhost/db"
    end

    test "falls through to Patterns.redact/1 for embedded API keys" do
      # OpenAI-style key embedded in value, key name not sensitive
      val = "note: sk-abcdefghijklmnopqrstuvwxyz01"
      redacted = Env.redact_value("NOTE", val)
      assert redacted =~ "[REDACTED:API_KEY]"
      refute redacted =~ "sk-abcdefghijklmnopqrstuvwxyz01"
    end

    test "coerces non-binary values via to_string/1 (defensive on log-site inputs)" do
      # An integer value goes through to_string/1 and then Patterns.redact
      assert Env.redact_value("PORT", 5432) == "5432"
    end
  end

  describe "redact_env/1" do
    test "redacts a mixed-sensitivity map" do
      env = %{
        "BASE" => "ok",
        "AWS_SECRET_ACCESS_KEY" => "AKIASMOKETEST1234567",
        "CONN" => "postgres://alice:hunter2@localhost/db",
        "PORT" => "5432"
      }

      redacted = Env.redact_env(env)

      assert redacted["BASE"] == "ok"
      assert redacted["AWS_SECRET_ACCESS_KEY"] == "[REDACTED]"
      assert redacted["CONN"] == "postgres://alice:[REDACTED]@localhost/db"
      assert redacted["PORT"] == "5432"
    end

    test "passes through non-map input unchanged" do
      assert Env.redact_env(nil) == nil
      assert Env.redact_env("foo") == "foo"
    end
  end

  describe "scrubbed_cmd_env/1" do
    test "emits an unset tuple for each currently-set sensitive var" do
      name = put_fake_secret("TOKEN")

      assert {name, nil} in Env.scrubbed_cmd_env()
    end

    test "drops non-allowlisted vars — inheritance is allowlist, not denylist" do
      # An innocuously named var is still unset for children: only
      # allowlisted names are inherited.
      name = put_fake_secret("DIR")

      assert {name, nil} in Env.scrubbed_cmd_env()
    end

    test "drops unconventionally-named secrets that a denylist would miss" do
      put_named_env("SECRET_KEY_BASE", "super-secret")
      put_named_env("ONECLI_AGENT_TOKENS", "tok1,tok2")

      result = Env.scrubbed_cmd_env()

      assert {"SECRET_KEY_BASE", nil} in result
      assert {"ONECLI_AGENT_TOKENS", nil} in result
    end

    test "drops credential-capability vars by default (SSH_AUTH_SOCK)" do
      put_named_env("SSH_AUTH_SOCK", "/tmp/ssh-agent.sock")

      assert {"SSH_AUTH_SOCK", nil} in Env.scrubbed_cmd_env()
    end

    test "allowlisted shell ergonomics survive (no unset tuple)" do
      result = Env.scrubbed_cmd_env()

      refute {"PATH", nil} in result
      refute {"HOME", nil} in result
      refute {"TERM", nil} in result
    end

    test "LC_* and XDG_* prefixed vars survive" do
      put_named_env("LC_JIDO_TEST_COLLATE", "C")
      put_named_env("XDG_JIDO_TEST_HOME", "/tmp/xdg")

      result = Env.scrubbed_cmd_env()

      refute {"LC_JIDO_TEST_COLLATE", nil} in result
      refute {"XDG_JIDO_TEST_HOME", nil} in result
    end

    test "credential-free proxy vars survive; credentialed ones are dropped" do
      put_named_env("http_proxy", "http://proxy.example.com:8080")
      put_named_env("HTTPS_PROXY", "proxy.example.com:8080")

      result = Env.scrubbed_cmd_env()

      refute {"http_proxy", nil} in result
      refute {"HTTPS_PROXY", nil} in result

      put_named_env("HTTP_PROXY", "http://user:pass@proxy.example.com:8080")
      assert {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()

      # Scheme-less userinfo form is just as credentialed.
      put_named_env("HTTP_PROXY", "user:pass@proxy.example.com:8080")
      assert {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()

      # Token-only userinfo (no password segment) is still a credential.
      put_named_env("HTTP_PROXY", "http://token@proxy.example.com:8080")
      assert {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()

      put_named_env("HTTP_PROXY", "token@proxy.example.com:8080")
      assert {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()

      # An `@` past the authority — in the path or query — is not
      # userinfo and must not drop the var.
      put_named_env("HTTP_PROXY", "http://proxy.example.com:8080/p@th")
      refute {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()

      put_named_env("HTTP_PROXY", "http://proxy.example.com?x=a@b")
      refute {"HTTP_PROXY", nil} in Env.scrubbed_cmd_env()
    end

    test "app-config extension surface admits extra vars" do
      name = put_fake_secret("DIR")

      Application.put_env(:jido_claw, :extra_allowed_env_vars, [name])
      on_exit(fn -> Application.delete_env(:jido_claw, :extra_allowed_env_vars) end)

      refute {name, nil} in Env.scrubbed_cmd_env()
    end

    test "app-config prefix extension surface admits prefixed vars" do
      put_named_env("JIDO_KEEP_ME", "1")

      Application.put_env(:jido_claw, :extra_allowed_env_prefixes, ["JIDO_KEEP_"])
      on_exit(fn -> Application.delete_env(:jido_claw, :extra_allowed_env_prefixes) end)

      refute {"JIDO_KEEP_ME", nil} in Env.scrubbed_cmd_env()
    end

    test "JIDOCLAW_EXTRA_ALLOWED_ENV_VARS System env extension admits extra vars" do
      name_a = put_fake_secret("DIR")
      name_b = put_fake_secret("DIR")

      # Messy formatting — spaces and a trailing comma — parses predictably.
      put_named_env("JIDOCLAW_EXTRA_ALLOWED_ENV_VARS", " #{name_a}, #{name_b},")

      result = Env.scrubbed_cmd_env()

      refute {name_a, nil} in result
      refute {name_b, nil} in result
    end

    test "an override with a sensitive name wins — no unset tuple emitted" do
      name = put_fake_secret("TOKEN")

      result = Env.scrubbed_cmd_env(%{name => "re-added"})

      assert {name, "re-added"} in result
      refute {name, nil} in result
      assert Enum.count(result, fn {key, _} -> key == name end) == 1
    end

    test "non-sensitive overrides pass through with keys/values coerced to strings" do
      assert {"SOME_PORT", "5432"} in Env.scrubbed_cmd_env(%{SOME_PORT: 5432})
    end

    test "explicit nil override value is preserved as an unset" do
      assert {"FORCE_UNSET_VAR", nil} in Env.scrubbed_cmd_env(%{"FORCE_UNSET_VAR" => nil})
    end
  end

  describe "scrubbed_port_env/1" do
    test "emits charlist/false unset tuples for sensitive vars" do
      name = put_fake_secret("TOKEN")

      assert {String.to_charlist(name), false} in Env.scrubbed_port_env()
    end

    test "overrides win over the scrub and are charlist-coerced" do
      name = put_fake_secret("TOKEN")
      charlist_name = String.to_charlist(name)

      result = Env.scrubbed_port_env(%{name => "re-added"})

      assert {charlist_name, ~c"re-added"} in result
      refute {charlist_name, false} in result
    end

    test "explicit nil override value becomes false (unset)" do
      assert {~c"FORCE_UNSET_VAR", false} in Env.scrubbed_port_env(%{"FORCE_UNSET_VAR" => nil})
    end
  end

  defp put_fake_secret(suffix) do
    name = "JIDO_TEST_#{System.unique_integer([:positive])}_#{suffix}"
    System.put_env(name, "fake-secret-value")
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  # For tests that need a REAL var name (SECRET_KEY_BASE, HTTP_PROXY, ...):
  # save and restore any pre-existing value instead of blindly deleting.
  defp put_named_env(name, value) do
    original = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        prior -> System.put_env(name, prior)
      end
    end)

    name
  end
end
