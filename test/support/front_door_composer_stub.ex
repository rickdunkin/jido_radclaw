defmodule JidoClaw.Test.FrontDoorComposerStub do
  @moduledoc """
  Test seam for the front door's composer launcher (`:front_door_composer`).

  Delegates to the real `JidoClaw.RouteComposer` unless `:front_door_create_mode`
  forces a `create_parent_run/1` branch — letting a test exercise the P1
  no-fall-through (a failed launch returns a bounded ack and never reaches the
  inline agent) and the R3-P1 orphan cleanup, without depending on a real launch
  failing:

    * `:delegate` (default) — real `create_parent_run/1`.
    * `:error` — returns `{:error, {:start_failed, :forced}}` (no parent created).
    * `{:return, parent}` — returns `{:ok, parent}`; the test pre-creates the parent
      (e.g. a malformed-catalog one) so the REAL `ensure_started/2` then fails and
      terminalizes it.

  `:front_door_ensure_mode` controls `ensure_started/2`:

    * `:delegate` (default) — real `ensure_started/2` (R3-P1 needs its real
      `terminalize_on_failure?` behavior).
    * `:noop` — returns `{:ok, self()}` WITHOUT starting the GenServer, so a test can
      assert the seeded parent (config + genesis events) the real `create_parent_run`
      wrote, without running real wave workers.
    * `:error` — returns `{:error, {:start_failed, :forced_ensure}}`.
  """

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer

  @spec create_parent_run(keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def create_parent_run(opts) do
    case Application.get_env(:jido_claw, :front_door_create_mode, :delegate) do
      :error -> {:error, {:start_failed, :forced}}
      {:return, parent} -> {:ok, parent}
      :delegate -> RouteComposer.create_parent_run(opts)
    end
  end

  @spec ensure_started(keyword(), WorkflowRun.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts, parent) do
    case Application.get_env(:jido_claw, :front_door_ensure_mode, :delegate) do
      :noop -> {:ok, self()}
      :error -> {:error, {:start_failed, :forced_ensure}}
      :delegate -> RouteComposer.ensure_started(opts, parent)
    end
  end
end
