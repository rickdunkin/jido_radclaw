defmodule JidoClaw.Web.AdminAccess do
  @moduledoc """
  Admin allowlist for the `/admin` (AshAdmin) surface.

  Membership is an env-driven email allowlist — `JIDOCLAW_ADMIN_EMAILS`,
  a comma-separated list — with no role column or migration. The default
  is empty, so `/admin` is unreachable for everyone until an operator
  explicitly grants access.

  The env var is read per call (not cached at boot) because
  `JidoClaw.Application.load_dotenv/0` populates `.env` values *after*
  runtime config has already evaluated; reading lazily means `.env`-supplied
  allowlists work without ordering gymnastics. Tests use the
  `:admin_emails` Application env as a seam, which takes precedence.
  """

  @app_env_key :admin_emails
  @env_var "JIDOCLAW_ADMIN_EMAILS"

  @doc """
  True when `user` is non-nil and its email (case-insensitive) is in the
  configured admin allowlist.
  """
  @spec admin?(struct() | nil) :: boolean()
  def admin?(nil), do: false

  def admin?(%{email: email}) when not is_nil(email) do
    String.downcase(to_string(email)) in admin_emails()
  end

  def admin?(_user), do: false

  @doc """
  The normalized (downcased, trimmed) admin email allowlist. Sourced from
  the `:admin_emails` Application env when set, else `#{@env_var}`.
  """
  @spec admin_emails() :: [String.t()]
  def admin_emails do
    parse_admin_emails(Application.get_env(:jido_claw, @app_env_key) || System.get_env(@env_var))
  end

  @doc """
  Normalize a raw allowlist value: comma-separated binary or list of
  emails → downcased, trimmed list with blanks dropped. `nil` → `[]`.
  """
  @spec parse_admin_emails(String.t() | [String.t() | atom()] | nil) :: [String.t()]
  def parse_admin_emails(nil), do: []

  def parse_admin_emails(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> normalize_entries()
  end

  def parse_admin_emails(raw) when is_list(raw) do
    raw
    |> Enum.map(&to_string/1)
    |> normalize_entries()
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.map(&String.downcase(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
  end
end
