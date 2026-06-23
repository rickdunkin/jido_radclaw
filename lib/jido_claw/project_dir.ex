defmodule JidoClaw.ProjectDir do
  @moduledoc """
  The single project root this node operates against.

  Boot (`JidoClaw.Application`), the skills/strategies/pipelines caches, and the
  AR-8b-2 retention sweep all key on it. Exists so callers outside
  `JidoClaw.Application` (which keeps a *private* `project_dir/0`) can reach the
  root without duplicating the env read.
  """

  @doc "The configured project root, defaulting to the current working directory."
  @spec current() :: String.t()
  def current, do: Application.get_env(:jido_claw, :project_dir, File.cwd!())
end
