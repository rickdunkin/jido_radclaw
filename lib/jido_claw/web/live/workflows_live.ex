defmodule JidoClaw.Web.WorkflowsLive do
  use JidoClaw.Web, :live_view

  require Logger

  alias JidoClaw.Orchestration.Cancellation
  alias JidoClaw.Orchestration.Replay
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep
  alias JidoClaw.Web.Components.GraphLayout
  alias JidoClaw.Web.Components.StepGraph

  # Mirrors Replay's terminal set: only a finished run gets a Replay button.
  @terminal [:completed, :failed, :cancelled, :abandoned]

  # Lateness crosses deadline thresholds without any event, so a timer
  # re-renders the page periodically (re-fetching runs + expanded steps).
  @deadline_refresh_ms 30_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh_deadlines, @deadline_refresh_ms)
    end

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
       replay_blocked: %{},
       reveal_runs: MapSet.new(),
       steps_view: :graph,
       step_graph: nil
     )}
  end

  # Periodic deadline refresh: re-arm, then re-fetch the runs (and the
  # expanded run's steps) while PRESERVING the view state assigns
  # (`expanded_run_id`, `replay_blocked`) — refresh/1 only replaces data.
  @impl Phoenix.LiveView
  def handle_info(:refresh_deadlines, socket) do
    Process.send_after(self(), :refresh_deadlines, @deadline_refresh_ms)
    {:noreply, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_steps", %{"id" => run_id}, socket) do
    if socket.assigns.expanded_run_id == run_id do
      {:noreply,
       assign(socket,
         expanded_run_id: nil,
         steps: [],
         steps_error: nil,
         step_graph: nil,
         steps_view: :graph
       )}
    else
      {steps, steps_error} = list_steps(socket, run_id)

      {:noreply,
       assign(socket,
         expanded_run_id: run_id,
         steps: steps,
         steps_error: steps_error,
         step_graph: build_graph(steps)
       )}
    end
  end

  # Explicit literal matching — never String.to_atom on params.
  def handle_event("set_steps_view", %{"view" => "graph"}, socket),
    do: {:noreply, assign(socket, steps_view: :graph)}

  def handle_event("set_steps_view", %{"view" => "table"}, socket),
    do: {:noreply, assign(socket, steps_view: :table)}

  def handle_event("set_steps_view", _params, socket), do: {:noreply, socket}

  # Per-run payload reveal (T2-2): membership in `reveal_runs` flips that run
  # (and its expanded steps) to `:auditor` scope at render — the dashboard's
  # replacement surface for the `public?` payload flip. Toggling re-renders
  # without a re-fetch; the 30s refresh preserves the set.
  def handle_event("reveal", %{"id" => run_id}, socket) do
    {:noreply,
     update(socket, :reveal_runs, fn reveal_runs ->
       if MapSet.member?(reveal_runs, run_id) do
         MapSet.delete(reveal_runs, run_id)
       else
         MapSet.put(reveal_runs, run_id)
       end
     end)}
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

  # Cancel button (live-run cancellation). Flash reports the run's ACTUAL
  # resulting status — Cancellation delegates a parked run to abandon, so the
  # result is :abandoned there and :cancelled on the live path.
  def handle_event("cancel", %{"id" => run_id}, socket) do
    case Cancellation.cancel(run_id, cancel_opts(socket)) do
      {:ok, run} ->
        {runs, runs_error} = list_runs(socket)

        {:noreply,
         socket
         |> assign(runs: runs, runs_error: runs_error)
         |> put_flash(:info, "#{run.name} is now #{run.status}")}

      {:error, :already_terminal} ->
        {runs, runs_error} = list_runs(socket)

        {:noreply,
         socket
         |> assign(runs: runs, runs_error: runs_error)
         |> put_flash(:error, "This run already finished — nothing to cancel")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cancel refused: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # One clock read per render pass: consistent deadline evidence across all
    # rows (the 30s timer re-renders as lateness crosses thresholds).
    assigns = assign(assigns, :now, DateTime.utc_now())

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
              <th>Deadline</th>
              <th style="text-align: right;">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for run <- @runs do %>
              <%!-- Payload cells render ONLY Visibility-projected values; the
                    reveal toggle flips this run (and its expanded steps) to
                    :auditor scope without a re-fetch. --%>
              <% scope = scope_for(run.id, @reveal_runs) %>
              <% run_view = Visibility.run_view(run, scope, @now) %>
              <%!-- The steps toggle rides on the data cells (not the row), so
                    the Actions cell's buttons never double-fire a toggle. --%>
              <tr id={"run-#{run.id}"}>
                <.toggle_cell run_id={run.id}>{run.name}</.toggle_cell>
                <.toggle_cell run_id={run.id} style="cursor: pointer; color: var(--muted);">
                  {run.workflow_type || "—"}
                </.toggle_cell>
                <.toggle_cell run_id={run.id}><.status_badge status={run.status} /></.toggle_cell>
                <.toggle_cell
                  run_id={run.id}
                  style="cursor: pointer; color: var(--muted); font-size: 0.875rem;"
                >
                  {format_time(run.started_at)}
                </.toggle_cell>
                <.toggle_cell run_id={run.id}>
                  <.deadline_badge evidence={run_view.deadline} />
                </.toggle_cell>
                <td style="text-align: right; white-space: nowrap;">
                  <button
                    class="btn"
                    style="font-size: 0.8125rem;"
                    phx-click="reveal"
                    phx-value-id={run.id}
                    id={"reveal-#{run.id}"}
                  >
                    {if scope == :auditor, do: "Hide payloads", else: "Reveal payloads"}
                  </button>
                  <button
                    :if={cancellable?(run.status)}
                    class="btn"
                    style="font-size: 0.8125rem;"
                    phx-click="cancel"
                    phx-value-id={run.id}
                    data-confirm="Cancel this run? Already-started step work may not stop immediately."
                    id={"cancel-#{run.id}"}
                  >
                    Cancel
                  </button>
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
                <td colspan="6" style="padding: 0.5rem 1rem 1rem 2rem; background: var(--surface);">
                  <% step_views = Enum.map(@steps, &Visibility.step_view(&1, scope, @now)) %>
                  <p :if={@steps_error} style="color: var(--muted);">{@steps_error}</p>
                  <p
                    :if={is_nil(@steps_error) and @steps == []}
                    style="color: var(--muted); font-size: 0.875rem;"
                  >
                    No steps recorded for this run
                  </p>
                  <div :if={result = run_view[:result]} style="margin-bottom: 0.75rem;">
                    <div style="color: var(--muted); font-size: 0.75rem; text-transform: uppercase; margin-bottom: 0.25rem;">
                      Result (revealed)
                    </div>
                    <pre style="font-size: 0.8125rem; white-space: pre-wrap; margin: 0;">{inspect(result, pretty: true, limit: :infinity)}</pre>
                  </div>
                  <div :if={@steps != []} style="display: flex; gap: 0.5rem; margin-bottom: 0.75rem;">
                    <button
                      class={"btn #{if @steps_view == :graph, do: "btn-primary"}"}
                      style="font-size: 0.8125rem;"
                      phx-click="set_steps_view"
                      phx-value-view="graph"
                      id={"steps-view-graph-#{run.id}"}
                    >
                      Graph
                    </button>
                    <button
                      class={"btn #{if @steps_view == :table, do: "btn-primary"}"}
                      style="font-size: 0.8125rem;"
                      phx-click="set_steps_view"
                      phx-value-view="table"
                      id={"steps-view-table-#{run.id}"}
                    >
                      Table
                    </button>
                  </div>
                  <.workflow_graph
                    :if={@steps_view == :graph and not is_nil(@step_graph)}
                    layout={@step_graph}
                  />
                  <table
                    :if={@steps_view == :table and step_views != []}
                    style="font-size: 0.875rem;"
                  >
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Step</th>
                        <th>Type</th>
                        <th>Status</th>
                        <th>Started</th>
                        <th>Completed</th>
                        <th>Deadline</th>
                        <th>Error</th>
                        <th :if={scope == :auditor}>Output</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={step_view <- step_views}>
                        <td style="color: var(--muted);">{step_view.sequence}</td>
                        <td>{step_view.name}</td>
                        <td style="color: var(--muted);">{step_view.step_type || "—"}</td>
                        <td><.status_badge status={step_view.status} /></td>
                        <td style="color: var(--muted);">{format_time(step_view.started_at)}</td>
                        <td style="color: var(--muted);">{format_time(step_view.completed_at)}</td>
                        <td><.deadline_badge evidence={step_view.deadline} /></td>
                        <td style="color: var(--muted);">{step_view.error || "—"}</td>
                        <td
                          :if={scope == :auditor}
                          style="color: var(--muted); font-size: 0.8125rem;"
                        >
                          {format_output(step_view[:output])}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </td>
              </tr>
            <% end %>
            <tr :if={@runs == []}>
              <td colspan="6" style="text-align: center; color: var(--muted); padding: 2rem;">
                No workflow runs yet
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # One toggle binding for all five data cells: each is a distinct DOM node, but
  # routing the `phx-click` through a single component keeps the toggle on the
  # cells (not the row), so the Actions cell never double-fires a step toggle.
  attr(:run_id, :string, required: true)
  attr(:style, :string, default: "cursor: pointer;")
  slot(:inner_block, required: true)

  @spec toggle_cell(map()) :: Phoenix.LiveView.Rendered.t()
  defp toggle_cell(assigns) do
    ~H"""
    <td phx-click="toggle_steps" phx-value-id={@run_id} style={@style}>
      {render_slot(@inner_block)}
    </td>
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

  # The inverse of replayable?: only a run that can still make progress has
  # anything to cancel.
  defp cancellable?(status), do: status in [:pending, :running, :awaiting_approval]

  # :auditor iff the operator clicked "Reveal payloads" for this run.
  defp scope_for(run_id, reveal_runs) do
    if MapSet.member?(reveal_runs, run_id), do: :auditor, else: :operator
  end

  defp format_output(nil), do: "—"
  defp format_output(output), do: inspect(output, limit: :infinity)

  # Replace the data assigns only — expanded_run_id / replay_blocked /
  # reveal_runs / steps_view survive a refresh untouched.
  defp refresh(socket) do
    {runs, runs_error} = list_runs(socket)
    socket = assign(socket, runs: runs, runs_error: runs_error)

    case socket.assigns.expanded_run_id do
      nil ->
        socket

      run_id ->
        {steps, steps_error} = list_steps(socket, run_id)
        assign(socket, steps: steps, steps_error: steps_error, step_graph: build_graph(steps))
    end
  end

  defp build_graph([]), do: nil
  defp build_graph(steps), do: GraphLayout.build(StepGraph.build(steps))

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

  # Without a current_actor the empty opts make Cancellation refuse cleanly
  # with :missing_required_opt (mirrors replay_opts).
  defp cancel_opts(%{assigns: %{current_actor: %{tenant_id: tenant_id} = actor}}) do
    [tenant: tenant_id, actor: actor]
  end

  defp cancel_opts(_socket), do: []
end
