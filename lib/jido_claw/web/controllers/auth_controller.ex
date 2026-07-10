defmodule JidoClaw.Web.AuthController do
  use JidoClaw.Web, :controller
  import AshAuthentication.Plug.Helpers

  alias JidoClaw.Accounts.PasswordPolicy
  alias JidoClaw.Audit.AsyncWriter
  alias JidoClaw.Audit.EventAttrs
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Tenants.Access
  alias JidoClaw.Web.AuthRateLimiter

  @max_email_bytes 320
  @bcrypt_max_password_bytes PasswordPolicy.bcrypt_max_bytes()

  # Client-supplied sign-out reasons are recorded only from this allowlist
  # (and only as untrusted `requested_reason`); everything else maps to nil.
  @sign_out_reasons ~w(account_unavailable invalid_actor)

  @spec sign_in(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_in(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    ip = remote_ip(conn)

    if valid_credential_shape?(email, password) do
      case AuthRateLimiter.check(ip, email) do
        :ok -> authenticate(conn, email, password, ip)
        {:error, {:rate_limited, retry_after}} -> rate_limited(conn, email, retry_after)
        {:error, :unavailable} -> limiter_unavailable(conn)
      end
    else
      invalid_credentials(conn, email)
    end
  end

  def sign_in(conn, _params), do: invalid_credentials(conn, nil)

  defp authenticate(conn, email, password, ip) do
    strategy = AshAuthentication.Info.strategy!(JidoClaw.Accounts.User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{
           "email" => email,
           "password" => password
         }) do
      {:ok, user} ->
        :ok = AuthRateLimiter.reset(ip, email)
        emit_auth_event(:sign_in_success, user.id, %{email: email})

        conn
        |> store_in_session(user)
        |> redirect(to: "/dashboard")

      {:error, _} ->
        invalid_credentials(conn, email)
    end
  end

  defp valid_credential_shape?(email, password) do
    String.valid?(email) and String.valid?(password) and
      byte_size(email) <= @max_email_bytes and
      byte_size(password) <= @bcrypt_max_password_bytes
  end

  defp invalid_credentials(conn, email) do
    payload =
      if is_binary(email) and byte_size(email) <= @max_email_bytes,
        do: %{email: email},
        else: %{reason: "malformed_request"}

    emit_auth_event(:sign_in_failure, nil, payload)

    conn
    |> put_flash(:error, "Invalid email or password")
    |> redirect(to: "/sign-in")
  end

  defp rate_limited(conn, email, retry_after) do
    emit_auth_event(:sign_in_failure, nil, %{email: email, reason: "rate_limited"})

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many sign-in attempts. Try again later.")
  end

  defp limiter_unavailable(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(503, "Sign-in is temporarily unavailable.")
  end

  defp remote_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  @doc """
  Forced-sign-out landing page for inactive tenants / invalid actor shapes.

  Renders a minimal page whose CSRF-protected DELETE form posts to the
  existing `/auth/sign-out` on an **explicit user click only** — never
  auto-submitted: an auto-submitting page would mint its own valid CSRF token
  and fire the protected DELETE on mere navigation, letting an attacker
  force-logout a signed-in user via a cross-site link.
  """
  @spec account_unavailable(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account_unavailable(conn, params) do
    conn
    |> put_layout(false)
    |> render(:account_unavailable, reason: allowlisted_reason(params))
  end

  @doc """
  Session-preserving 503 landing page for auth-time infrastructure failures.

  The session is untouched, so users recover automatically once the database
  returns — an outage must never mass-logout every signed-in browser.
  """
  @spec service_unavailable(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def service_unavailable(conn, _params) do
    conn
    |> put_status(503)
    |> put_layout(false)
    |> render(:service_unavailable)
  end

  @spec sign_out(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sign_out(conn, params) do
    # Resolve the user from the SESSION — the /auth scope has no auth plug,
    # so conn.assigns never carries a user here (the old assigns read audited
    # a nil actor on every sign-out). A resolver error is treated as no-user
    # for audit purposes; it must never block the sign-out.
    user =
      case session_user_resolver().resolve(get_session(conn)) do
        {:ok, user} -> user
        _unauthenticated_or_error -> nil
      end

    # Derive the authoritative fields server-side BEFORE clearing, then clear
    # unconditionally: a DB failure during derivation maps to bounded values
    # and must never prevent `clear_session/1`.
    audit_fields = %{
      requested_reason: allowlisted_reason(params),
      tenant_status_at_signout: tenant_status_at_signout(user),
      actor_valid: valid_actor_shape?(user)
    }

    conn = clear_session(conn)

    emit_auth_event(:sign_out, user && to_string(user.id), audit_fields)

    redirect(conn, to: "/sign-in")
  end

  defp allowlisted_reason(%{"reason" => reason}) when reason in @sign_out_reasons, do: reason
  defp allowlisted_reason(_params), do: nil

  # Server-derived tenant state at sign-out time (the client-supplied reason
  # is recorded only as untrusted `requested_reason`; voluntary-vs-forced is
  # evidenced by THESE fields). Best-effort read-only check: any lookup
  # failure maps to the bounded value "unavailable".
  defp tenant_status_at_signout(nil), do: nil

  defp tenant_status_at_signout(user) do
    case tenant_access().active?(to_string(user.id)) do
      :ok -> "active"
      {:error, {:tenant_inactive, status}} -> to_string(status)
      {:error, _reason} -> "unavailable"
    end
  rescue
    # This best-effort probe runs BEFORE clear_session/1, so ANY raise here
    # would block the sign-out itself — degrade to the bounded value instead.
    # reach:disable-next-line bare_rescue
    _error -> "unavailable"
  end

  # The same actor-shape check the mount gate performs, recomputed here so
  # the audit row records validity rather than trusting the client.
  defp valid_actor_shape?(nil), do: false

  defp valid_actor_shape?(user),
    do: match?(%{tenant_id: tenant_id} when is_binary(tenant_id), Actor.build(user))

  defp session_user_resolver do
    Application.get_env(:jido_claw, :session_user_resolver, JidoClaw.Web.SessionUser)
  end

  defp tenant_access do
    Application.get_env(:jido_claw, :tenant_access_module, Access)
  end

  defp emit_auth_event(kind, actor_id, payload) do
    AsyncWriter.cast(
      EventAttrs.new(
        tenant_id: tenant_for_auth(),
        event_kind: :auth_event,
        actor_kind: if(actor_id, do: :user, else: :system),
        actor_id: actor_id,
        target_kind: :auth,
        target_id: Atom.to_string(kind),
        payload: payload
      )
    )
  end

  # Auth events are emitted under the "default" tenant since users are
  # untenanted by design (matches Solutions). When a multi-tenant
  # auth boundary lands, this can be lifted from the user record.
  defp tenant_for_auth, do: "default"
end
