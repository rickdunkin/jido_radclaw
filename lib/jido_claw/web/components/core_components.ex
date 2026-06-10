defmodule JidoClaw.Web.CoreComponents do
  @moduledoc false
  use Phoenix.Component

  attr(:flash, :map, required: true)

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="flash flash-info">
      {msg}
    </div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash flash-error">
      {msg}
    </div>
    """
  end

  attr(:navigate, :string, default: nil)
  attr(:class, :string, default: "")
  attr(:variant, :string, default: "default")
  slot(:inner_block, required: true)

  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class={"btn #{if @variant == "primary", do: "btn-primary"} #{@class}"}
    >
      {render_slot(@inner_block)}
    </.link>
    <button :if={!@navigate} class={"btn #{if @variant == "primary", do: "btn-primary"} #{@class}"}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  slot(:inner_block)

  @spec stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def stat_card(assigns) do
    ~H"""
    <div class="card" style="text-align: center;">
      <div style="color: var(--muted); font-size: 0.75rem; text-transform: uppercase; margin-bottom: 0.5rem;">
        {@label}
      </div>
      <div style="font-size: 2rem; font-weight: 700; color: var(--accent);">
        {@value || render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:status, :atom, required: true)

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    color =
      case assigns.status do
        s when s in [:completed, :ready, :active, :approved] -> "badge-green"
        s when s in [:running, :pending, :awaiting_approval] -> "badge-yellow"
        s when s in [:failed, :error, :rejected, :cancelled, :abandoned] -> "badge-red"
        _ -> "badge-blue"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge #{@color}"}>{@status}</span>
    """
  end

  # Deadline lateness badge (T2-1): renders `JidoClaw.Orchestration.Deadline`
  # evidence — em-dash when no policy/evidence, otherwise the status with the
  # lateness amount once past due.
  attr(:evidence, :map, default: nil)

  @spec deadline_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def deadline_badge(assigns) do
    ~H"""
    <span :if={is_nil(@evidence)} style="color: var(--muted);">—</span>
    <span :if={@evidence} class={"badge #{deadline_color(@evidence.status)}"}>
      {deadline_label(@evidence)}
    </span>
    """
  end

  defp deadline_color(:due_soon), do: "badge-yellow"
  defp deadline_color(status) when status in [:overdue, :escalated], do: "badge-red"
  defp deadline_color(_status), do: "badge-green"

  defp deadline_label(%{status: :on_time}), do: "on time"
  defp deadline_label(%{status: :due_soon}), do: "due soon"
  defp deadline_label(%{status: :overdue, overdue_by_ms: ms}), do: "overdue #{lateness(ms)}"
  defp deadline_label(%{status: :escalated, overdue_by_ms: ms}), do: "escalated #{lateness(ms)}"

  defp lateness(ms) when ms >= 3_600_000, do: "+#{div(ms, 3_600_000)}h"
  defp lateness(ms) when ms >= 60_000, do: "+#{div(ms, 60_000)}m"
  defp lateness(ms), do: "+#{div(ms, 1000)}s"

  # Step-DAG render (T3-2): absolutely-positioned divs over a prebuilt
  # `JidoClaw.Web.Components.GraphLayout` — stage, dog-leg edge segments,
  # connection ports, and metadata-only node boxes. No SVG, no new CSS
  # classes; wide graphs scroll horizontally.
  attr(:layout, :map, required: true)

  @spec workflow_graph(map()) :: Phoenix.LiveView.Rendered.t()
  def workflow_graph(assigns) do
    ~H"""
    <div style="overflow-x: auto;">
      <div style={"position: relative; width: #{@layout.width}px; height: #{@layout.height}px;"}>
        <div
          :for={segment <- @layout.segments}
          style={"position: absolute; background: var(--border); left: #{segment.x}px; top: #{segment.y}px; width: #{segment.width}px; height: #{segment.height}px;"}
        >
        </div>
        <div
          :for={port <- @layout.ports}
          style={"position: absolute; width: 8px; height: 8px; border-radius: 50%; background: var(--muted); left: #{port.x - 4}px; top: #{port.y - 4}px;"}
        >
        </div>
        <div
          :for={positioned <- @layout.nodes}
          style={"position: absolute; left: #{positioned.x}px; top: #{positioned.y}px; width: #{positioned.width}px; height: #{positioned.height}px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); padding: 0.375rem 0.75rem; display: flex; flex-direction: column; justify-content: center; gap: 0.25rem; box-sizing: border-box;"}
        >
          <div style="font-size: 0.8125rem; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {positioned.node.label}
          </div>
          <div style="display: flex; align-items: center; gap: 0.5rem;">
            <.status_badge status={positioned.node.status} />
            <span style="color: var(--muted); font-size: 0.75rem;">
              {positioned.node.step_type || "—"}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
