defmodule JidoClaw.VFS.WorkspaceSupervisor do
  @moduledoc """
  DynamicSupervisor for `JidoClaw.VFS.Workspace` processes.

  One workspace per `workspace_id`, started lazily by
  `JidoClaw.VFS.Workspace.ensure_started/2` and torn down by
  `JidoClaw.VFS.Workspace.teardown/1`.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
