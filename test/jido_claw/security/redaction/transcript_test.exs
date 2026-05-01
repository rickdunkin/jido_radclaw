defmodule JidoClaw.Security.Redaction.TranscriptTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Transcript

  describe "redact/2 — strings" do
    test "passes secrets through Patterns.redact" do
      input = "Bearer abcdef0123456789abcdef"
      assert Transcript.redact(input) =~ "Bearer [REDACTED]"
    end

    test "passes benign string byte-equivalent" do
      assert Transcript.redact("client.api_base_url") == "client.api_base_url"
    end
  end

  describe "redact/2 — maps" do
    test "replaces sensitive-key values with [REDACTED]" do
      input = %{
        "AWS_SECRET_ACCESS_KEY" => "AKIASMOKETEST1234567",
        "DATABASE_PASSWORD" => "hunter2",
        "name" => "alice"
      }

      out = Transcript.redact(input)

      assert out["AWS_SECRET_ACCESS_KEY"] == "[REDACTED]"
      assert out["DATABASE_PASSWORD"] == "[REDACTED]"
      assert out["name"] == "alice"
    end

    test "applies binary patterns to non-sensitive-key values" do
      input = %{"note" => "key: sk-ant-AAAAAAAAAAAAAAAAAAAA"}
      out = Transcript.redact(input)
      assert out["note"] =~ "[REDACTED:ANTHROPIC_KEY]"
    end

    test "atom keys also matched against sensitive-suffix list" do
      input = %{:my_secret => "leak", :name => "alice"}
      out = Transcript.redact(input)
      assert out[:my_secret] == "[REDACTED]"
      assert out[:name] == "alice"
    end
  end

  describe "redact/2 — lists" do
    test "recurses into list elements" do
      input = ["plain", "Bearer abcdef0123456789abcdef", %{"name" => "alice"}]
      [a, b, c] = Transcript.redact(input)
      assert a == "plain"
      assert b =~ "Bearer [REDACTED]"
      assert c == %{"name" => "alice"}
    end
  end

  describe "redact/2 — JSON-decode gating" do
    test "default :json_aware_keys [] preserves JSON-shaped strings byte-equivalent" do
      payload = ~s({"foo": "bar", "nested": {"baz": 1}})
      input = %{"content" => payload}

      out = Transcript.redact(input)

      # Without opt-in, the JSON string is treated as opaque content —
      # not decoded, not re-encoded.
      assert out["content"] == payload
    end

    test "with :json_aware_keys [\"arguments\"], decodes/recurses/re-encodes" do
      payload = ~s({"AWS_SECRET_ACCESS_KEY": "AKIASMOKETEST1234567", "user": "alice"})
      input = %{"arguments" => payload}

      out = Transcript.redact(input, json_aware_keys: ["arguments"])
      decoded = Jason.decode!(out["arguments"])

      assert decoded["AWS_SECRET_ACCESS_KEY"] == "[REDACTED]"
      assert decoded["user"] == "alice"
    end

    test "non-JSON value under a json-aware key falls back to Patterns.redact" do
      input = %{"arguments" => "not json sk-ant-AAAAAAAAAAAAAAAAAAAA"}
      out = Transcript.redact(input, json_aware_keys: ["arguments"])
      assert out["arguments"] =~ "[REDACTED:ANTHROPIC_KEY]"
    end

    test "json-aware applies only to direct-child string values, not deep" do
      # A nested "content" inside a non-aware parent should NOT decode
      # — the parent_key is the immediate map key.
      input = %{"outer" => %{"content" => ~s({"x": 1})}}
      out = Transcript.redact(input, json_aware_keys: [])
      assert out["outer"]["content"] == ~s({"x": 1})
    end
  end

  describe "idempotency" do
    test "running the redactor twice yields the same result" do
      input = %{
        "outer" => "Bearer abcdef0123456789abcdef",
        "AWS_SECRET_ACCESS_KEY" => "AKIASMOKETEST1234567",
        "list" => ["sk-ant-AAAAAAAAAAAAAAAAAAAA"]
      }

      once = Transcript.redact(input)
      twice = Transcript.redact(once)
      assert once == twice
    end
  end

  describe "non-recursable terms" do
    test "passes integers, atoms, nil through unchanged" do
      assert Transcript.redact(42) == 42
      assert Transcript.redact(:foo) == :foo
      assert Transcript.redact(nil) == nil
    end
  end
end
