defmodule JidoClaw.Security.Redaction.EmbeddingTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Embedding

  test "returns {redacted, count} for a clean string" do
    assert {"hello world", 0} = Embedding.redact("hello world")
  end

  test "counts a redaction firing" do
    {redacted, count} = Embedding.redact("Bearer abcdef0123456789abcdef")
    assert count == 1
    assert redacted =~ "[REDACTED]"
  end

  test "non-binary input returns {term, 0}" do
    assert {nil, 0} = Embedding.redact(nil)
    assert {[1, 2], 0} = Embedding.redact([1, 2])
  end
end
