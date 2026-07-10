defmodule JidoClaw.Tools.RunCommand do
  @moduledoc """
  Execute a shell command and return its output.

  Routes through `JidoClaw.Shell.SessionManager` which uses jido_shell
  with the Host backend for persistent sessions (CWD, env vars,
  history). SessionManager is required; commands are refused if it is
  unavailable.

  ## Routing

    * `backend: nil` / no backend param — classifier picks host vs VFS;
      requires SessionManager.
    * `backend: "host"` / `"vfs"` — routing override; still goes
      through SessionManager.
    * `backend: "ssh"` + `server: <name>` — routes to the SSH session
      for the declared server. Never falls back to local execution.
  """

  use JidoClaw.Tools.Action,
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
        ignored under MCP serve_mode (stdio framing).
        """
      ]
    ]

  @impl Jido.Action
  def on_before_validate_params(params) do
    params
    |> coerce_backend_param(:backend)
    |> coerce_backend_param("backend")
    |> then(&{:ok, &1})
  end

  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.Tools.OutputShaper
  alias JidoClaw.Tools.RunCommand.ForgeBridge

  @jido_deadline_key :__jido_deadline_ms__

  @impl Jido.Action
  def run(%{command: command} = params, context) do
    MCPScope.wrap(:run_command, params, context, fn enriched ->
      case get_in(enriched, [:tool_context, :sandbox]) do
        :docker ->
          # AR-8b-2 F2: a `:docker` worker routes execution into its Forge
          # Docker session, IGNORING `backend`/`server` entirely — short-circuit
          # before `coerce_backend`/`validate_backend_server` so a model-supplied
          # `backend: "ssh"` can neither preempt the Forge route nor raise a
          # spurious SSH error (the sandbox is set by template policy, not
          # params). Hard-fails if the session is unavailable; never falls back
          # to the host shell. `enriched` is passed (not just the key/timeout) so
          # the bridge can read the outer `:__jido_deadline_ms__` (C2.0).
          forge_key = get_in(enriched, [:tool_context, :forge_session_key])
          ForgeBridge.dispatch(command, forge_key, params, enriched)

        _ ->
          run_host(command, params, enriched)
      end
    end)
  end

  # -- Private ----------------------------------------------------------------

  # The host/VFS/SSH dispatch (the pre-AR-8b-2 path), reached for every non-
  # `:docker` sandbox tier (including `:none`/`:prototype`).
  defp run_host(command, params, enriched) do
    timeout = Map.get(params, :timeout, 30_000)

    workspace_id =
      get_in(enriched, [:tool_context, :workspace_id]) ||
        Map.get(params, :workspace_id, "default")

    project_dir =
      get_in(enriched, [:tool_context, :project_dir]) || File.cwd!()

    backend = coerce_backend(Map.get(params, :backend))
    server = Map.get(params, :server)
    agent_id = get_in(enriched, [:tool_context, :agent_id]) || "main"
    stream_to_display? = OutputShaper.effective_streaming?(params, enriched)
    action_deadline_ms = Map.get(enriched, @jido_deadline_key)

    # The FULL shapeable? predicate, not just enabled?+non-streaming:
    # capturing 512KB for a call the shaper will pass through (e.g. no
    # tenant) would land on OutputLimit's 32KB head-cut instead of the
    # legacy 10KB behavior. Same predicate on both sides means capture
    # and shaping can never disagree.
    capture? = OutputShaper.shapeable?("run_command", params, enriched)

    with :ok <- validate_backend_server(backend, server) do
      dispatch(command, backend, %{
        timeout: timeout,
        workspace_id: workspace_id,
        project_dir: project_dir,
        server: server,
        params: params,
        stream?: stream_to_display?,
        agent_id: agent_id,
        capture?: capture?,
        action_deadline_ms: action_deadline_ms
      })
    end
  end

  defp validate_backend_server(:ssh, server) when is_binary(server) and server != "", do: :ok

  defp validate_backend_server(:ssh, _),
    do: {:error, "server: is required when backend: \"ssh\""}

  defp validate_backend_server(_, _), do: :ok

  # `dispatch_opts` keys: :timeout, :workspace_id, :project_dir, :server,
  # :params, :stream?, :agent_id, :capture?. Bundled to keep arity within
  # credo limits.
  defp dispatch(command, :ssh, dispatch_opts) do
    %{
      timeout: timeout,
      workspace_id: workspace_id,
      project_dir: project_dir,
      server: server,
      stream?: stream?,
      agent_id: agent_id,
      capture?: capture?,
      action_deadline_ms: action_deadline_ms
    } = dispatch_opts

    if session_manager_available?() do
      opts =
        [project_dir: project_dir, backend: :ssh, server: server]
        |> maybe_put_streaming(stream?, agent_id)
        |> maybe_put_capture(capture?)
        |> maybe_put_action_deadline(action_deadline_ms)

      workspace_id
      |> SessionManager.run(command, timeout, opts)
      |> normalize_deadline_result()
    else
      {:error, "SSH requires SessionManager; SessionManager is not running"}
    end
  end

  defp dispatch(command, backend, dispatch_opts) do
    %{
      timeout: timeout,
      workspace_id: workspace_id,
      project_dir: project_dir,
      stream?: stream?,
      agent_id: agent_id,
      capture?: capture?,
      action_deadline_ms: action_deadline_ms
    } = dispatch_opts

    opts =
      [project_dir: project_dir]
      |> maybe_put(:backend, backend)
      |> maybe_put_streaming(stream?, agent_id)
      |> maybe_put_capture(capture?)
      |> maybe_put_action_deadline(action_deadline_ms)

    if session_manager_available?() do
      workspace_id
      |> SessionManager.run(command, timeout, opts)
      |> normalize_deadline_result()
    else
      {:error, "SessionManager is not running; cannot execute command"}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # `stream?` is the EFFECTIVE flag (`OutputShaper.effective_streaming?/2`)
  # — already false under MCP serve_mode (where Display would corrupt the
  # stdio JSON-RPC framing) and under `sandbox: :docker` (the Forge route never
  # streams), so no serve-mode/docker check is needed here.
  defp maybe_put_streaming(opts, false, _agent_id), do: opts

  defp maybe_put_streaming(opts, true, agent_id) do
    Keyword.merge(opts,
      stream_to_display: true,
      agent_id: agent_id,
      tool_name: "run_command"
    )
  end

  defp maybe_put_capture(opts, false), do: opts

  defp maybe_put_capture(opts, true),
    do: Keyword.put(opts, :capture_bytes, OutputShaper.capture_bytes())

  # `Jido.Exec` kills the action task at this absolute monotonic deadline. Pass
  # it into SessionManager rather than deriving a relative timeout here: the
  # manager is serialized, so a call can sit in its mailbox after its caller has
  # already timed out. The manager re-checks immediately before launching the
  # command and refuses a stale call instead of executing it as an orphan.
  defp maybe_put_action_deadline(opts, deadline) when is_integer(deadline),
    do: Keyword.put(opts, :action_deadline_ms, deadline)

  defp maybe_put_action_deadline(opts, _deadline), do: opts

  # These tagged errors are emitted only for action-deadline-aware calls. Keep
  # the codes outside Jido's retryable timeout vocabulary and pin `retry: false`
  # for both retry layers: a timed-out mutating shell command must never be
  # launched a second time automatically.
  defp normalize_deadline_result({:error, {kind, message}})
       when kind in [:action_deadline_exceeded, :command_timeout] do
    {:error,
     %{
       code: deadline_error_code(kind),
       message: message,
       details: %{operation: "run_command", retry: false}
     }}
  end

  defp normalize_deadline_result(result), do: result

  defp deadline_error_code(:action_deadline_exceeded), do: :host_deadline_exceeded
  defp deadline_error_code(:command_timeout), do: :host_command_timeout

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
end
