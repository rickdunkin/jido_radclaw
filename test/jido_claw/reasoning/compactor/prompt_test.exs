defmodule JidoClaw.Reasoning.Compactor.PromptTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Compactor.Prompt

  describe "default_text/0" do
    test "is non-empty and instructs the model to compress" do
      text = Prompt.default_text()

      assert is_binary(text)
      assert byte_size(text) > 200
      assert String.contains?(text, "compress")
      assert String.contains?(text, "summary")
    end
  end

  describe "build/3" do
    test "includes the transcript and instructions and char budget" do
      prompt = Prompt.build("user: hello\nassistant: hi", nil, 4_000)

      assert String.contains?(prompt, "user: hello")
      assert String.contains?(prompt, "assistant: hi")
      assert String.contains?(prompt, "4000 characters")
      refute String.contains?(prompt, "Prior summary")
    end

    test "embeds a prior summary when provided" do
      prompt = Prompt.build("u: hi", "Previous turn we discussed X", 2_000)

      assert String.contains?(prompt, "Prior summary")
      assert String.contains?(prompt, "Previous turn we discussed X")
    end

    test "ignores empty prior summary" do
      prompt = Prompt.build("u: hi", "", 1_000)
      refute String.contains?(prompt, "Prior summary")
    end
  end
end
