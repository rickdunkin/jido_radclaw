defmodule JidoClaw.Web.LiveUserAuth do
  @moduledoc """
  LiveView mount hooks with a three-way outcome split.

  An unauthenticated session redirects to `/sign-in`; an inactive tenant (or
  an authenticated user with an invalid actor shape) halts to the
  `/auth/account-unavailable` landing page, whose explicit CSRF-protected
  DELETE form is the only session-clearing path — an `on_mount` hook cannot
  clear a Plug session, so redirecting an inactive-tenant user to `/sign-in`
  used to loop forever; and an infrastructure failure (the auth lookup OR the
  tenant activity check) halts to the session-preserving `/service-unavailable`
  503 page — "cannot determine auth state" is a 503 everywhere, never a guess.

  Session resolution goes through `JidoClaw.Web.SessionUser` (result-
  preserving); `:session_user_resolver` / `:tenant_access_module` are
  test-only app-env seams for driving the infra branches without breaking
  the SQL sandbox.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Web.AdminAccess

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:live_user_optional, _params, session, socket) do
    case assign_current_user(socket, session) do
      {socket, {:error, reason}} -> halt_unavailable(socket, reason)
      {socket, _resolved} -> {:cont, socket}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    case assign_current_user(socket, session) do
      {socket, {:error, reason}} -> halt_unavailable(socket, reason)
      {socket, :unauthenticated} -> {:halt, redirect(socket, to: "/sign-in")}
      {socket, {:ok, _user}} -> mount_active_tenant(socket)
    end
  end

  def on_mount(:live_admin_required, _params, session, socket) do
    case assign_current_user(socket, session) do
      {socket, {:error, reason}} ->
        halt_unavailable(socket, reason)

      {socket, :unauthenticated} ->
        {:halt, redirect(socket, to: "/sign-in")}

      {socket, {:ok, user}} ->
        if AdminAccess.admin?(user) do
          {:cont, socket}
        else
          {:halt, redirect(socket, to: "/dashboard")}
        end
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    case assign_current_user(socket, session) do
      {socket, {:error, reason}} -> halt_unavailable(socket, reason)
      {socket, {:ok, _user}} -> {:halt, redirect(socket, to: "/dashboard")}
      {socket, :unauthenticated} -> {:cont, socket}
    end
  end

  # The activity gate is ALSO the first provisioner of a fresh user's tenant
  # row — `ensure_active` keeps its create-if-missing semantics (read-first
  # inside `Tenants.Access`, so a steady-state mount is a single SELECT).
  defp mount_active_tenant(socket) do
    case socket.assigns do
      %{current_actor: %{tenant_id: tenant_id}} ->
        check_tenant_active(socket, tenant_id)

      _invalid_actor ->
        # An authenticated user whose actor lacks the tenant shape can never
        # mount; force the sign-out landing instead of looping via /sign-in.
        {:halt, redirect(socket, to: "/auth/account-unavailable?reason=invalid_actor")}
    end
  end

  defp check_tenant_active(socket, tenant_id) do
    case tenant_access().ensure_active(tenant_id) do
      :ok ->
        {:cont, socket}

      {:error, {:tenant_inactive, status}} ->
        Logger.info("[LiveUserAuth] inactive tenant #{tenant_id} (#{status}); forcing sign-out")
        {:halt, redirect(socket, to: "/auth/account-unavailable?reason=account_unavailable")}

      {:error, reason} ->
        Logger.warning(
          "[LiveUserAuth] tenant activity check unavailable for #{tenant_id}: #{inspect(reason)}"
        )

        {:halt, redirect(socket, to: "/service-unavailable")}
    end
  end

  defp halt_unavailable(socket, reason) do
    Logger.warning("[LiveUserAuth] session resolution unavailable: #{inspect(reason)}")
    {:halt, redirect(socket, to: "/service-unavailable")}
  end

  # Result-preserving: the resolver outcome rides alongside the socket so
  # every hook can split `:unauthenticated` from `{:error, _}` (503) instead
  # of collapsing both to `current_user: nil`.
  defp assign_current_user(socket, session) do
    case session_user_resolver().resolve(session) do
      {:ok, user} ->
        {assign(socket, current_user: user, current_actor: Actor.build(user)), {:ok, user}}

      :unauthenticated ->
        {assign(socket, current_user: nil, current_actor: nil), :unauthenticated}

      {:error, reason} ->
        {assign(socket, current_user: nil, current_actor: nil), {:error, reason}}
    end
  end

  defp session_user_resolver do
    Application.get_env(:jido_claw, :session_user_resolver, JidoClaw.Web.SessionUser)
  end

  defp tenant_access do
    Application.get_env(:jido_claw, :tenant_access_module, Access)
  end
end
