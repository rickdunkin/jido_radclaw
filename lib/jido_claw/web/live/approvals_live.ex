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
  alias JidoClaw.Orchestration.WorkflowRun

  # Gate events can arrive in bursts; coalesce inbox reloads behind a single
  # delayed :refresh_gates, mirroring DashboardLive's overview debounce.
  @refresh_debounce_ms 250

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: RunPubSub.subscribe_gates()

    {:ok,
     assign(socket,
       page_title: "Approvals",
       gates: load_gates(socket),
       gates_refresh_pending: false
     )}
  end

  @impl Phoenix.LiveView
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
          <span style="font-weight: 600;">{gate_title(gate)}</span>
          <.status_badge status={gate.status} />
        </div>
        <div style="color: var(--muted); font-size: 0.875rem; margin-bottom: 0.25rem;">
          {gate.step_name} · {gate.kind}
        </div>
        <div
          :if={gate.tool_name}
          style="color: var(--muted); font-size: 0.8125rem; margin-bottom: 0.25rem;"
        >
          tool: <code>{gate.tool_name}</code>
        </div>
        <div
          :if={details_value(gate, "agent_template")}
          style="color: var(--muted); font-size: 0.8125rem; margin-bottom: 0.25rem;"
        >
          template: <code>{details_value(gate, "agent_template")}</code>
        </div>
        <div
          :if={details_value(gate, "arguments")}
          style="color: var(--muted); font-size: 0.8125rem; margin-bottom: 0.25rem;"
        >
          args: <code>{details_value(gate, "arguments")}</code>
        </div>
        <div
          :if={gate_description(gate)}
          style="color: var(--muted); font-size: 0.875rem; margin-bottom: 0.75rem;"
        >
          {gate_description(gate)}
        </div>

        <form phx-submit="decide" id={"gate-form-#{gate.id}"}>
          <input type="hidden" name="case_id" value={gate.id} />

          <%!-- Review-stall waive controls (camus C1-4 / orca OQ-1): one row
                per REQUIRED key (finding_keys — the complete list; the
                findings display is capped), each with a native `required`
                checkbox so the browser blocks Approve until every finding is
                addressed. Reject carries formnovalidate below, so it is
                never blocked. --%>
          <div :if={gate.kind == :review_stall} style="margin-bottom: 0.75rem;">
            <div style="font-size: 0.875rem; font-weight: 600; margin-bottom: 0.5rem;">
              Waive every surviving finding to approve
            </div>
            <div :for={row <- waive_rows(gate)} style="margin-bottom: 0.5rem;">
              <label style="display: block; font-size: 0.8125rem;">
                <input type="checkbox" name={"waive[#{row.key}]"} value="true" required />
                [{row.severity}] {row.title}
                <code :if={row.location != ""}>{row.location}</code>
              </label>
              <input type="hidden" name={"waive_severity[#{row.key}]"} value={row.severity} />
              <input
                type="text"
                name={"waive_note[#{row.key}]"}
                placeholder="waive note (optional)"
                style="width: 100%; margin-top: 0.25rem;"
              />
            </div>
            <div
              :if={details_value(gate, "resume_hint")}
              style="color: var(--muted); font-size: 0.8125rem; margin-top: 0.5rem;"
            >
              {details_value(gate, "resume_hint")}
            </div>
          </div>

          <div :for={field <- gate_fields(gate)} style="margin-bottom: 0.75rem;">
            <label style="display: block; font-size: 0.875rem; margin-bottom: 0.25rem;">
              {field["label"]}
              <span :if={field["required"]} style="color: var(--muted);">(required)</span>
            </label>
            <.gate_field_input field={field} />
          </div>

          <div style="display: flex; gap: 0.5rem;">
            <button type="submit" name="decision" value="approve" class="btn btn-primary">
              Approve
            </button>
            <button type="submit" name="decision" value="reject" class="btn" formnovalidate>
              Reject
            </button>
            <button
              :if={gate.workflow_run_id}
              type="button"
              class="btn"
              style="margin-left: auto; color: var(--muted);"
              phx-click="abandon"
              phx-value-id={gate.id}
            >
              Abandon run
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # One typed input per declared gate DSL field (`details["fields"]`, seeded
  # by GateStep from Gate.Info). Values land in the decision comment.
  defp gate_field_input(%{field: %{"type" => "textarea"}} = assigns) do
    ~H"""
    <textarea name={"fields[#{@field["name"]}]"} rows="2" style="width: 100%;"></textarea>
    """
  end

  defp gate_field_input(%{field: %{"type" => "select"}} = assigns) do
    ~H"""
    <select name={"fields[#{@field["name"]}]"}>
      <option :for={option <- @field["options"] || []} value={option}>{option}</option>
    </select>
    """
  end

  defp gate_field_input(%{field: %{"type" => "number"}} = assigns) do
    ~H"""
    <input type="number" name={"fields[#{@field["name"]}]"} />
    """
  end

  defp gate_field_input(%{field: %{"type" => "boolean"}} = assigns) do
    ~H"""
    <input type="checkbox" name={"fields[#{@field["name"]}]"} value="true" />
    """
  end

  defp gate_field_input(assigns) do
    ~H"""
    <input type="text" name={"fields[#{@field["name"]}]"} style="width: 100%;" />
    """
  end

  @impl Phoenix.LiveView
  def handle_event("decide", %{"case_id" => id} = params, socket) do
    decision = if params["decision"] == "reject", do: :reject, else: :approve

    decide(
      socket,
      decision,
      id,
      comment_from_fields(params["fields"]),
      waive_records_from_params(params)
    )
  end

  def handle_event("approve", %{"id" => id}, socket), do: decide(socket, :approve, id)
  def handle_event("reject", %{"id" => id}, socket), do: decide(socket, :reject, id)

  # Operator abandon (AR-1): deliberately give up on the parked run. Only
  # legal from :awaiting_approval — a live run refuses (illegal transition).
  def handle_event("abandon", %{"id" => id}, socket) do
    actor = socket.assigns[:current_actor]
    attrs = %{decided_by_id: actor && actor.user_id}

    case Cases.abandon(id, attrs, tenant: tenant_id(socket), actor: actor) do
      {:ok, %WorkflowRun{} = run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Run #{run.name} abandoned")
         |> assign(gates: load_gates(socket))}

      # Review-stall abandon returns the case — the run stays :running until
      # the parked composer wakes and terminalizes it :abandoned itself.
      {:ok, %AgentCase{}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Review-stall gate abandoned — the composer will end the run")
         |> assign(gates: load_gates(socket))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not abandon run: #{inspect(reason)}")}
    end
  end

  # Gate lifecycle events (RunPubSub gates channel) — each arms a coalesced
  # inbox reload.
  @impl Phoenix.LiveView
  def handle_info({:gate_requested, _run_id, _info}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info({:gate_resolved, _run_id, _info}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(:refresh_gates, socket) do
    {:noreply, assign(socket, gates: load_gates(socket), gates_refresh_pending: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp decide(socket, decision, id, comment \\ nil, waive_records \\ []) do
    actor = socket.assigns[:current_actor]
    attrs = decide_attrs(actor, comment, waive_records)

    case Cases.decide(id, decision, attrs, tenant: tenant_id(socket), actor: actor) do
      {:ok, %WorkflowRun{} = run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Gate #{decision}d — run #{run.name} is now #{run.status}")
         |> assign(gates: load_gates(socket))}

      {:ok, %AgentCase{kind: :review_stall}} ->
        {:noreply,
         socket
         |> put_flash(:info, review_stall_flash(decision))
         |> assign(gates: load_gates(socket))}

      {:ok, %AgentCase{}} ->
        {:noreply,
         socket
         |> put_flash(:info, tool_call_flash(decision))
         |> assign(gates: load_gates(socket))}

      {:error, :incomplete_waiver} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Approve requires every surviving finding waived — check each finding " <>
             "(add a note if useful) and submit again, or reject."
         )}

      {:error, :parent_terminal} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The parent route has already ended — this gate can no longer be approved " <>
             "(reject or abandon to close it)."
         )}

      {:error, :parent_state_unknown} ->
        {:noreply,
         put_flash(socket, :error, "Could not verify the parent route's state — try again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not #{decision} gate: #{inspect(reason)}")}
    end
  end

  # Optional decide attrs ride only when provided: a nil comment / empty waive
  # list never lands a key.
  defp decide_attrs(actor, comment, waive_records) do
    %{decided_by_id: actor && actor.user_id}
    |> put_decide_attr(:decision_comment, comment)
    |> put_decide_attr(:waive_records, waive_records)
  end

  defp put_decide_attr(attrs, _key, nil), do: attrs
  defp put_decide_attr(attrs, _key, []), do: attrs
  defp put_decide_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp tool_call_flash(:approve), do: "Tool call approved — the agent may retry it now"
  defp tool_call_flash(:reject), do: "Tool call rejected — the agent will not retry it"

  # Review-stall decisions are recorded on the case; the RUN terminal lands
  # asynchronously when the parked composer wakes (never read off decide).
  defp review_stall_flash(:approve),
    do: "Waivers recorded — the run completes as done_with_findings when the composer resumes"

  defp review_stall_flash(:reject),
    do: "Findings rejected — the run fails as fix_failed when the composer resumes"

  # -- Gate DSL presentation (seeded into details by GateStep) --

  defp gate_title(gate), do: details_value(gate, "gate_title") || gate.step_name

  defp gate_description(gate), do: details_value(gate, "gate_description")

  defp gate_fields(gate) do
    case details_value(gate, "fields") do
      fields when is_list(fields) -> Enum.filter(fields, &is_map/1)
      _ -> []
    end
  end

  defp details_value(%{details: details}, key) when is_map(details), do: Map.get(details, key)
  defp details_value(_gate, _key), do: nil

  # One waive row per REQUIRED key: `finding_keys` is the complete
  # waive-required list; `findings` is the (capped) display list, joined for
  # severity/title/location where present — a beyond-cap key still gets a row
  # (key-only), so Approve can always be completed from this surface.
  defp waive_rows(gate) do
    findings = List.wrap(details_value(gate, "findings"))
    keys = List.wrap(details_value(gate, "finding_keys"))

    for key <- keys, is_binary(key) do
      shown = Enum.find(findings, &(is_map(&1) and &1["key"] == key))

      %{
        key: key,
        severity: (is_map(shown) && shown["severity"]) || "unknown",
        title:
          (is_map(shown) && shown["title"]) ||
            "(beyond display cap — key #{String.slice(key, 0, 12)}…)",
        location: (is_map(shown) && shown["location"]) || ""
      }
    end
  end

  # `waive[<key>] = "true"` checkboxes + `waive_severity[<key>]` hidden fields
  # + optional `waive_note[<key>]` collapse into the `Cases.decide/4`
  # `:waive_records` attrs shape.
  defp waive_records_from_params(%{"waive" => waived} = params) when is_map(waived) do
    severities = Map.get(params, "waive_severity", %{})
    notes = Map.get(params, "waive_note", %{})

    for {key, "true"} <- waived do
      %{
        "key" => key,
        "severity" => Map.get(severities, key),
        "note" => blank_to_nil(Map.get(notes, key))
      }
    end
  end

  defp waive_records_from_params(_params), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The typed field values, folded into the decision comment audit line
  # ("name: value", non-empty values only).
  defp comment_from_fields(fields) when is_map(fields) do
    fields
    |> Enum.filter(fn {_name, value} -> is_binary(value) and String.trim(value) != "" end)
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{String.trim(value)}" end)
    |> case do
      "" -> nil
      comment -> comment
    end
  end

  defp comment_from_fields(_fields), do: nil

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
