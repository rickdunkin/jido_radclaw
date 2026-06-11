defmodule JidoClaw.Security.Redaction.LogRedactorTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.LogRedactor

  defp filter(msg, meta \\ %{}) do
    LogRedactor.filter(%{level: :info, msg: msg, meta: meta}, [])
  end

  test "redacts string log events" do
    event = %{
      level: :info,
      msg: {:string, "token sk-abcdefghijklmnopqrstuvwxyz01"},
      meta: %{}
    }

    redacted = LogRedactor.filter(event, [])

    assert redacted.msg == {:string, "token [REDACTED:API_KEY]"}
  end

  test "install! registers an idempotent primary logger filter" do
    assert :ok = LogRedactor.install!()
    assert :ok = LogRedactor.install!()

    filters = Map.fetch!(:logger.get_primary_config(), :filters)

    assert Keyword.has_key?(filters, :jidoclaw_redact_secrets)
  end

  describe "meta redaction" do
    test "masks values under sensitive atom keys" do
      redacted = filter("msg", %{api_key: "sk-abcdefghijklmnopqrstuvwxyz01"})

      assert redacted.meta.api_key == "[REDACTED]"
    end

    test "scrubs embedded secrets in non-sensitive-keyed values" do
      redacted = filter("msg", %{note: "token sk-abcdefghijklmnopqrstuvwxyz01"})

      assert redacted.meta.note == "token [REDACTED:API_KEY]"
    end

    test "charlist values under non-skip keys are redacted as text" do
      redacted = filter("msg", %{note: ~c"token sk-abcdefghijklmnopqrstuvwxyz01"})

      assert redacted.meta.note == ~c"token [REDACTED:API_KEY]"
    end

    test "skip-set standard keys pass through byte-identical" do
      meta = %{file: ~c"/path/to/file.ex", mfa: {Foo, :bar, 1}, line: 42}

      redacted = filter("msg", meta)

      assert redacted.meta == meta
    end

    test "crash_reason is walked — nested GenServer state secrets are masked" do
      redacted =
        filter("msg", %{crash_reason: %{state: %{api_key: "sk-abcdefghijklmnopqrstuvwxyz01"}}})

      assert redacted.meta.crash_reason == %{state: %{api_key: "[REDACTED]"}}
    end

    test "tuple crash_reason keeps its shape with inner values masked" do
      redacted =
        filter("msg", %{
          crash_reason: {:badmatch, %{api_key: "sk-abcdefghijklmnopqrstuvwxyz01"}}
        })

      assert redacted.meta.crash_reason == {:badmatch, %{api_key: "[REDACTED]"}}
    end

    test "charlist inside a tuple crash_reason is redacted with the shape preserved" do
      redacted = filter("msg", %{crash_reason: {:badarg, ~c"sk-abcdefghijklmnopqrstuvwxyz01"}})

      assert redacted.meta.crash_reason == {:badarg, ~c"[REDACTED:API_KEY]"}
    end

    test "containers nested past the depth bound fail closed as [REDACTED:DEPTH]" do
      secret_container = %{api_key: "sk-abcdefghijklmnopqrstuvwxyz01"}
      meta = %{a: %{b: %{c: %{d: %{e: secret_container}}}}}

      redacted = filter("msg", meta)

      assert get_in(redacted.meta, [:a, :b, :c, :d, :e]) == "[REDACTED:DEPTH]"
      refute inspect(redacted.meta) =~ "sk-abcdefghijklmnopqrstuvwxyz01"
    end
  end

  describe "report messages" do
    test "map report masks sensitive keys" do
      redacted = filter({:report, %{password: "hunter2"}})

      assert redacted.msg == {:report, %{password: "[REDACTED]"}}
    end

    test "binary-keyed report masks sensitive keys" do
      redacted = filter({:report, %{"api_key" => "sk-abcdefghijklmnopqrstuvwxyz01"}})

      assert redacted.msg == {:report, %{"api_key" => "[REDACTED]"}}
    end

    test "keyword report (OTP crash-report shape) walks nested state" do
      report = [
        pid: self(),
        registered_name: :my_server,
        state: %{api_key: "sk-abcdefghijklmnopqrstuvwxyz01", count: 3}
      ]

      redacted = filter({:report, report})

      assert {:report, walked} = redacted.msg
      assert walked[:pid] == self()
      assert walked[:registered_name] == :my_server
      assert walked[:state] == %{api_key: "[REDACTED]", count: 3}
    end
  end

  describe "format messages" do
    test "scrubs binary args, format untouched" do
      redacted = filter({"api_key=~s", ["sk-abcdefghijklmnopqrstuvwxyz01"]})

      assert redacted.msg == {"api_key=~s", ["[REDACTED:API_KEY]"]}
    end

    test "walks structured ~p args shape-preservingly" do
      redacted = filter({"state=~p", [%{api_key: "sk-abcdefghijklmnopqrstuvwxyz01"}]})

      assert redacted.msg == {"state=~p", [%{api_key: "[REDACTED]"}]}
    end

    test "benign structured args pass byte-identical" do
      msg = {"~p", [%{a: 1}]}

      assert filter(msg).msg == msg
    end

    test "redacts a literal secret in the format string itself" do
      redacted = filter({"token sk-abcdefghijklmnopqrstuvwxyz01 seen", []})

      assert redacted.msg == {"token [REDACTED:API_KEY] seen", []}
    end

    test "directives survive adjacent to sensitive-looking key names" do
      msg = {"token=~s, key=~p", ["short", :v]}

      assert filter(msg).msg == msg
    end

    test "width/precision/modifier directive variants survive redaction" do
      # Pins the full ~F.P.PadModC grammar against future regex narrowing.
      msg = {"token=~-10s pass=~10.5s name=~ts pct=~~", ["a", "b", "c"]}

      assert filter(msg).msg == msg
    end

    test "charlist formats stay charlists" do
      redacted = filter({~c"token sk-abcdefghijklmnopqrstuvwxyz01 via ~s", [~c"x"]})

      assert redacted.msg == {~c"token [REDACTED:API_KEY] via ~s", [~c"x"]}
    end

    test "charlist args are redacted and stay charlists" do
      redacted = filter({"token=~s", [~c"sk-abcdefghijklmnopqrstuvwxyz01"]})

      assert redacted.msg == {"token=~s", [~c"[REDACTED:API_KEY]"]}
    end

    test "benign charlist and plain integer-list args pass byte-identical" do
      charlist_msg = {"~s", [~c"hello"]}
      intlist_msg = {"~w", [[1, 2, 3]]}

      assert filter(charlist_msg).msg == charlist_msg
      assert filter(intlist_msg).msg == intlist_msg
    end

    test "non-codepoint integer args pass through without dropping the event" do
      msg = {"~w", [[999_999_999_999]]}

      redacted = filter(msg)

      assert redacted != :stop
      assert redacted.msg == msg
    end
  end
end
