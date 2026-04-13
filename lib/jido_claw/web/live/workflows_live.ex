defmodule JidoClaw.Web.WorkflowsLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    runs =
      Ash.read!(JidoClaw.Orchestration.WorkflowRun,
        actor: socket.assigns.current_user,
        authorize?: false
      )

    {:ok, assign(socket, page_title: "Workflows", runs: runs)}
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
            <tr :for={run <- @runs}>
              <td><%= run.name %></td>
              <td style="color: var(--muted);"><%= run.workflow_type || "—" %></td>
              <td><.status_badge status={run.status} /></td>
              <td style="color: var(--muted); font-size: 0.875rem;"><%= format_time(run.started_at) %></td>
            </tr>
            <tr :if={@runs == []}>
              <td colspan="4" style="text-align: center; color: var(--muted); padding: 2rem;">No workflow runs yet</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
