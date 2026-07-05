defmodule JidoClaw.Security.Redaction.MemoryTest do
  @moduledoc """
  Pins the sensitive-key subsumption contract of `redact_metadata/1`:
  the `@sensitive_keys` matcher is `String.contains?`-based, so the
  short forms (`token`, `credential`) must keep covering the long
  forms (`auth_token`, `credentials`) that were dropped from the list.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Memory

  describe "redact_metadata/1 sensitive-key subsumption" do
    test "token/credential short forms cover auth_token/credentials" do
      metadata = %{
        "token" => "tok-1",
        "auth_token" => "tok-2",
        "credential" => "cred-1",
        "credentials" => "cred-2"
      }

      assert Memory.redact_metadata(metadata) == %{
               "token" => "[REDACTED:METADATA_VALUE]",
               "auth_token" => "[REDACTED:METADATA_VALUE]",
               "credential" => "[REDACTED:METADATA_VALUE]",
               "credentials" => "[REDACTED:METADATA_VALUE]"
             }
    end

    test "atom keys and uppercase keys still match" do
      assert Memory.redact_metadata(%{auth_token: "x"}) ==
               %{auth_token: "[REDACTED:METADATA_VALUE]"}

      assert Memory.redact_metadata(%{"AUTH_TOKEN" => "x"}) ==
               %{"AUTH_TOKEN" => "[REDACTED:METADATA_VALUE]"}
    end

    test "non-sensitive keys pass values through" do
      assert Memory.redact_metadata(%{"note" => "plain"}) == %{"note" => "plain"}
    end
  end
end
