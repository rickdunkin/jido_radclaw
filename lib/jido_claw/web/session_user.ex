defmodule JidoClaw.Web.SessionUser do
  @moduledoc """
  Result-preserving session→user resolution for browser surfaces.

  `AshAuthentication.Plug.Helpers.authenticate_resource_from_session/4`
  collapses every failure — including a database outage mid-lookup — to
  `:error`, which the mount hooks and `RequireAuth` plug would then read as
  "signed out" and answer with a redirect to `/sign-in`. This resolver keeps
  the three outcomes distinct: `{:ok, user}`, `:unauthenticated` (the session
  genuinely carries no valid identity), and `{:error, reason}` ("cannot
  determine auth state" — surfaced as a session-preserving 503, never a
  guess).

  Because the app sets `require_token_presence_for_authentication?(true)`,
  the session stores a JWT (under `"<subject_name>_token"`), and resolution
  mirrors the upstream helper's full token-validation chain — all four steps
  are security-critical and must be preserved:

    1. verify the JWT signature + claims;
    2. reject tokens carrying an `"act"` claim;
    3. confirm the `jti` still exists in the token resource with purpose
       `"user"` — the revocation / log-out-everywhere fence;
    4. only then resolve the verified `"sub"` to a user record.

  Taxonomy: missing token / failed JWT verification / `"act"` claim /
  missing-or-revoked token row / user NotFound → `:unauthenticated`; any
  lookup or framework error — connection failures
  (`Core.AshErrors.connection_error?/1`-recognizable shapes) and unexpected
  errors alike → `{:error, reason}`, never silently unauthenticated.

  The `opts` seam (`:verify_jwt`, `:get_token`, `:subject_to_user`) exists so
  tests can drive the infrastructure branches without breaking the SQL
  sandbox; production callers use `resolve/1`.
  """

  alias AshAuthentication.Info
  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource
  alias JidoClaw.Core.AshErrors

  @resource JidoClaw.Accounts.User
  @otp_app :jido_claw
  @db_errors AshErrors.db_errors()

  @type outcome :: {:ok, JidoClaw.Accounts.User.t()} | :unauthenticated | {:error, term()}

  @spec resolve(map(), keyword()) :: outcome()
  def resolve(session, opts \\ []) when is_map(session) do
    case Map.get(session, session_key()) do
      token when is_binary(token) -> resolve_token(token, opts)
      _missing -> :unauthenticated
    end
  end

  defp resolve_token(token, opts) do
    verify_jwt = Keyword.get(opts, :verify_jwt, &default_verify_jwt/1)

    case verify_jwt.(token) do
      {:ok, %{"sub" => subject, "jti" => jti} = claims, _resource}
      when not is_map_key(claims, "act") ->
        lookup(subject, jti, opts)

      _invalid_or_actor_token ->
        :unauthenticated
    end
  end

  # The two DB-touching steps. An Ash non-bang call normally RETURNS its
  # error, but a driver exception can still be raised through non-Ash paths —
  # rescue the canonical infra structs and preserve them as `{:error, _}`;
  # programming raises stay loud.
  defp lookup(subject, jti, opts) do
    get_token = Keyword.get(opts, :get_token, &default_get_token/1)
    subject_to_user = Keyword.get(opts, :subject_to_user, &default_subject_to_user/1)

    case get_token.(jti) do
      # Upstream pins exactly one live row for the jti; none means revoked.
      {:ok, [_token_row]} -> resolve_subject(subject_to_user, subject)
      {:ok, _revoked_or_ambiguous} -> :unauthenticated
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in @db_errors -> {:error, error}
  end

  defp resolve_subject(subject_to_user, subject) do
    case subject_to_user.(subject) do
      {:ok, user} -> {:ok, user}
      {:error, %Ash.Error.Query.NotFound{}} -> :unauthenticated
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} -> :unauthenticated
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_verify_jwt(token), do: Jwt.verify(token, @otp_app)

  defp default_get_token(jti) do
    token_resource = Info.authentication_tokens_token_resource!(@resource)
    TokenResource.Actions.get_token(token_resource, %{"jti" => jti, "purpose" => "user"})
  end

  defp default_subject_to_user(subject), do: AshAuthentication.subject_to_user(subject, @resource)

  # The token-presence session slot (`"user_token"` today), derived from the
  # resource's subject name instead of hardcoded so an upstream rename cannot
  # silently de-authenticate every session.
  defp session_key, do: "#{Info.authentication_subject_name!(@resource)}_token"
end
