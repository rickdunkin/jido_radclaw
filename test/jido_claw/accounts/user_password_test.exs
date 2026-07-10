defmodule JidoClaw.Accounts.UserPasswordTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Accounts.User

  test "registration rejects short passwords and accepts the documented minimum" do
    email = "password-policy-#{System.unique_integer([:positive])}@example.com"

    assert {:error, %Ash.Error.Invalid{}} =
             User.register_with_password(
               %{
                 email: email,
                 password: "short",
                 password_confirmation: "short"
               },
               authorize?: false
             )

    password = "twelve-chars"

    assert {:ok, _user} =
             User.register_with_password(
               %{
                 email: email,
                 password: password,
                 password_confirmation: password
               },
               authorize?: false
             )
  end

  test "registration accepts 72 bytes and rejects longer ASCII and multibyte passwords" do
    exact_ascii = String.duplicate("a", 72)
    too_long_ascii = exact_ascii <> "a"
    exact_multibyte = String.duplicate("é", 36)
    too_long_multibyte = exact_multibyte <> "é"

    assert byte_size(exact_ascii) == 72
    assert byte_size(exact_multibyte) == 72
    assert String.length(too_long_multibyte) < 72
    assert byte_size(too_long_multibyte) > 72

    for password <- [exact_ascii, exact_multibyte] do
      assert {:ok, _user} =
               User.register_with_password(
                 %{
                   email: unique_email("accepted"),
                   password: password,
                   password_confirmation: password
                 },
                 authorize?: false
               )
    end

    assert {:error, %Ash.Error.Invalid{} = ascii_error} =
             User.register_with_password(
               %{
                 email: unique_email("rejected-ascii"),
                 password: too_long_ascii,
                 password_confirmation: too_long_ascii
               },
               authorize?: false
             )

    assert Exception.message(ascii_error) =~ "length must be less than or equal to 72"

    assert {:error, %Ash.Error.Invalid{} = multibyte_error} =
             User.register_with_password(
               %{
                 email: unique_email("rejected-multibyte"),
                 password: too_long_multibyte,
                 password_confirmation: too_long_multibyte
               },
               authorize?: false
             )

    assert Exception.message(multibyte_error) =~ "byte size of no more than 72"
  end

  test "every password action carries the same character and bcrypt byte bounds" do
    for action_name <- [
          :sign_in_with_password,
          :register_with_password,
          :change_password,
          :reset_password_with_token
        ] do
      action = Ash.Resource.Info.action(User, action_name)
      argument = Enum.find(action.arguments, &(&1.name == :password))

      if action_name != :sign_in_with_password do
        assert argument.constraints[:min_length] == 12
      end

      assert argument.constraints[:max_length] == 72
    end

    for {action_name, argument_name} <- [
          register_with_password: :password_confirmation,
          change_password: :current_password,
          change_password: :password_confirmation,
          reset_password_with_token: :password_confirmation
        ] do
      action = Ash.Resource.Info.action(User, action_name)
      argument = Enum.find(action.arguments, &(&1.name == argument_name))

      assert argument.constraints[:max_length] == 72
    end

    assert byte_validations(:sign_in_with_password) == %{password: 72}

    assert byte_validations(:register_with_password) == %{
             password: 72,
             password_confirmation: 72
           }

    assert byte_validations(:change_password) == %{
             current_password: 72,
             password: 72,
             password_confirmation: 72
           }

    assert byte_validations(:reset_password_with_token) == %{
             password: 72,
             password_confirmation: 72
           }
  end

  test "sign-in rejects an over-72-byte candidate before bcrypt comparison" do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    assert {:error,
            %AshAuthentication.Errors.AuthenticationFailed{
              caused_by: %Ash.Error.Invalid{} = error
            }} =
             AshAuthentication.Strategy.action(strategy, :sign_in, %{
               "email" => unique_email("sign-in"),
               "password" => String.duplicate("é", 37)
             })

    assert Exception.message(error) =~ "byte size of no more than 72"
  end

  defp byte_validations(action_name) do
    action = Ash.Resource.Info.action(User, action_name)

    entries =
      if Map.has_key?(action, :changes) do
        action.changes
      else
        action.preparations
      end

    for %Ash.Resource.Validation{
          module: Ash.Resource.Validation.ByteSize,
          opts: opts
        } <- entries,
        into: %{} do
      {opts[:attribute], opts[:max]}
    end
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
