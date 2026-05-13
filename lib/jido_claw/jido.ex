defmodule JidoClaw.Jido do
  @moduledoc """
  Top-level Jido agent runtime entry for JidoClaw.

  Hooks the application into the Jido framework via `use Jido`, providing
  the agent supervision tree, signal routing, and skill plumbing that the
  rest of the system builds on. Started early in `JidoClaw.Application`'s
  core children list.
  """

  use Jido, otp_app: :jido_claw
end
