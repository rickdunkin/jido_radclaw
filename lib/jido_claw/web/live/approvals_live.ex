defmodule JidoClaw.Web.ApprovalsLive do
  @moduledoc """
  Operator inbox for human approval gates.

  Lists the current tenant's pending `AgentCase`s and routes approve/reject
  clicks through `JidoClaw.Orchestration.Cases.decide/4` — the same decision
  point as the CLI `/gates` command. Subscribes to the gate PubSub channel so
  the inbox refreshes (debounced) when a gate is requested or resolved
  anywhere in the tenant.
  """

  use JidoClaw.Web, :live_view

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.RunPubSub

  # Gate events can arrive in bursts; coalesce inbox reloads behind a single
  # delayed :refresh_gates, mirroring DashboardLive's overview debounce.
  @refresh_debounce_ms 250

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: RunPubSub.subscribe_gates()

    {:ok,
     assign(socket,
       page_title: "Approvals",
       gates: load_gates(socket),
       gates_refresh_pending: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 style="font-size: 1.5rem; font-weight: 700; margin-bottom: 1.5rem;">Approvals</h1>

      <div
        :if={@gates == []}
        class="card"
        style="color: var(--muted); font-size: 0.875rem;"
      >
        No pending approval gates
      </div>

      <div
        :for={gate <- @gates}
        class="card"
        style="margin-bottom: 1rem;"
      >
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem;">
          <span style="font-weight: 600;">{gate.step_name}</span>
          <.status_badge status={gate.status} />
        </div>
        <div style="color: var(--muted); font-size: 0.875rem; margin-bottom: 0.75rem;">
          {gate.kind}
        </div>
        <div style="display: flex; gap: 0.5rem;">
          <button class="btn btn-primary" phx-click="approve" phx-value-id={gate.id}>
            Approve
          </button>
          <button class="btn" phx-click="reject" phx-value-id={gate.id}>
            Reject
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket), do: decide(socket, :approve, id)
  def handle_event("reject", %{"id" => id}, socket), do: decide(socket, :reject, id)

  # Gate lifecycle events (RunPubSub gates channel) — each arms a coalesced
  # inbox reload.
  @impl true
  def handle_info({:gate_requested, _run_id, _info}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:gate_resolved, _run_id, _info}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(:refresh_gates, socket) do
    {:noreply, assign(socket, gates: load_gates(socket), gates_refresh_pending: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp decide(socket, decision, id) do
    actor = socket.assigns[:current_actor]
    attrs = %{decided_by_id: actor && actor.user_id}

    case Cases.decide(id, decision, attrs, tenant: tenant_id(socket), actor: actor) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Gate #{decision}d — run #{run.name} is now #{run.status}")
         |> assign(gates: load_gates(socket))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not #{decision} gate: #{inspect(reason)}")}
    end
  end

  defp load_gates(socket) do
    case socket.assigns[:current_actor] do
      %{tenant_id: tenant_id} = actor ->
        case AgentCase.pending_for_tenant(tenant: tenant_id, actor: actor) do
          {:ok, gates} -> gates
          {:error, _reason} -> []
        end

      _ ->
        []
    end
  end

  defp tenant_id(socket) do
    case socket.assigns[:current_actor] do
      %{tenant_id: tenant_id} -> tenant_id
      _ -> nil
    end
  end

  # Debounce: the first event in a burst arms a single timer + sets the pending
  # flag; subsequent events are no-ops until :refresh_gates clears it.
  defp schedule_refresh(%{assigns: %{gates_refresh_pending: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh_gates, @refresh_debounce_ms)
    assign(socket, gates_refresh_pending: true)
  end
end
