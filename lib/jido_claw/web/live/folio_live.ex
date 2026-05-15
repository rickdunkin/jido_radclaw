defmodule JidoClaw.Web.FolioLive do
  use JidoClaw.Web, :live_view

  require Logger

  alias JidoClaw.Folio.Action, as: FolioAction
  alias JidoClaw.Folio.InboxItem
  alias JidoClaw.Folio.Project, as: FolioProject

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {inbox, inbox_error} =
      case InboxItem.list_unprocessed(actor: actor, authorize?: false) do
        {:ok, items} ->
          {items, nil}

        {:error, e} ->
          Logger.warning("[FolioLive] inbox list failed: #{inspect(e)}")
          {[], "Could not load inbox"}
      end

    {actions, actions_error} =
      case FolioAction.list_next_actions(actor: actor, authorize?: false) do
        {:ok, items} ->
          {items, nil}

        {:error, e} ->
          Logger.warning("[FolioLive] actions list failed: #{inspect(e)}")
          {[], "Could not load actions"}
      end

    {projects, projects_error} =
      case FolioProject.list_active(actor: actor, authorize?: false) do
        {:ok, items} ->
          {items, nil}

        {:error, e} ->
          Logger.warning("[FolioLive] projects list failed: #{inspect(e)}")
          {[], "Could not load projects"}
      end

    {:ok,
     assign(socket,
       page_title: "Folio",
       tab: :inbox,
       inbox: inbox,
       actions: actions,
       projects: projects,
       inbox_error: inbox_error,
       actions_error: actions_error,
       projects_error: projects_error
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Folio GTD</h1>

      <div style="display: flex; gap: 0.25rem; margin-bottom: 1.5rem;">
        <button
          class={"btn #{if @tab == :inbox, do: "btn-primary"}"}
          phx-click="tab"
          phx-value-tab="inbox"
        >
          Inbox ({length(@inbox)})
        </button>
        <button
          class={"btn #{if @tab == :actions, do: "btn-primary"}"}
          phx-click="tab"
          phx-value-tab="actions"
        >
          Next Actions ({length(@actions)})
        </button>
        <button
          class={"btn #{if @tab == :projects, do: "btn-primary"}"}
          phx-click="tab"
          phx-value-tab="projects"
        >
          Projects ({length(@projects)})
        </button>
      </div>

      <div :if={@tab == :inbox} class="card">
        <div
          :for={item <- @inbox}
          style="padding: 0.75rem 0; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center;"
        >
          <div>
            <div style="font-weight: 500;">{item.title}</div>
            <div :if={item.notes} style="color: var(--muted); font-size: 0.875rem;">
              {String.slice(item.notes, 0, 100)}
            </div>
          </div>
          <.status_badge status={item.status} />
        </div>
        <div :if={@inbox == []} style="text-align: center; color: var(--muted); padding: 2rem;">
          Inbox zero! 🎉
        </div>
      </div>

      <div :if={@tab == :actions} class="card">
        <div
          :for={action <- @actions}
          style="padding: 0.75rem 0; border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center;"
        >
          <div>
            <div style="font-weight: 500;">{action.title}</div>
            <div style="color: var(--muted); font-size: 0.875rem;">
              {if action.context, do: "@#{action.context}", else: ""}
              {if action.due_date, do: " · Due #{action.due_date}", else: ""}
            </div>
          </div>
          <.status_badge status={action.status} />
        </div>
        <div :if={@actions == []} style="text-align: center; color: var(--muted); padding: 2rem;">
          No next actions
        </div>
      </div>

      <div :if={@tab == :projects} class="card">
        <div
          :for={project <- @projects}
          style="padding: 0.75rem 0; border-bottom: 1px solid var(--border);"
        >
          <div style="font-weight: 500;">{project.name}</div>
          <div :if={project.outcome} style="color: var(--muted); font-size: 0.875rem;">
            {project.outcome}
          </div>
        </div>
        <div :if={@projects == []} style="text-align: center; color: var(--muted); padding: 2rem;">
          No active projects
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  rescue
    ArgumentError -> {:noreply, socket}
  end
end
