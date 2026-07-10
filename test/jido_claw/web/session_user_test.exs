defmodule JidoClaw.Web.SessionUserTest do
  @moduledoc """
  Direct unit coverage for the result-preserving session resolver — the
  security boundary the mount hooks and `RequireAuth` ride on. The app-env
  mount seams only test routing; the four token-validation steps (JWT
  verify, `"act"` rejection, jti revocation fence, subject lookup) and the
  unauthenticated-vs-infra split are pinned HERE.

  Valid-session fixtures go through the official
  `AshAuthentication.Plug.Helpers.store_in_session/2`, pinning upstream
  session-format compatibility; infrastructure branches use the resolver's
  injected dependency seam so PostgreSQL and the SQL sandbox stay undisturbed.
  """
  use JidoClaw.TenantCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Test, only: [init_test_session: 2]

  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource
  alias JidoClaw.Accounts.Token
  alias JidoClaw.Accounts.User
  alias JidoClaw.Web.SessionUser

  describe "real-session paths (official store_in_session fixture)" do
    test "a freshly stored session resolves to the user" do
      user = register_user!()

      assert {:ok, resolved} = SessionUser.resolve(session_for(user))
      assert resolved.id == user.id
    end

    test "an empty session is :unauthenticated" do
      assert SessionUser.resolve(%{}) == :unauthenticated
    end

    test "a malformed JWT is :unauthenticated" do
      assert SessionUser.resolve(%{"user_token" => "not-a-jwt"}) == :unauthenticated
    end

    test "a revoked token row is :unauthenticated (the log-out-everywhere fence)" do
      user = register_user!()
      session = session_for(user)

      # Revoke by deleting the jti row — the resolver must confirm presence,
      # not merely verify the signature (which would still pass here).
      {:ok, %{"jti" => jti}} = Jwt.peek(session["user_token"])

      assert {:ok, [row]} =
               TokenResource.Actions.get_token(Token, %{"jti" => jti, "purpose" => "user"})

      :ok = Ash.destroy(row, authorize?: false)

      assert SessionUser.resolve(session) == :unauthenticated
    end
  end

  describe "seam-driven branches" do
    test "a token carrying an \"act\" claim is :unauthenticated" do
      verify = fn _token ->
        {:ok, %{"sub" => "user?id=x", "jti" => "j", "act" => %{"sub" => "impersonator"}}, User}
      end

      assert SessionUser.resolve(%{"user_token" => "signed"}, verify_jwt: verify) ==
               :unauthenticated
    end

    test "a missing token row is :unauthenticated" do
      outcome =
        SessionUser.resolve(%{"user_token" => "signed"},
          verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
          get_token: fn _jti -> {:ok, []} end
        )

      assert outcome == :unauthenticated
    end

    test "a token-lookup infrastructure error is preserved, never unauthenticated" do
      error = %DBConnection.ConnectionError{message: "tcp closed"}

      outcome =
        SessionUser.resolve(%{"user_token" => "signed"},
          verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
          get_token: fn _jti -> {:error, error} end
        )

      assert outcome == {:error, error}
    end

    test "a RAISED connection error during lookup is preserved as {:error, _}" do
      outcome =
        SessionUser.resolve(%{"user_token" => "signed"},
          verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
          get_token: fn _jti -> raise DBConnection.ConnectionError, "pool timeout" end
        )

      assert {:error, %DBConnection.ConnectionError{}} = outcome
    end

    test "a user-lookup infrastructure error is preserved, never unauthenticated" do
      error = %Ash.Error.Unknown{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error: "** (DBConnection.ConnectionError) tcp recv: closed"
          }
        ]
      }

      outcome =
        SessionUser.resolve(%{"user_token" => "signed"},
          verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
          get_token: fn _jti -> {:ok, [:token_row]} end,
          subject_to_user: fn _subject -> {:error, error} end
        )

      assert outcome == {:error, error}
    end

    test "an unexpected framework error is ALSO {:error, _} — never a silent sign-out" do
      outcome =
        SessionUser.resolve(%{"user_token" => "signed"},
          verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
          get_token: fn _jti -> {:error, :misconfigured_token_resource} end
        )

      assert outcome == {:error, :misconfigured_token_resource}
    end

    test "a user NotFound is :unauthenticated" do
      not_found = NotFound.exception([])

      for shape <- [not_found, Invalid.exception(errors: [not_found])] do
        outcome =
          SessionUser.resolve(%{"user_token" => "signed"},
            verify_jwt: fn _ -> {:ok, %{"sub" => "user?id=x", "jti" => "j"}, User} end,
            get_token: fn _jti -> {:ok, [:token_row]} end,
            subject_to_user: fn _subject -> {:error, shape} end
          )

        assert outcome == :unauthenticated
      end
    end
  end

  defp register_user! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "session-user-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    user
  end

  defp session_for(user) do
    build_conn()
    |> init_test_session(%{})
    |> Helpers.store_in_session(user)
    |> Plug.Conn.get_session()
  end
end
