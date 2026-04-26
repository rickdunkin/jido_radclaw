defmodule JidoClaw.Tools.RunCommand do
  @moduledoc """
  Execute a shell command and return its output.

  Routes through `JidoClaw.Shell.SessionManager` which uses jido_shell
  with the Host backend for persistent sessions (CWD, env vars,
  history). Falls back to `System.cmd` if the session manager is
  unavailable — *except* when `backend: "ssh"` is set, which strictly
  requires SessionManager.

  ## Routing

    * `backend: nil` / no backend param — classifier picks host vs VFS;
      falls back to `System.cmd` if SessionManager is down.
    * `backend: "host"` / `"vfs"` — routing override; still goes
      through SessionManager.
    * `backend: "ssh"` + `server: <name>` — routes to the SSH session
      for the declared server. Never falls back to local execution.
  """

  use Jido.Action,
    name: "run_command",
    description:
      "Execute a shell command and return its output. Use for running tests, builds, scripts, etc.",
    category: "shell",
    tags: ["shell", "exec"],
    output_schema: [
      output: [type: :string, required: true],
      exit_code: [type: :integer, required: true]
    ],
    schema: [
      command: [
        type: :string,
        required: true,
        doc: """
        The command to execute. Simple sandbox-native programs with mount-prefixed
        absolute paths (e.g. `cat /project/mix.exs`, `cd /project && cat mix.exs`)
        are routed to a VFS-aware sandbox session. Commands with pipes/redirects,
        non-allowlisted commands, or host paths are routed to the host shell
        (`sh -c`) unchanged.
        """
      ],
      timeout: [
        type: :integer,
        default: 30_000,
        doc:
          "Timeout in milliseconds. For `backend: \"ssh\"`, set generously — the connect handshake against a slow host can add up to the server's `connect_timeout` (default 10s) on top of the command's own running time."
      ],
      workspace_id: [
        type: :string,
        default: "default",
        doc: "Session workspace for persistent shell state"
      ],
      backend: [
        type: {:in, ["host", "vfs", "ssh"]},
        required: false,
        doc:
          "Routing override. \"host\"/\"vfs\" bypass classifier; \"ssh\" requires the `server` param and routes through the declared SSH target in `.jido/config.yaml`."
      ],
      server: [
        type: :string,
        required: false,
        doc: "SSH server name from `.jido/config.yaml` (required when `backend: \"ssh\"`)."
      ],
      stream_to_display: [
        type: :boolean,
        default: false,
        doc: """
        When true, stream output chunks to `JidoClaw.Display` in real time
        instead of only returning the captured output at the end. Silently
        ignored under MCP serve_mode (stdio framing) and when the
        SessionManager is unavailable.
        """
      ]
    ]

  @max_output_chars 10_000

  @impl true
  def on_before_validate_params(params) do
    params
    |> coerce_backend_param(:backend)
    |> coerce_backend_param("backend")
    |> then(&{:ok, &1})
  end

  @impl true
  def run(%{command: command} = params, context) do
    timeout = Map.get(params, :timeout, 30_000)

    workspace_id =
      get_in(context, [:tool_context, :workspace_id]) ||
        Map.get(params, :workspace_id, "default")

    project_dir =
      get_in(context, [:tool_context, :project_dir]) || File.cwd!()

    backend = coerce_backend(Map.get(params, :backend))
    server = Map.get(params, :server)
    agent_id = get_in(context, [:tool_context, :agent_id]) || "main"
    stream_to_display? = streaming_requested?(params)

    with :ok <- validate_backend_server(backend, server) do
      dispatch(
        command,
        timeout,
        workspace_id,
        project_dir,
        backend,
        server,
        params,
        stream_to_display?,
        agent_id
      )
    end
  end

  # -- Private ----------------------------------------------------------------

  defp validate_backend_server(:ssh, server) when is_binary(server) and server != "", do: :ok

  defp validate_backend_server(:ssh, _),
    do: {:error, "server: is required when backend: \"ssh\""}

  defp validate_backend_server(_, _), do: :ok

  defp dispatch(
         command,
         timeout,
         workspace_id,
         project_dir,
         :ssh,
         server,
         _params,
         stream?,
         agent_id
       ) do
    if session_manager_available?() do
      opts =
        [project_dir: project_dir, backend: :ssh, server: server]
        |> maybe_put_streaming(stream?, agent_id)

      JidoClaw.Shell.SessionManager.run(workspace_id, command, timeout, opts)
    else
      {:error, "SSH requires SessionManager; SessionManager is not running"}
    end
  end

  defp dispatch(
         command,
         timeout,
         workspace_id,
         project_dir,
         backend,
         _server,
         _params,
         stream?,
         agent_id
       ) do
    opts =
      [project_dir: project_dir]
      |> maybe_put(:backend, backend)
      |> maybe_put_streaming(stream?, agent_id)

    if session_manager_available?() do
      JidoClaw.Shell.SessionManager.run(workspace_id, command, timeout, opts)
    else
      # System.cmd fallback gate: ignore stream_to_display: entirely —
      # without SessionManager there are no shell session events for
      # Display to subscribe to.
      run_with_system_cmd(command, timeout)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Drop streaming opts under MCP serve_mode (stdio JSON-RPC) — Display
  # writes raw ANSI to stdout and would corrupt the framing.
  defp maybe_put_streaming(opts, false, _agent_id), do: opts

  defp maybe_put_streaming(opts, true, agent_id) do
    if Application.get_env(:jido_claw, :serve_mode) == :mcp do
      require Logger
      Logger.debug("[RunCommand] dropping stream_to_display: under MCP serve_mode")
      opts
    else
      Keyword.merge(opts,
        stream_to_display: true,
        agent_id: agent_id,
        tool_name: "run_command"
      )
    end
  end

  defp streaming_requested?(params) do
    Map.get(params, :stream_to_display) == true or
      Map.get(params, "stream_to_display") == true
  end

  # Legacy-atom coercion for NimbleOptions. Turns `:host`/`:vfs`/`:ssh`
  # into their string equivalents so the `{:in, [...]}` schema
  # accepts in-process callers that still pass atoms.
  defp coerce_backend_param(params, key) do
    case Map.get(params, key) do
      :host -> Map.put(params, key, "host")
      :vfs -> Map.put(params, key, "vfs")
      :ssh -> Map.put(params, key, "ssh")
      _ -> params
    end
  end

  # Post-validation atom conversion. Explicit case prevents dynamic
  # atom creation; also tolerates direct callers that bypass schema
  # validation and pass raw atoms.
  defp coerce_backend(nil), do: nil
  defp coerce_backend("host"), do: :host
  defp coerce_backend("vfs"), do: :vfs
  defp coerce_backend("ssh"), do: :ssh
  defp coerce_backend(:host), do: :host
  defp coerce_backend(:vfs), do: :vfs
  defp coerce_backend(:ssh), do: :ssh

  defp session_manager_available? do
    case Process.whereis(JidoClaw.Shell.SessionManager) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  defp run_with_system_cmd(command, timeout) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, %{output: truncate(output), exit_code: exit_code}}

      nil ->
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp truncate(output) when byte_size(output) > @max_output_chars do
    String.slice(output, 0, @max_output_chars) <> "\n... (output truncated)"
  end

  defp truncate(output), do: output
end
