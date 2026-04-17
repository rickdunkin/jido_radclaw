defmodule JidoClaw.Tools.RunCommand do
  @moduledoc """
  Execute a shell command and return its output.

  Routes through `JidoClaw.Shell.SessionManager` which uses jido_shell
  with the Host backend for persistent sessions (CWD, env vars, history).
  Falls back to `System.cmd` if the session manager is unavailable.
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
      timeout: [type: :integer, default: 30_000, doc: "Timeout in milliseconds"],
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
      ]
    ]

  @max_output_chars 10_000

  @impl true
  def run(%{command: command} = params, context) do
    timeout = Map.get(params, :timeout, 30_000)

    workspace_id =
      get_in(context, [:tool_context, :workspace_id]) ||
        Map.get(params, :workspace_id, "default")

    project_dir =
      get_in(context, [:tool_context, :project_dir]) || File.cwd!()

    opts = [project_dir: project_dir, force: Map.get(params, :force)]

    if session_manager_available?() do
      JidoClaw.Shell.SessionManager.run(workspace_id, command, timeout, opts)
    else
      run_with_system_cmd(command, timeout)
    end
  end

  # -- Private ----------------------------------------------------------------

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
