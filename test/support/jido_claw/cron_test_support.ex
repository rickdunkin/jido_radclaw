defmodule JidoClaw.Cron.TestSupport do
  @moduledoc """
  Test seam for `Cron.Worker` failure modes.

  `always_fail/0` returns `{:error, :forced}` deterministically and is
  used by `cron/persistent_disable_test.exs` to drive the 3-failure
  auto-disable path without involving the agent runtime.

  Lives under `test/support/` so it ships only with `MIX_ENV=test`.
  """

  @spec always_fail() :: {:error, :forced}
  def always_fail, do: {:error, :forced}
end
