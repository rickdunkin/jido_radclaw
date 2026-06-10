defmodule JidoClaw.Web.WorkflowsLive do
  use JidoClaw.Web, :live_view

  require Logger

  alias JidoClaw.Orchestration.Replay
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep

  # Mirrors Replay's terminal set: only a finished run gets a Replay button.
  @terminal [:completed, :failed, :cancelled, :abandoned]

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
       steps_error: nil,
       replay_blocked: %{}
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

  # Replay button (Phase 4). The two gate refusals are surfaced as a flash
  # plus a per-run override button (`phx-value-force` /
  # `phx-value-allow_irreversible`) — the operator affordance the MCP tool
  # deliberately lacks. Each refusal's blocked map carries the flags the
  # failing click already had forward onto the armed button, so a run that
  # trips BOTH gates resolves in one extra click instead of ping-ponging
  # between mutually-resetting overrides.
  def handle_event("replay", %{"id" => run_id} = params, socket) do
    case Replay.replay(run_id, replay_opts(socket, params)) do
      {:ok, run} ->
        {runs, runs_error} = list_runs(socket)

        {:noreply,
         socket
         |> assign(runs: runs, runs_error: runs_error)
         |> update(:replay_blocked, &Map.delete(&1, run_id))
         |> put_flash(:info, "Replay launched: #{run.name} is #{run.status}")}

      {:error, {:definition_changed, _stored, _current}} ->
        blocked = %{
          reason: :definition_changed,
          force: true,
          allow_irreversible: params["allow_irreversible"] == "true"
        }

        {:noreply,
         socket
         |> update(:replay_blocked, &Map.put(&1, run_id, blocked))
         |> put_flash(:error, definition_changed_flash(blocked))}

      {:error, :irreversible_steps_executed} ->
        blocked = %{
          reason: :irreversible,
          allow_irreversible: true,
          force: params["force"] == "true"
        }

        {:noreply,
         socket
         |> update(:replay_blocked, &Map.put(&1, run_id, blocked))
         |> put_flash(:error, irreversible_flash(blocked))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Replay refused: #{inspect(reason)}")}
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
              <th style="text-align: right;">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for run <- @runs do %>
              <%!-- The steps toggle rides on the data cells (not the row), so
                    the Actions cell's buttons never double-fire a toggle. --%>
              <tr id={"run-#{run.id}"}>
                <td phx-click="toggle_steps" phx-value-id={run.id} style="cursor: pointer;">
                  {run.name}
                </td>
                <td
                  phx-click="toggle_steps"
                  phx-value-id={run.id}
                  style="cursor: pointer; color: var(--muted);"
                >
                  {run.workflow_type || "—"}
                </td>
                <td phx-click="toggle_steps" phx-value-id={run.id} style="cursor: pointer;">
                  <.status_badge status={run.status} />
                </td>
                <td
                  phx-click="toggle_steps"
                  phx-value-id={run.id}
                  style="cursor: pointer; color: var(--muted); font-size: 0.875rem;"
                >
                  {format_time(run.started_at)}
                </td>
                <td style="text-align: right; white-space: nowrap;">
                  <%= if replayable?(run.status) do %>
                    <%!-- Each override button re-emits the flags its refusal's
                          click carried (HEEx omits false/nil attr values), so
                          granted overrides survive into the next click. --%>
                    <% blocked = @replay_blocked[run.id] %>
                    <button
                      class="btn"
                      style="font-size: 0.8125rem;"
                      phx-click="replay"
                      phx-value-id={run.id}
                      id={"replay-#{run.id}"}
                    >
                      Replay
                    </button>
                    <button
                      :if={blocked && blocked.reason == :definition_changed}
                      class="btn btn-primary"
                      style="font-size: 0.8125rem;"
                      phx-click="replay"
                      phx-value-id={run.id}
                      phx-value-force="true"
                      phx-value-allow_irreversible={blocked.allow_irreversible && "true"}
                      id={"replay-force-#{run.id}"}
                    >
                      Force replay
                    </button>
                    <button
                      :if={blocked && blocked.reason == :irreversible}
                      class="btn btn-primary"
                      style="font-size: 0.8125rem;"
                      phx-click="replay"
                      phx-value-id={run.id}
                      phx-value-allow_irreversible="true"
                      phx-value-force={blocked.force && "true"}
                      id={"replay-irreversible-#{run.id}"}
                    >
                      Replay anyway
                    </button>
                  <% end %>
                </td>
              </tr>
              <tr :if={@expanded_run_id == run.id} id={"steps-#{run.id}"}>
                <td colspan="5" style="padding: 0.5rem 1rem 1rem 2rem; background: var(--surface);">
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
              <td colspan="5" style="text-align: center; color: var(--muted); padding: 2rem;">
                No workflow runs yet
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # When the refused click already carried the OTHER gate's grant, say the
  # armed button keeps it — the operator should know one click resolves both.
  defp definition_changed_flash(%{allow_irreversible: carried?}) do
    base =
      "The definition changed since this run — \"Force replay\" runs the current definition"

    if carried?, do: base <> " (keeping the irreversible override)", else: base
  end

  defp irreversible_flash(%{force: carried?}) do
    base = "This run executed irreversible steps — \"Replay anyway\" will repeat them"
    if carried?, do: base <> " (keeping the definition override)", else: base
  end

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp replayable?(status), do: status in @terminal

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

  # Without a current_actor the empty opts make Replay refuse cleanly with
  # :missing_required_opt (mirrors list_runs' degraded fallback).
  defp replay_opts(%{assigns: %{current_actor: %{tenant_id: tenant_id} = actor}}, params) do
    [
      tenant: tenant_id,
      actor: actor,
      force: params["force"] == "true",
      allow_irreversible: params["allow_irreversible"] == "true"
    ]
  end

  defp replay_opts(_socket, _params), do: []
end
