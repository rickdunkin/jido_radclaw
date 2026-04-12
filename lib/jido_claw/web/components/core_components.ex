defmodule JidoClaw.Web.CoreComponents do
  use Phoenix.Component

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="flash flash-info">
      <%= msg %>
    </div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash flash-error">
      <%= msg %>
    </div>
    """
  end

  attr(:navigate, :string, default: nil)
  attr(:class, :string, default: "")
  attr(:variant, :string, default: "default")
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <.link :if={@navigate} navigate={@navigate} class={"btn #{if @variant == "primary", do: "btn-primary"} #{@class}"}>
      <%= render_slot(@inner_block) %>
    </.link>
    <button :if={!@navigate} class={"btn #{if @variant == "primary", do: "btn-primary"} #{@class}"}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  slot(:inner_block)

  def stat_card(assigns) do
    ~H"""
    <div class="card" style="text-align: center;">
      <div style="color: var(--muted); font-size: 0.75rem; text-transform: uppercase; margin-bottom: 0.5rem;">
        <%= @label %>
      </div>
      <div style="font-size: 2rem; font-weight: 700; color: var(--accent);">
        <%= @value || render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  attr(:status, :atom, required: true)

  def status_badge(assigns) do
    color =
      case assigns.status do
        s when s in [:completed, :ready, :active, :approved] -> "badge-green"
        s when s in [:running, :pending, :awaiting_approval] -> "badge-yellow"
        s when s in [:failed, :error, :rejected, :cancelled] -> "badge-red"
        _ -> "badge-blue"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge #{@color}"}><%= @status %></span>
    """
  end
end
