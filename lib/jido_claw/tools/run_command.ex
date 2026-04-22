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

  The legacy `force: :host | :vfs` param still works unchanged.
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
      force: [
        type: {:in, [:host, :vfs, nil]},
        required: false,
        doc: """
        Override the automatic host/VFS classifier. `:host` forces sh -c;
        `:vfs` forces the jido_shell sandbox (useful for bare `ls`/`pwd` that
        should observe the VFS session's cwd, or commands with literal shell
        metachars in quoted args).
        """
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

    with :ok <- validate_backend_server(backend, server) do
      dispatch(command, timeout, workspace_id, project_dir, backend, server, params)
    end
  end

  # -- Private ----------------------------------------------------------------

  defp validate_backend_server(:ssh, server) when is_binary(server) and server != "", do: :ok

  defp validate_backend_server(:ssh, _),
    do: {:error, "server: is required when backend: \"ssh\""}

  defp validate_backend_server(_, _), do: :ok

  defp dispatch(command, timeout, workspace_id, project_dir, :ssh, server, _params) do
    if session_manager_available?() do
      opts = [project_dir: project_dir, backend: :ssh, server: server]
      JidoClaw.Shell.SessionManager.run(workspace_id, command, timeout, opts)
    else
      {:error, "SSH requires SessionManager; SessionManager is not running"}
    end
  end

  defp dispatch(command, timeout, workspace_id, project_dir, backend, _server, params) do
    opts =
      [project_dir: project_dir, force: Map.get(params, :force)]
      |> maybe_put(:backend, backend)

    if session_manager_available?() do
      JidoClaw.Shell.SessionManager.run(workspace_id, command, timeout, opts)
    else
      run_with_system_cmd(command, timeout)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
