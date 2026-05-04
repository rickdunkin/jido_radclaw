defmodule JidoClaw.Conversations.SessionId do
  @moduledoc """
  Pure helper for generating REPL/session-string identifiers.

  This module exists only to host the legacy `new_session_id/0` after
  the JSONL writer in `JidoClaw.Session` (`lib/jido_claw/platform/session.ex`)
  was retired in favor of the Postgres-backed `Conversations.Message`
  resource. The REPL boot path still needs an external/string session
  id to register a `Session.Worker` GenServer in `JidoClaw.SessionRegistry`,
  so this helper keeps the legacy ID format (`session_<unix_ts>`) intact.
  """

  @doc """
  Generate a new session string of the form
  `session_<utc_timestamp_with_no_separators>`.
  """
  @spec new() :: String.t()
  def new do
    now = NaiveDateTime.utc_now()
    "session_#{NaiveDateTime.to_iso8601(now) |> String.replace(~r/[^0-9]/, "")}"
  end
end
