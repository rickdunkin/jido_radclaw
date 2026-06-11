defmodule JidoClaw.Trace.SanitizeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Trace.Sanitize

  describe "payload/1 — sensitive key redaction" do
    test "redacts exact-match sensitive keys" do
      for key <- [
            :api_key,
            :apikey,
            :password,
            :secret,
            :token,
            :auth_token,
            :authtoken,
            :private_key,
            :privatekey,
            :access_key,
            :accesskey,
            :bearer,
            :api_secret,
            :apisecret,
            :client_secret,
            :clientsecret
          ] do
        assert Sanitize.payload(%{key => "supersecret"}) == %{key => "[REDACTED]"}
      end
    end

    test "redacts keys ending in known suffixes (_secret, _key, _token, _password)" do
      assert Sanitize.payload(%{my_secret: "x"}) == %{my_secret: "[REDACTED]"}
      assert Sanitize.payload(%{primary_key: "x"}) == %{primary_key: "[REDACTED]"}
      assert Sanitize.payload(%{user_token: "x"}) == %{user_token: "[REDACTED]"}
      assert Sanitize.payload(%{admin_password: "x"}) == %{admin_password: "[REDACTED]"}
    end

    test "redacts keys containing 'secret_' substring" do
      assert Sanitize.payload(%{secret_value: "x"}) == %{secret_value: "[REDACTED]"}
    end

    test "redacts string keys with the same rules" do
      assert Sanitize.payload(%{"api_key" => "x"}) == %{"api_key" => "[REDACTED]"}
      assert Sanitize.payload(%{"AUTH_TOKEN" => "x"}) == %{"AUTH_TOKEN" => "[REDACTED]"}
    end
  end

  describe "payload/1 — large key omission" do
    test "omits known large keys, including :params" do
      for key <- [
            :arguments,
            :context,
            :data,
            :llm_opts,
            :messages,
            :params,
            :prompt,
            :query,
            :raw,
            :raw_request,
            :raw_response,
            :request,
            :request_opts,
            :response,
            :result,
            :stacktrace,
            :state
          ] do
        assert Sanitize.payload(%{key => %{very: "large"}}) == %{key => "[OMITTED]"}
      end
    end

    test "recurses into nested maps to apply omission" do
      input = %{outer: %{prompt: "huge", child: %{params: %{deep: true}}}}

      assert Sanitize.payload(input) ==
               %{outer: %{prompt: "[OMITTED]", child: %{params: "[OMITTED]"}}}
    end

    test "omits content-bearing keys from jido_ai Turn-shaped metadata" do
      for key <- ["content", "input", "output", "text", "thinking_content"] do
        assert Sanitize.payload(%{key => "conversation body"}) == %{key => "[OMITTED]"},
               "expected top-level #{inspect(key)} to be omitted"

        assert Sanitize.payload(%{"outer" => %{key => "conversation body"}}) ==
                 %{"outer" => %{key => "[OMITTED]"}},
               "expected nested #{inspect(key)} to be omitted"
      end
    end

    test "omits content-bearing atom keys" do
      assert Sanitize.payload(%{thinking_content: "chain of thought"}) ==
               %{thinking_content: "[OMITTED]"}
    end

    test "recurses into lists of maps" do
      input = [%{token: "x"}, %{normal: 1}]

      assert Sanitize.payload(input) ==
               [%{token: "[REDACTED]"}, %{normal: 1}]
    end
  end

  describe "payload/1 — benign passthrough" do
    test "passes through plain values" do
      assert Sanitize.payload(%{foo: 1, bar: "ok"}) == %{foo: 1, bar: "ok"}
    end

    test "stringifies pids and funs" do
      pid = self()
      fun = fn -> :ok end

      out = Sanitize.payload(%{a: pid, b: fun})
      assert is_binary(out.a)
      assert is_binary(out.b)
    end
  end

  describe "preview/2" do
    test "slices strings to the configured byte budget" do
      assert Sanitize.preview("hello world", 5) == "hello"
    end

    test "inspects non-binary values with bounded output" do
      preview = Sanitize.preview(%{token: "should-redact", x: 1}, 200)

      assert is_binary(preview)
      assert preview =~ "[REDACTED]"
    end
  end
end
