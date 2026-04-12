defmodule JidoClaw.Web.SignInLive do
  use JidoClaw.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sign In",
       email: "",
       password: "",
       error: nil,
       trigger_action: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display: flex; justify-content: center; align-items: center; min-height: 80vh;">
      <div class="card" style="width: 400px;">
        <h1 style="font-size: 1.25rem; font-weight: 700; margin-bottom: 1.5rem; text-align: center;">Sign in to JidoClaw</h1>

        <div :if={@error} class="flash flash-error" style="margin-bottom: 1rem;">
          <%= @error %>
        </div>

        <form
          phx-submit="sign_in"
          phx-trigger-action={@trigger_action}
          action="/auth/sign-in"
          method="post"
          style="display: flex; flex-direction: column; gap: 1rem;"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <div>
            <label style="display: block; color: var(--muted); font-size: 0.875rem; margin-bottom: 0.25rem;">Email</label>
            <input type="email" name="email" value={@email} phx-change="validate" required />
          </div>
          <div>
            <label style="display: block; color: var(--muted); font-size: 0.875rem; margin-bottom: 0.25rem;">Password</label>
            <input type="password" name="password" required />
          </div>
          <button type="submit" class="btn btn-primary" style="width: 100%; justify-content: center;">Sign In</button>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"email" => email}, socket) do
    {:noreply, assign(socket, email: email)}
  end

  @impl true
  def handle_event("sign_in", %{"email" => email, "password" => _password}, socket) do
    if String.trim(email) == "" do
      {:noreply, assign(socket, error: "Email is required")}
    else
      {:noreply, assign(socket, trigger_action: true)}
    end
  end
end
