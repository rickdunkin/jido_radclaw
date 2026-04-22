defmodule JidoClaw.Shell.SSHError do
  @moduledoc """
  Formats SSH errors surfaced by `Jido.Shell.Backend.SSH` into
  user-facing strings that interpolate the server entry's host, port,
  user, and path.

  Kept pure (no state) and separate from `SessionManager` so unit tests
  can exercise every row in the mapping table without going through
  session integration.

  ## Categories

    * `{:command, :start_failed}` with `{:ssh_connect, reason}` —
      connect-time failures. Authentication-specific reasons are
      classified narrowly; all other shapes fall through to a generic
      "connection failed" message.
    * `{:command, :start_failed}` with `{:key_read_failed, reason}` —
      key file could not be read.
    * `{:command, :timeout}` and `{:command, :output_limit_exceeded}` —
      command-lifecycle errors.
    * `{:missing_env, var}` and `{:missing_config, key}` — registry-side
      errors surfaced before the backend is invoked.
    * Anything else renders via `Exception.message/1` when it's a
      `Jido.Shell.Error` struct, otherwise `inspect/1`.

  Note: encrypted-key decode failures typically surface as connect or
  authentication failures (the read succeeds; decode happens inside the
  SSH key callback) and land in the generic "connection failed" /
  "authentication rejected" branches.
  """

  alias Jido.Shell.Error
  alias JidoClaw.Shell.ServerRegistry.ServerEntry

  @doc """
  Format an error with a server entry for display. The entry supplies
  the host/port/user/name interpolation context.
  """
  @spec format(term(), ServerEntry.t()) :: String.t()
  def format(error, entry)

  # `ShellSessionServer.do_run_command/3` wraps a backend `%Error{}` returned
  # from `execute/4` inside another `Error.command(:start_failed, %{reason: <inner>, line: line})`.
  # On reconnect-during-run-command, the inner error carries the real
  # `{:ssh_connect, reason}` shape; unwrap so that case hits the specific
  # connect-reason formatter below instead of the generic catchall.
  def format(
        %Error{code: {:command, :start_failed}, context: %{reason: %Error{} = inner}},
        %ServerEntry{} = entry
      ) do
    format(inner, entry)
  end

  def format(
        %Error{code: {:command, :start_failed}, context: %{reason: {:ssh_connect, reason}}} = _err,
        %ServerEntry{} = entry
      ) do
    format_ssh_connect_reason(reason, entry)
  end

  def format(
        %Error{
          code: {:command, :start_failed},
          context: %{reason: {:key_read_failed, :enoent}, path: path}
        },
        %ServerEntry{name: name}
      ) do
    "SSH to #{name} failed: key file not found at #{path}"
  end

  def format(
        %Error{
          code: {:command, :start_failed},
          context: %{reason: {:key_read_failed, :eacces}, path: path}
        },
        %ServerEntry{name: name}
      ) do
    "SSH to #{name} failed: key file unreadable at #{path} (check permissions)"
  end

  def format(
        %Error{
          code: {:command, :start_failed},
          context: %{reason: {:key_read_failed, reason}, path: path}
        },
        %ServerEntry{name: name}
      ) do
    "SSH to #{name} failed: could not read key file at #{path} (#{inspect(reason)})"
  end

  def format(
        %Error{code: {:command, :start_failed}, context: %{reason: {:missing_config, key}}},
        %ServerEntry{name: name}
      ) do
    "SSH to #{name}: server entry missing required field '#{key}'"
  end

  def format(%Error{code: {:command, :timeout}}, %ServerEntry{name: name}) do
    "SSH to #{name} command timed out"
  end

  def format(%Error{code: {:command, :output_limit_exceeded}}, %ServerEntry{name: name}) do
    "SSH to #{name}: output limit exceeded, command aborted"
  end

  def format({:missing_env, var}, %ServerEntry{name: name}) do
    "SSH to #{name} failed: env var #{var} is not set"
  end

  def format({:missing_config, key}, %ServerEntry{name: name}) do
    "SSH to #{name}: server entry missing required field '#{key}'"
  end

  def format(%Error{} = error, %ServerEntry{name: name}) do
    "SSH to #{name} failed: #{Exception.message(error)}"
  end

  def format(other, %ServerEntry{name: name}) do
    "SSH to #{name} failed: #{inspect(other)}"
  end

  # -- Private ---------------------------------------------------------------

  defp format_ssh_connect_reason(:econnrefused, %ServerEntry{name: name, host: host, port: port}) do
    "SSH to #{name} failed: connection refused at #{host}:#{port}"
  end

  defp format_ssh_connect_reason(:nxdomain, %ServerEntry{name: name, host: host}) do
    "SSH to #{name} failed: host not found (#{host})"
  end

  defp format_ssh_connect_reason(:timeout, %ServerEntry{name: name, host: host, port: port}) do
    "SSH to #{name} failed: connection timed out at #{host}:#{port}"
  end

  defp format_ssh_connect_reason(:ehostunreach, %ServerEntry{name: name, host: host}) do
    "SSH to #{name} failed: host unreachable (#{host})"
  end

  defp format_ssh_connect_reason(reason, %ServerEntry{name: name, host: host, user: user}) do
    if auth_reason?(reason) do
      "SSH to #{name} failed: authentication rejected for #{user}@#{host}"
    else
      "SSH to #{name} failed: connection failed (#{inspect(reason)})"
    end
  end

  # Heuristic — OpenSSH/erlang :ssh surfaces authentication failures in
  # several shapes: the atom `:authentication_failed`, a tuple
  # containing it, or a charlist/string that mentions "auth". Anything
  # else falls through to "connection failed".
  defp auth_reason?(:authentication_failed), do: true
  defp auth_reason?({:authentication_failed, _}), do: true

  defp auth_reason?(reason) when is_list(reason) do
    case List.ascii_printable?(reason) do
      true ->
        reason
        |> to_string()
        |> String.downcase()
        |> String.contains?("auth")

      false ->
        false
    end
  end

  defp auth_reason?(reason) when is_binary(reason) do
    reason |> String.downcase() |> String.contains?("auth")
  end

  defp auth_reason?(_), do: false
end
