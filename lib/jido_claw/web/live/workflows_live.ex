defmodule JidoClaw.Web.WorkflowsLive do
  use JidoClaw.Web, :live_view

  require Logger

  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep

  @impl true
  def mount(_params, _session, socket) do
    {runs, runs_error} =
      list_runs(socket)

    {:ok,
     assign(socket,
       page_title: "Workflows",
       runs: runs,
       runs_error: runs_error,
       expanded_run_id: nil,
       steps: [],
       steps_error: nil
     )}
  end

  @impl true
  def handle_event("toggle_steps", %{"id" => run_id}, socket) do
    if socket.assigns.expanded_run_id == run_id do
      {:noreply, assign(socket, expanded_run_id: nil, steps: [], steps_error: nil)}
    else
      {steps, steps_error} = list_steps(socket, run_id)
      {:noreply, assign(socket, expanded_run_id: run_id, steps: steps, steps_error: steps_error)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem;">
        <h1 style="font-size: 1.5rem; font-weight: 700;">Workflows</h1>
      </div>

      <div class="card">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Status</th>
              <th>Started</th>
            </tr>
          </thead>
          <tbody>
            <%= for run <- @runs do %>
              <tr
                phx-click="toggle_steps"
                phx-value-id={run.id}
                style="cursor: pointer;"
                id={"run-#{run.id}"}
              >
                <td>{run.name}</td>
                <td style="color: var(--muted);">{run.workflow_type || "—"}</td>
                <td><.status_badge status={run.status} /></td>
                <td style="color: var(--muted); font-size: 0.875rem;">
                  {format_time(run.started_at)}
                </td>
              </tr>
              <tr :if={@expanded_run_id == run.id} id={"steps-#{run.id}"}>
                <td colspan="4" style="padding: 0.5rem 1rem 1rem 2rem; background: var(--surface);">
                  <p :if={@steps_error} style="color: var(--muted);">{@steps_error}</p>
                  <p
                    :if={is_nil(@steps_error) and @steps == []}
                    style="color: var(--muted); font-size: 0.875rem;"
                  >
                    No steps recorded for this run
                  </p>
                  <table :if={@steps != []} style="font-size: 0.875rem;">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Step</th>
                        <th>Type</th>
                        <th>Status</th>
                        <th>Started</th>
                        <th>Completed</th>
                        <th>Error</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={step <- @steps}>
                        <td style="color: var(--muted);">{step.sequence}</td>
                        <td>{step.name}</td>
                        <td style="color: var(--muted);">{step.step_type || "—"}</td>
                        <td><.status_badge status={step.status} /></td>
                        <td style="color: var(--muted);">{format_time(step.started_at)}</td>
                        <td style="color: var(--muted);">{format_time(step.completed_at)}</td>
                        <td style="color: var(--muted);">{step.error || "—"}</td>
                      </tr>
                    </tbody>
                  </table>
                </td>
              </tr>
            <% end %>
            <tr :if={@runs == []}>
              <td colspan="4" style="text-align: center; color: var(--muted); padding: 2rem;">
                No workflow runs yet
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp list_runs(%{assigns: %{current_actor: %{tenant_id: tenant_id} = actor}}) do
    case WorkflowRun.list(tenant: tenant_id, actor: actor) do
      {:ok, items} ->
        {items, nil}

      {:error, e} ->
        Logger.warning("[WorkflowsLive] runs list failed: #{inspect(e)}")
        {[], "Could not load workflow runs"}
    end
  end

  defp list_runs(_socket), do: {[], "Could not load workflow runs"}

  # The per-run step detail: the WorkflowStep read model projected from the
  # run's step_* events, in sequence order.
  defp list_steps(%{assigns: %{current_actor: %{tenant_id: tenant_id} = actor}}, run_id) do
    case WorkflowStep.for_run(run_id, tenant: tenant_id, actor: actor) do
      {:ok, steps} ->
        {steps, nil}

      {:error, e} ->
        Logger.warning("[WorkflowsLive] steps list failed: #{inspect(e)}")
        {[], "Could not load steps for this run"}
    end
  end

  defp list_steps(_socket, _run_id), do: {[], "Could not load steps for this run"}
end
