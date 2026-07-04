defmodule JidoClaw.Web.ProjectsLiveTest do
  @moduledoc """
  Pure-render coverage of the projects page's load-error surfacing (1.11): a
  failed `Project.read` writes `@projects_error`, which the template must render
  instead of the misleading "No projects yet" empty state.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Web.ProjectsLive
  alias Phoenix.HTML.Safe

  test "renders the projects_error row (not the empty state) when the load failed" do
    html = render_projects([], projects_error: "Could not load projects")

    assert html =~ "Could not load projects"
    refute html =~ "No projects yet"
  end

  test "renders the empty state when there is no error and no projects" do
    html = render_projects([], projects_error: nil)

    assert html =~ "No projects yet"
  end

  defp render_projects(projects, overrides) do
    %{
      __changed__: %{},
      projects: projects,
      projects_error: nil,
      flash: %{}
    }
    |> Map.merge(Map.new(overrides))
    |> ProjectsLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
