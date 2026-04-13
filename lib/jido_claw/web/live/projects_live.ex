defmodule JidoClaw.Web.ProjectsLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    projects =
      Ash.read!(JidoClaw.Projects.Project, actor: socket.assigns.current_user, authorize?: false)

    {:ok, assign(socket, page_title: "Projects", projects: projects)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Projects</h1>

      <div class="card">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>GitHub</th>
              <th>Branch</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={project <- @projects}>
              <td style="font-weight: 500;"><%= project.name %></td>
              <td style="color: var(--muted);"><%= project.github_full_name || "—" %></td>
              <td style="color: var(--muted);"><%= project.default_branch || "main" %></td>
              <td style="color: var(--muted); font-size: 0.875rem;"><%= Calendar.strftime(project.inserted_at, "%Y-%m-%d") %></td>
            </tr>
            <tr :if={@projects == []}>
              <td colspan="4" style="text-align: center; color: var(--muted); padding: 2rem;">No projects yet</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
