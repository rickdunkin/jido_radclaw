defmodule JidoClaw.Security.Redaction.PromptRedactionTest do
  @moduledoc """
  The vendor-CLI prompt-egress redactor (item 7 PR-3): both clauses run the
  ANSI pre-pass before the pattern scan, so an escape-split secret is
  reassembled and caught — the `OutputRedaction` root's posture at egress.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.PromptRedaction

  @split_secret "creds: sk-ant-\e[0maaaabbbbccccddddeeeeffff done"

  test "a plain secret in a binary prompt is redacted" do
    redacted = PromptRedaction.redact("key sk-ant-aaaabbbbccccddddeeeeffff here")

    assert redacted =~ "[REDACTED:ANTHROPIC_KEY]"
    refute redacted =~ "aaaabbbbccccddddeeeeffff"
  end

  test "an ANSI-split secret is reassembled and redacted (the PR-3 pre-pass)" do
    redacted = PromptRedaction.redact(@split_secret)

    assert redacted =~ "[REDACTED:ANTHROPIC_KEY]"
    refute redacted =~ "aaaabbbbccccddddeeeeffff"
    refute redacted =~ "\e["
  end

  test "message-list contents get the same pre-pass (string and atom keys)" do
    messages = [
      %{"role" => "user", "content" => @split_secret},
      %{role: :system, content: @split_secret},
      %{"role" => "tool", "content" => %{not: "a binary"}}
    ]

    assert [string_keyed, atom_keyed, untouched] = PromptRedaction.redact(messages)

    assert string_keyed["content"] =~ "[REDACTED:ANTHROPIC_KEY]"
    refute string_keyed["content"] =~ "aaaabbbbccccddddeeeeffff"
    assert atom_keyed.content =~ "[REDACTED:ANTHROPIC_KEY]"
    refute atom_keyed.content =~ "aaaabbbbccccddddeeeeffff"
    assert untouched == %{"role" => "tool", "content" => %{not: "a binary"}}
  end

  test "non-binary, non-list input passes through untouched" do
    assert PromptRedaction.redact(nil) == nil
    assert PromptRedaction.redact(%{a: 1}) == %{a: 1}
    assert PromptRedaction.redact(42) == 42
  end
end
