defmodule JidoClaw.Security.Redaction.PatternsTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Patterns

  describe "redact/1" do
    test "redacts Anthropic key with the ANTHROPIC label, NOT the generic API_KEY label" do
      input = "leaked: sk-ant-aaaabbbbccccddddeeeeffff key"
      redacted = Patterns.redact(input)

      assert redacted =~ "[REDACTED:ANTHROPIC_KEY]"
      refute redacted =~ "[REDACTED:API_KEY]"
      refute redacted =~ "sk-ant-aaaabbbbccccddddeeeeffff"
    end

    test "redacts generic OpenAI-style sk-... when not Anthropic-prefixed" do
      input = "leaked: sk-abcdefghijklmnopqrstuvwx key"
      redacted = Patterns.redact(input)

      assert redacted =~ "[REDACTED:API_KEY]"
      refute redacted =~ "sk-abcdefghijklmnopqrstuvwx"
    end

    test "Anthropic-and-generic in the same string both redact correctly" do
      input = "ant=sk-ant-AAAAAAAAAAAAAAAAAAAA generic=sk-BBBBBBBBBBBBBBBBBBBB"
      redacted = Patterns.redact(input)

      assert redacted =~ "ant=[REDACTED:ANTHROPIC_KEY]"
      assert redacted =~ "generic=[REDACTED:API_KEY]"
    end

    test "redacts JidoClaw API keys" do
      assert Patterns.redact("k=jidoclaw_aaaaaaaaaaaaaaaaaaaaaa") =~ "[REDACTED:JIDOCLAW_KEY]"
    end

    test "redacts GitHub PATs (both ghp_ and github_pat_ shapes)" do
      assert Patterns.redact("t=ghp_abcdefghijklmnopqrstuvwxyz1234567890") =~
               "[REDACTED:GITHUB_PAT]"

      assert Patterns.redact("t=github_pat_abcdefghijklmnopqrst") =~ "[REDACTED:GITHUB_PAT]"
    end

    test "redacts Bearer tokens preserving the Bearer prefix" do
      redacted = Patterns.redact("Authorization: Bearer abcdef0123456789abcdef")
      assert redacted =~ "Bearer [REDACTED]"
      refute redacted =~ "abcdef0123456789abcdef"
    end

    test "redacts JWTs" do
      jwt =
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"

      assert Patterns.redact(jwt) == "[REDACTED:JWT]"
    end

    test "redacts AWS access key IDs" do
      assert Patterns.redact("AKIAIOSFODNN7EXAMPLE") =~ "[REDACTED:AWS_KEY]"
    end

    test "redacts URL userinfo (lifted from Redaction.Env)" do
      input = "conn=postgres://alice:hunter2@db.local:5432/app"
      redacted = Patterns.redact(input)

      assert redacted =~ "postgres://alice:[REDACTED]@db.local"
      refute redacted =~ "hunter2"
    end

    test "passes non-binary input through unchanged" do
      assert Patterns.redact(42) == 42
      assert Patterns.redact(:atom) == :atom
      assert Patterns.redact(nil) == nil
      assert Patterns.redact(%{a: 1}) == %{a: 1}
    end

    test "is idempotent — re-redacting an already-redacted string is a no-op" do
      once = Patterns.redact("sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA")
      twice = Patterns.redact(once)
      assert once == twice
    end

    test "preserves benign content byte-equivalent" do
      benign = "client.api_base_url and route /v1/users"
      assert Patterns.redact(benign) == benign
    end
  end

  describe "redact_with_count/1" do
    test "returns 0 when no patterns fire" do
      assert {"hello world", 0} = Patterns.redact_with_count("hello world")
    end

    test "counts firings across multiple distinct patterns in one string" do
      input = "ant=sk-ant-AAAAAAAAAAAAAAAAAAAA aws=AKIAIOSFODNN7EXAMPLE"
      {redacted, count} = Patterns.redact_with_count(input)

      assert count >= 2
      assert redacted =~ "[REDACTED:ANTHROPIC_KEY]"
      assert redacted =~ "[REDACTED:AWS_KEY]"
    end

    test "passes non-binary input through with count 0" do
      assert {42, 0} = Patterns.redact_with_count(42)
      assert {nil, 0} = Patterns.redact_with_count(nil)
    end
  end
end
