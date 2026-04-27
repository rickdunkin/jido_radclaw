defmodule JidoClaw.Test.FakeSSH do
  @moduledoc """
  Test helper that mimics Erlang's `:ssh` and `:ssh_connection` modules
  for integration tests around `Jido.Shell.Backend.SSH`.

  Injected via `:ssh_module` and `:ssh_connection_module` keys on the
  backend config. `JidoClaw.Shell.ServerRegistry.build_ssh_config/3`
  reads these keys from `Application.get_env(:jido_claw, :ssh_test_modules)`
  and merges them into the backend config, so tests only need to set
  the Application env at setup and clear it on teardown.

  Adapted from `deps/jido_shell/test/jido/shell/backend/ssh_test.exs`
  with the following additions: explicit scripted command responses
  (exec time, output, exit code) keyed by command substring, and
  per-test mode switches for connect errors.
  """

  # -- :ssh API surface -------------------------------------------------------

  def connect(host, port, opts, _timeout) do
    case mode() do
      :connect_error ->
        notify({:connect_error, host, port})
        {:error, :econnrefused}

      :connect_nxdomain ->
        {:error, :nxdomain}

      :connect_timeout ->
        {:error, :timeout}

      :connect_auth_error ->
        {:error, ~c"Unable to connect using the available authentication methods"}

      _ ->
        conn = spawn(fn -> Process.sleep(:infinity) end)
        notify({:connect, host, port, opts, conn})
        {:ok, conn}
    end
  end

  def close(conn) do
    notify({:close, conn})
    :ok
  end

  # -- :ssh_connection API surface --------------------------------------------

  def session_channel(conn, _timeout) do
    case mode() do
      :session_channel_error ->
        {:error, :session_channel_failed}

      :session_channel_error_once ->
        if take_first_call(:session_channel) do
          {:error, :session_channel_failed}
        else
          channel_id = :erlang.unique_integer([:positive])
          notify({:session_channel, conn, channel_id})
          {:ok, channel_id}
        end

      _ ->
        channel_id = :erlang.unique_integer([:positive])
        notify({:session_channel, conn, channel_id})
        {:ok, channel_id}
    end
  end

  def setenv(_conn, _channel_id, _var, _value, _timeout), do: :success

  def exec(conn, channel_id, command, _timeout) do
    command_str = to_string(command)
    notify({:exec, conn, channel_id, command_str})

    caller = self()

    case mode() do
      :exec_failure ->
        :failure

      :exec_failure_once ->
        if take_first_call(:exec) do
          :failure
        else
          script_response(caller, conn, channel_id, command_str)
          :success
        end

      :exec_error ->
        {:error, :exec_rejected}

      :no_events ->
        # Simulates a hung remote — the backend's per-channel timeout
        # takes over.
        :success

      _ ->
        script_response(caller, conn, channel_id, command_str)
        :success
    end
  end

  def close(conn, channel_id) do
    notify({:close_channel, conn, channel_id})
    :ok
  end

  # -- Scripted responses -----------------------------------------------------

  # Each clause matches on a substring of the full wrapped command line
  # (the backend wraps as `cd <cwd> && env ... sh -lc '<user command>'`),
  # so tests can pass `"echo hello"` and the clause fires regardless of
  # wrapping.
  defp script_response(caller, conn, channel_id, command_str) do
    cond do
      String.contains?(command_str, "__fake_nonzero__") ->
        send(caller, {:ssh_cm, conn, {:data, channel_id, 1, "oops\n"}})
        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 42}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})

      String.contains?(command_str, "__fake_hang__") ->
        # Backend's timeout kicks in; we emit nothing.
        :ok

      String.contains?(command_str, "__fake_big_output__") ->
        send(caller, {:ssh_cm, conn, {:data, channel_id, 0, String.duplicate("x", 1_000)}})
        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})

      String.contains?(command_str, "__fake_streaming_overflow__") ->
        # Multiple chunks emitted as :output (each within cap), then a chunk
        # that pushes past the cap. With test override = 100 KB streaming cap,
        # 4 × 30 KB chunks fit (120 KB cumulative — last chunk rejected).
        for _ <- 1..4 do
          send(caller, {:ssh_cm, conn, {:data, channel_id, 0, String.duplicate("x", 30_000)}})
        end

        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})

      String.contains?(command_str, "__fake_output_overflow__") ->
        # Single chunk larger than SessionManager's @max_ssh_output_bytes
        # (1_000_000). The backend's OutputLimiter rejects the chunk and
        # terminates the command with {:command, :output_limit_exceeded}.
        send(caller, {:ssh_cm, conn, {:data, channel_id, 0, String.duplicate("x", 1_100_000)}})
        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})

      String.contains?(command_str, "__fake_echo_env__") ->
        # Captures the command as data so tests can inspect the env the
        # backend propagated through `env VAR=... sh -lc <cmd>`.
        send(caller, {:ssh_cm, conn, {:data, channel_id, 0, command_str <> "\n"}})
        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})

      true ->
        send(caller, {:ssh_cm, conn, {:data, channel_id, 0, "ok\n"}})
        send(caller, {:ssh_cm, conn, {:exit_status, channel_id, 0}})
        send(caller, {:ssh_cm, conn, {:eof, channel_id}})
        send(caller, {:ssh_cm, conn, {:closed, channel_id}})
    end
  end

  # -- Test support -----------------------------------------------------------

  @doc "Bind the current process as the observer for fake_ssh notifications."
  def bind_test_pid(pid \\ self()) do
    :persistent_term.put({__MODULE__, :test_pid}, pid)
    :ok
  end

  def clear_test_pid do
    :persistent_term.erase({__MODULE__, :test_pid})
    :ok
  end

  @doc "Set the FakeSSH behavioral mode for the current test."
  def set_mode(mode) when is_atom(mode) do
    :persistent_term.put({__MODULE__, :mode}, mode)
    :persistent_term.erase({__MODULE__, :first_call, :exec})
    :persistent_term.erase({__MODULE__, :first_call, :session_channel})
    :ok
  end

  def clear_mode do
    :persistent_term.erase({__MODULE__, :mode})
    :persistent_term.erase({__MODULE__, :first_call, :exec})
    :persistent_term.erase({__MODULE__, :first_call, :session_channel})
    :ok
  end

  defp mode, do: :persistent_term.get({__MODULE__, :mode}, :normal)

  # First-call tracker for "*_once" modes: returns true exactly once
  # per `tag`, then false on subsequent calls until cleared.
  defp take_first_call(tag) do
    key = {__MODULE__, :first_call, tag}

    case :persistent_term.get(key, :unconsumed) do
      :unconsumed ->
        :persistent_term.put(key, :consumed)
        true

      :consumed ->
        false
    end
  end

  defp notify(event) do
    case :persistent_term.get({__MODULE__, :test_pid}, nil) do
      pid when is_pid(pid) -> send(pid, {:fake_ssh, event})
      _ -> :ok
    end
  end
end
