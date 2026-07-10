defmodule JidoClaw.Web.AuthHTML do
  @moduledoc """
  Minimal controller-rendered pages for the auth outcome split: the
  forced-sign-out landing (`account_unavailable`) and the session-preserving
  503 page (`service_unavailable`). Both render inside the root layout only
  (`put_layout(false)`), so they carry no app chrome and no `@current_user`
  dependency.
  """
  use JidoClaw.Web, :html

  @doc """
  Forced-sign-out landing page. The DELETE form is CSRF-protected and fires
  on an explicit click only — deliberately no auto-submit and no inline JS
  (see `AuthController.account_unavailable/2`).
  """
  @spec account_unavailable(map()) :: Phoenix.LiveView.Rendered.t()
  def account_unavailable(assigns) do
    ~H"""
    <main class="container" style="padding-top: 4rem; max-width: 34rem;">
      <div class="card">
        <h1 style="margin-bottom: 1rem;">Account unavailable</h1>
        <p style="color: var(--muted); margin-bottom: 1.5rem;">
          Your account is currently unavailable, so you cannot use JidoClaw right
          now. Sign out below and contact an operator if you believe this is an
          error.
        </p>
        <.form for={%{}} action="/auth/sign-out" method="delete">
          <input :if={@reason} type="hidden" name="reason" value={@reason} />
          <button type="submit" class="btn btn-primary">Sign out</button>
        </.form>
      </div>
    </main>
    """
  end

  @doc "Session-preserving 503 page for auth-time infrastructure failures."
  @spec service_unavailable(map()) :: Phoenix.LiveView.Rendered.t()
  def service_unavailable(assigns) do
    ~H"""
    <main class="container" style="padding-top: 4rem; max-width: 34rem;">
      <div class="card">
        <h1 style="margin-bottom: 1rem;">Temporarily unavailable</h1>
        <p style="color: var(--muted);">
          JidoClaw cannot verify your session right now. You have not been signed
          out — retry shortly.
        </p>
      </div>
    </main>
    """
  end
end
