defmodule JidoClaw.Accounts.Checks.RegistrationAllowed do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "registration is allowed"

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, _context, _opts), do: true
end
