defmodule JidoClaw.Trace.PolicyTest.TStruct do
  @moduledoc false
  defstruct [:token, :name]
end

defmodule JidoClaw.Trace.PolicyTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Trace.Policy
  alias JidoClaw.Trace.PolicyTest.TStruct

  # A 24-char run after `sk-ant-api03-` clears Patterns' 20+ length floor.
  @anthropic_secret "Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"

  describe "keep_trace?/2" do
    test "is deterministic for a given key + rate" do
      policy = %{Policy.default() | sample_rate: 0.5}
      key = {:request, "deterministic-key"}

      decisions = for _ <- 1..200, do: Policy.keep_trace?(policy, key)
      # A single distinct decision ⇒ deterministic for this key + rate.
      assert [_] = Enum.uniq(decisions)
    end

    test "sample_rate 1.0 keeps every key, 0.0 drops every key" do
      keep_all = Policy.default()
      drop_all = %{Policy.default() | sample_rate: 0.0}

      for i <- 1..50 do
        key = {:request, "k-#{i}"}
        assert Policy.keep_trace?(keep_all, key)
        refute Policy.keep_trace?(drop_all, key)
      end
    end
  end

  describe "scrub/2 — key redaction" do
    test "omits large keys" do
      assert Policy.scrub(Policy.default(), %{params: %{a: 1}, prompt: "huge"}) ==
               %{params: "[OMITTED]", prompt: "[OMITTED]"}
    end

    test "redacts curated exact + suffix + contains keys" do
      assert Policy.scrub(Policy.default(), %{api_key: "x"}) == %{api_key: "[REDACTED]"}
      assert Policy.scrub(Policy.default(), %{user_token: "x"}) == %{user_token: "[REDACTED]"}
      assert Policy.scrub(Policy.default(), %{secret_value: "x"}) == %{secret_value: "[REDACTED]"}
    end

    test "redacts the 7 unseparated compound keys not covered by Env" do
      for key <- [
            :apikey,
            :authtoken,
            :privatekey,
            :accesskey,
            :bearer,
            :apisecret,
            :clientsecret
          ] do
        assert Policy.scrub(Policy.default(), %{key => "x"}) == %{key => "[REDACTED]"},
               "expected #{inspect(key)} to be redacted"
      end
    end

    test "redacts Env-only keys (authorization, credential)" do
      assert Policy.scrub(Policy.default(), %{authorization: "Basic x"}) ==
               %{authorization: "[REDACTED]"}

      assert Policy.scrub(Policy.default(), %{credential: "x"}) == %{credential: "[REDACTED]"}
    end
  end

  describe "scrub/2 — value redaction + serialization safety" do
    test "scrubs secrets embedded in a non-redacted string value" do
      out = Policy.scrub(Policy.default(), %{note: @anthropic_secret})
      refute out.note =~ "sk-ant-api03"
      assert out.note =~ "[REDACTED"
    end

    test "redacts secrets inside an invalid (non-UTF-8) binary without crashing" do
      blob = <<0xFF, 0xFE>> <> "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA"
      out = Policy.scrub(Policy.default(), %{blob: blob})

      assert is_binary(out.blob)
      assert String.valid?(out.blob)
      refute out.blob =~ "sk-ant-api03"
    end

    test "key-redacts struct fields (not inspect/1, which would leak)" do
      out = Policy.scrub(Policy.default(), %TStruct{token: "x", name: "ok"})
      assert out == %{token: "[REDACTED]", name: "ok"}
    end

    test "converts tuples to scrubbed lists, closing tuple-nested secret leaks" do
      out = Policy.scrub(Policy.default(), %{outcome: {:error, @anthropic_secret}})
      assert [:error, scrubbed] = out.outcome
      refute scrubbed =~ "sk-ant-api03"
    end

    test "stringifies pids, funs, refs, and ports via inspect" do
      port = Port.open({:spawn, "cat"}, [:binary])

      try do
        out =
          Policy.scrub(Policy.default(), %{a: self(), b: fn -> :ok end, c: make_ref(), d: port})

        assert is_binary(out.a)
        assert is_binary(out.b)
        assert is_binary(out.c)
        assert is_binary(out.d)
      after
        Port.close(port)
      end
    end

    test "recurses into nested maps and lists" do
      input = %{outer: %{prompt: "huge", items: [%{token: "x"}, %{ok: 1}]}}

      assert Policy.scrub(Policy.default(), input) ==
               %{outer: %{prompt: "[OMITTED]", items: [%{token: "[REDACTED]"}, %{ok: 1}]}}
    end

    test "passes through benign scalars unchanged" do
      assert Policy.scrub(Policy.default(), %{foo: 1, bar: "ok", flag: true, nada: nil}) ==
               %{foo: 1, bar: "ok", flag: true, nada: nil}
    end
  end

  describe "from_config/1" do
    test "layers extra omit/redact keys additively (case-insensitive) onto the floor" do
      policy =
        Policy.from_config(
          extra_omit_keys: [:custom_blob, "OtherBlob"],
          extra_redact_keys: ["x_custom"]
        )

      # built-in floor preserved
      assert Policy.scrub(policy, %{params: %{a: 1}}) == %{params: "[OMITTED]"}
      assert Policy.scrub(policy, %{api_key: "x"}) == %{api_key: "[REDACTED]"}
      # extra omit (atom + mixed-case string both normalized)
      assert Policy.scrub(policy, %{custom_blob: %{a: 1}}) == %{custom_blob: "[OMITTED]"}
      assert Policy.scrub(policy, %{"OtherBlob" => "y"}) == %{"OtherBlob" => "[OMITTED]"}
      # extra redact
      assert Policy.scrub(policy, %{x_custom: "y"}) == %{x_custom: "[REDACTED]"}
    end

    test "coerces integer sample_rate and clamps out-of-range values" do
      assert Policy.from_config(sample_rate: 1).sample_rate == 1.0
      assert Policy.from_config(sample_rate: 5).sample_rate == 1.0
      assert Policy.from_config(sample_rate: -1).sample_rate == 0.0
      assert Policy.from_config(sample_rate: 0.25).sample_rate == 0.25
      assert Policy.from_config(sample_rate: "garbage").sample_rate == 1.0
    end

    test "accepts a map config as well as a keyword list" do
      assert Policy.from_config(%{sample_rate: 0.5}).sample_rate == 0.5
    end
  end
end
