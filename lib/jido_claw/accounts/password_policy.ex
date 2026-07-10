defmodule JidoClaw.Accounts.PasswordPolicy do
  @moduledoc """
  Shared password input bounds for bcrypt-backed authentication.

  `AshAuthentication.BcryptProvider` only distinguishes the first 72 bytes.
  Every action and transport boundary must reject a larger candidate before it
  reaches the provider, including multibyte UTF-8 strings with fewer than 72
  characters.
  """

  @bcrypt_max_bytes 72

  @spec bcrypt_max_bytes() :: 72
  def bcrypt_max_bytes, do: @bcrypt_max_bytes
end
