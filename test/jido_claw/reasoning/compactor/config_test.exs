defmodule JidoClaw.Reasoning.Compactor.ConfigTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Error.ValidationError
  alias JidoClaw.Reasoning.Compactor.Config

  describe "default/0" do
    test "returns auto-mode config with sane defaults" do
      cfg = Config.default()

      assert cfg.mode == :auto
      assert cfg.strategy == :summary
      assert cfg.max_messages == 60
      assert cfg.recompact_delta_threshold == 30
      assert cfg.keep_last_turns == 6
      assert cfg.protect_first_n_turns == 2
      assert cfg.max_summary_chars == 4_000
      assert cfg.summarizer_timeout_ms == 15_000
      assert cfg.summarizer_model == nil
      assert cfg.summarizer_max_retries == 1
      assert cfg.summarizer_retry_backoff_ms == 250
    end
  end

  describe "off/0" do
    test "returns mode :off but otherwise valid config" do
      cfg = Config.off()

      assert cfg.mode == :off
      assert cfg.strategy == :summary
      assert cfg.summarizer_max_retries == 1
      assert cfg.summarizer_retry_backoff_ms == 250
      assert :ok = Config.validate(cfg)
    end
  end

  describe "new/1" do
    test "accepts a keyword list of overrides" do
      assert {:ok, cfg} = Config.new(mode: :manual, max_messages: 40)
      assert cfg.mode == :manual
      assert cfg.max_messages == 40
      # other defaults preserved
      assert cfg.keep_last_turns == 6
    end

    test "accepts a map of overrides" do
      assert {:ok, cfg} = Config.new(%{mode: :off, keep_last_turns: 3})
      assert cfg.mode == :off
      assert cfg.keep_last_turns == 3
    end

    test "defaults recompact_delta_threshold to half of max_messages" do
      assert {:ok, cfg} =
               Config.new(
                 max_messages: 100,
                 recompact_delta_threshold: :auto,
                 keep_last_turns: 6,
                 protect_first_n_turns: 2
               )

      assert cfg.recompact_delta_threshold == 50
    end

    test "derives recompact_delta_threshold when only max_messages is overridden" do
      assert Config.new!(max_messages: 100).recompact_delta_threshold == 50
    end

    test "derives floor(max_messages/2) when max_messages is odd" do
      cfg =
        Config.new!(
          max_messages: 7,
          keep_last_turns: 1,
          protect_first_n_turns: 0
        )

      assert cfg.recompact_delta_threshold == 3
    end

    test "derived recompact_delta_threshold has a floor of 1" do
      cfg =
        Config.new!(
          max_messages: 2,
          keep_last_turns: 1,
          protect_first_n_turns: 0
        )

      assert cfg.recompact_delta_threshold == 1
    end

    test "explicit recompact_delta_threshold wins over derivation" do
      assert Config.new!(max_messages: 100, recompact_delta_threshold: 11).recompact_delta_threshold ==
               11
    end

    test "leaves recompact_delta_threshold at the default when max_messages is not overridden" do
      assert Config.new!(keep_last_turns: 6).recompact_delta_threshold == 30
    end
  end

  describe "validate/1" do
    test "rejects unknown mode" do
      assert {:error, %ValidationError{}} = Config.new(mode: :nope)
    end

    test "rejects unsupported strategy" do
      assert {:error, %ValidationError{}} = Config.new(strategy: :smart)
    end

    test "rejects non-positive max_messages" do
      assert {:error, %ValidationError{}} = Config.new(max_messages: 0)
    end

    test "rejects non-positive keep_last_turns" do
      assert {:error, %ValidationError{}} = Config.new(keep_last_turns: 0)
    end

    test "rejects capacity violation" do
      assert {:error, %ValidationError{}} =
               Config.new(
                 max_messages: 10,
                 keep_last_turns: 6,
                 protect_first_n_turns: 5
               )
    end

    test "rejects negative protect_first_n_turns" do
      assert {:error, %ValidationError{}} = Config.new(protect_first_n_turns: -1)
    end

    test "rejects non-positive max_summary_chars" do
      assert {:error, %ValidationError{}} = Config.new(max_summary_chars: 0)
    end

    test "rejects non-positive summarizer_timeout_ms" do
      assert {:error, %ValidationError{}} = Config.new(summarizer_timeout_ms: 0)
    end

    test "rejects negative summarizer_max_retries" do
      assert {:error, %ValidationError{}} = Config.new(summarizer_max_retries: -1)
    end

    test "accepts zero summarizer_max_retries (retries disabled)" do
      assert {:ok, cfg} = Config.new(summarizer_max_retries: 0)
      assert cfg.summarizer_max_retries == 0
    end

    test "rejects non-positive summarizer_retry_backoff_ms" do
      assert {:error, %ValidationError{}} = Config.new(summarizer_retry_backoff_ms: 0)
    end

    test "validates existing struct" do
      cfg = Config.default()
      assert :ok = Config.validate(cfg)
    end
  end

  describe "new!/1" do
    test "raises on invalid input" do
      assert_raise ValidationError, fn -> Config.new!(mode: :bogus) end
    end

    test "returns Config on valid input" do
      assert %Config{mode: :auto} = Config.new!(mode: :auto)
    end
  end
end
