defmodule JidoClaw.Web.AdminAccessTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Web.AdminAccess` — allowlist parsing,
  config-source precedence, and `admin?/1` membership checks.

  `async: false`: the `:admin_emails` Application env and the
  `JIDOCLAW_ADMIN_EMAILS` system env are global mutable state.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Web.AdminAccess

  @env_var "JIDOCLAW_ADMIN_EMAILS"

  setup do
    original_app_env = Application.fetch_env(:jido_claw, :admin_emails)
    original_sys_env = System.get_env(@env_var)

    on_exit(fn ->
      case original_app_env do
        {:ok, value} -> Application.put_env(:jido_claw, :admin_emails, value)
        :error -> Application.delete_env(:jido_claw, :admin_emails)
      end

      if original_sys_env do
        System.put_env(@env_var, original_sys_env)
      else
        System.delete_env(@env_var)
      end
    end)

    Application.delete_env(:jido_claw, :admin_emails)
    System.delete_env(@env_var)
    :ok
  end

  describe "parse_admin_emails/1" do
    test "nil yields an empty allowlist" do
      assert AdminAccess.parse_admin_emails(nil) == []
    end

    test "empty and blank-only binaries yield an empty allowlist" do
      assert AdminAccess.parse_admin_emails("") == []
      assert AdminAccess.parse_admin_emails("  , ,") == []
    end

    test "splits a comma-separated binary, trimming whitespace" do
      assert AdminAccess.parse_admin_emails(" a@b.com , c@d.com ") == ["a@b.com", "c@d.com"]
    end

    test "downcases entries" do
      assert AdminAccess.parse_admin_emails("Admin@Example.COM") == ["admin@example.com"]
    end

    test "drops blank entries between commas" do
      assert AdminAccess.parse_admin_emails("a@b.com,,c@d.com,") == ["a@b.com", "c@d.com"]
    end

    test "normalizes a list, stringifying entries" do
      assert AdminAccess.parse_admin_emails([" A@B.com ", :"c@d.com", ""]) ==
               ["a@b.com", "c@d.com"]
    end
  end

  describe "admin_emails/0" do
    test "defaults to an empty allowlist when nothing is configured" do
      assert AdminAccess.admin_emails() == []
    end

    test "reads and normalizes the Application env seam" do
      Application.put_env(:jido_claw, :admin_emails, [" Admin@Example.com "])
      assert AdminAccess.admin_emails() == ["admin@example.com"]
    end

    test "falls back to the system env, normalized" do
      System.put_env(@env_var, " You@Example.com ,ops@example.com")
      assert AdminAccess.admin_emails() == ["you@example.com", "ops@example.com"]
    end

    test "Application env takes precedence over system env" do
      System.put_env(@env_var, "sys@example.com")
      Application.put_env(:jido_claw, :admin_emails, "app@example.com")
      assert AdminAccess.admin_emails() == ["app@example.com"]
    end
  end

  describe "admin?/1" do
    test "nil user is never admin" do
      Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
      refute AdminAccess.admin?(nil)
    end

    test "false for everyone when the allowlist is empty" do
      refute AdminAccess.admin?(%{email: "a@b.com"})
    end

    test "true for an allowlisted email" do
      Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
      assert AdminAccess.admin?(%{email: "a@b.com"})
    end

    test "matches case-insensitively, including Ash.CiString emails" do
      Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
      assert AdminAccess.admin?(%{email: "A@B.COM"})
      assert AdminAccess.admin?(%{email: Ash.CiString.new("A@b.Com")})
    end

    test "false for a non-allowlisted email" do
      Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
      refute AdminAccess.admin?(%{email: "intruder@b.com"})
    end

    test "false for a user without an email" do
      Application.put_env(:jido_claw, :admin_emails, ["a@b.com"])
      refute AdminAccess.admin?(%{email: nil})
      refute AdminAccess.admin?(%{})
    end
  end
end
