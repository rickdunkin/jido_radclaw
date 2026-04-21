defmodule JidoClaw.Security.Redaction.EnvTest do
  use ExUnit.Case, async: true

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
end
