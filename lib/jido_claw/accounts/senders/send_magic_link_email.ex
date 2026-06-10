defmodule JidoClaw.Accounts.User.Senders.SendMagicLinkEmail do
  @moduledoc false
  use AshAuthentication.Sender

  @impl AshAuthentication.Sender
  def send(_user, _token, _opts) do
    # Deliberate no-op: JidoClaw ships no mailer, so the token is dropped
    # and the email-based flow cannot complete.
    :ok
  end
end
