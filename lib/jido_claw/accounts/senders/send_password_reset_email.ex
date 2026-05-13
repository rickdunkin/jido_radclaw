defmodule JidoClaw.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc false
  use AshAuthentication.Sender

  @impl true
  def send(_user, _token, _opts) do
    # TODO: implement email sending
    :ok
  end
end
