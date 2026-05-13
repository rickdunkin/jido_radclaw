defmodule JidoClaw.Secrets do
  @moduledoc false
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], _resource, _opts, _context) do
    case Application.get_env(:jido_claw, :token_signing_secret) do
      nil -> :error
      secret -> {:ok, secret}
    end
  end
end
