defmodule JidoClaw.Shell.SSHErrorTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.Error
  alias JidoClaw.Shell.ServerRegistry.ServerEntry
  alias JidoClaw.Shell.SSHError

  defp entry(overrides \\ %{}) do
    struct!(
      %ServerEntry{
        name: "staging",
        host: "web01.example.com",
        user: "deploy",
        port: 22,
        auth_kind: :default,
        cwd: "/",
        env: %{},
        shell: "sh",
        connect_timeout: 10_000
      },
      overrides
    )
  end

  defp connect_error(reason, host \\ "web01.example.com", port \\ 22) do
    Error.command(:start_failed, %{reason: {:ssh_connect, reason}, host: host, port: port})
  end

  describe "connect-time errors" do
    test "econnrefused interpolates host and port" do
      assert SSHError.format(connect_error(:econnrefused), entry()) =~
               "connection refused at web01.example.com:22"
    end

    test "nxdomain references host" do
      assert SSHError.format(connect_error(:nxdomain), entry()) =~
               "host not found (web01.example.com)"
    end

    test "timeout interpolates host and port" do
      assert SSHError.format(connect_error(:timeout), entry(%{port: 2222})) =~
               "connection timed out at web01.example.com:2222"
    end

    test "ehostunreach references host" do
      assert SSHError.format(connect_error(:ehostunreach), entry()) =~
               "host unreachable (web01.example.com)"
    end

    test "authentication_failed atom classified as auth rejected" do
      assert SSHError.format(connect_error(:authentication_failed), entry()) =~
               "authentication rejected for deploy@web01.example.com"
    end

    test "charlist with 'auth' substring classified as auth rejected" do
      err =
        connect_error(~c"Unable to connect using the available authentication methods")

      assert SSHError.format(err, entry()) =~
               "authentication rejected for deploy@web01.example.com"
    end

    test "generic reason falls into connection failed branch" do
      msg = SSHError.format(connect_error(:something_unexpected), entry())
      assert msg =~ "SSH to staging failed: connection failed"
      assert msg =~ "something_unexpected"
    end
  end

  describe "key read errors" do
    test "enoent formats 'not found at <path>'" do
      err =
        Error.command(:start_failed, %{
          reason: {:key_read_failed, :enoent},
          path: "/nope/key"
        })

      assert SSHError.format(err, entry()) ==
               "SSH to staging failed: key file not found at /nope/key"
    end

    test "eacces formats 'unreadable at <path>'" do
      err =
        Error.command(:start_failed, %{
          reason: {:key_read_failed, :eacces},
          path: "/root/key"
        })

      msg = SSHError.format(err, entry())
      assert msg =~ "key file unreadable at /root/key"
      assert msg =~ "check permissions"
    end

    test "other key reasons include reason inspect" do
      err =
        Error.command(:start_failed, %{
          reason: {:key_read_failed, :eio},
          path: "/weird/key"
        })

      msg = SSHError.format(err, entry())
      assert msg =~ "could not read key file at /weird/key"
      assert msg =~ "eio"
    end
  end

  describe "command-lifecycle errors" do
    test "timeout" do
      err = Error.command(:timeout, %{line: "sleep 5"})
      assert SSHError.format(err, entry()) == "SSH to staging command timed out"
    end

    test "output_limit_exceeded" do
      err = Error.command(:output_limit_exceeded, %{})
      assert SSHError.format(err, entry()) =~ "output limit exceeded"
    end
  end

  describe "registry-side errors" do
    test "missing_env tuple" do
      assert SSHError.format({:missing_env, "SSH_PROD_PW"}, entry()) ==
               "SSH to staging failed: env var SSH_PROD_PW is not set"
    end

    test "missing_config tuple" do
      msg = SSHError.format({:missing_config, :host}, entry())
      assert msg =~ "server entry missing required field 'host'"
    end

    test "start_failed with missing_config reason" do
      err = Error.command(:start_failed, %{reason: {:missing_config, :user}})
      msg = SSHError.format(err, entry())
      assert msg =~ "server entry missing required field 'user'"
    end
  end

  describe "fallback formatting" do
    test "unknown Jido.Shell.Error renders via Exception.message/1" do
      err = Error.command(:crashed, %{line: "foo", reason: "boom"})
      msg = SSHError.format(err, entry())
      assert msg =~ "SSH to staging failed: "
      assert msg =~ "crashed"
    end

    test "arbitrary term renders via inspect" do
      assert SSHError.format(:unknown_thing, entry()) ==
               "SSH to staging failed: :unknown_thing"
    end
  end

  describe "double-wrapped start_failed (reconnect path)" do
    test "unwraps inner connect error and formats specific reason" do
      # `ShellSessionServer.do_run_command/3` wraps a backend-returned
      # `%Jido.Shell.Error{}` in another `Error.command(:start_failed, …)`.
      # The unwrap clause must reach the inner connect reason.
      inner = connect_error(:econnrefused)
      outer = Error.command(:start_failed, %{reason: inner, line: "true"})

      assert SSHError.format(outer, entry()) ==
               "SSH to staging failed: connection refused at web01.example.com:22"
    end
  end
end
