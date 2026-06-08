defmodule JidoClaw.Setup.CredentialCheck do
  @moduledoc """
  Result of probing a single provider's API credential during setup:
  whether it is `configured?` (a key/token is present) and `valid?` (the
  key/token actually works), plus a human `provider` label.
  """
  @enforce_keys [:configured?, :valid?, :provider]
  defstruct [:configured?, :valid?, :provider]

  @type t :: %__MODULE__{
          configured?: boolean(),
          valid?: boolean(),
          provider: String.t()
        }
end
