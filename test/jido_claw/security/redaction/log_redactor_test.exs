defmodule JidoClaw.Security.Redaction.LogRedactorTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Security.Redaction.LogRedactor

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

    filters = :logger.get_primary_config() |> Map.fetch!(:filters)

    assert Keyword.has_key?(filters, :jidoclaw_redact_secrets)
  end
end
