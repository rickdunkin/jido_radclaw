defmodule JidoClaw.Forge.Sandbox.Docker do
  @moduledoc """
  Sandbox implementation using Docker Sandboxes (`sbx` CLI) for
  OS-level isolation. Each Forge session gets its own microVM with a
  dedicated Docker daemon, filesystem, and network.

  Requires Docker Desktop >= 4.40 with `sbx` CLI installed and authenticated.
  """

  @behaviour JidoClaw.Forge.Sandbox.Behaviour
  require Logger

  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Security.Redaction.Env

  defstruct [:sandbox_name, :workspace_dir, :sandbox_id]

  @type t :: %__MODULE__{
          sandbox_name: String.t(),
          workspace_dir: String.t(),
          sandbox_id: String.t()
        }

  @impl JidoClaw.Forge.Sandbox.Behaviour
  @spec create(map()) ::
          {:error, :sbx_not_found | {:sbx_create_failed, pos_integer(), any()}}
          | {:ok, t(), binary()}
  def create(spec) do
    case System.find_executable("sbx") do
      nil ->
        {:error, :sbx_not_found}

      _path ->
        do_create(spec)
    end
  end

  defp do_create(spec) do
    sandbox_id = "#{:erlang.unique_integer([:positive])}"
    sandbox_name = "forge-#{sandbox_id}"
    workspace_dir = Path.join(workspace_base(), sandbox_name)
    File.mkdir_p!(workspace_dir)

    agent_type = sandbox_agent_type(spec)
    args = build_create_args(sandbox_name, agent_type, workspace_dir, spec)

    case System.cmd("sbx", args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
      {_output, 0} ->
        client = %__MODULE__{
          sandbox_name: sandbox_name,
          workspace_dir: workspace_dir,
          sandbox_id: sandbox_id
        }

        # Inject OneCLI proxy env if configured
        onecli_env = onecli_env(sandbox_id)
        if map_size(onecli_env) > 0, do: inject_env(client, onecli_env)

        {:ok, client, sandbox_id}

      {error_output, code} ->
        File.rm_rf(workspace_dir)
        {:error, {:sbx_create_failed, code, error_output}}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec(%__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir}, command, opts) do
    args = build_exec_args(sandbox_name, workspace_dir, command)
    timeout = Keyword.get(opts, :timeout)

    if timeout do
      exec_with_timeout(args, timeout)
    else
      System.cmd("sbx", args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env())
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec_argv(
        %__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir},
        command,
        args,
        opts
      ) do
    sbx_args = build_exec_argv_args(sandbox_name, workspace_dir, command, args)
    timeout = Keyword.get(opts, :timeout)

    if timeout do
      exec_with_timeout(sbx_args, timeout)
    else
      System.cmd("sbx", sbx_args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env())
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def run(
        %__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir},
        agent_type,
        args,
        opts
      ) do
    name = Keyword.get(opts, :name, sandbox_name)
    sbx_args = build_run_args(name, agent_type, workspace_dir, args)
    timeout = Keyword.get(opts, :timeout)

    if timeout do
      exec_with_timeout(sbx_args, timeout)
    else
      System.cmd("sbx", sbx_args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env())
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def spawn(%__MODULE__{sandbox_name: sandbox_name}, command, args, _opts) do
    case System.find_executable("sbx") do
      nil ->
        {:error, :sbx_not_found}

      sbx_path ->
        port =
          Port.open(
            {:spawn_executable, sbx_path},
            [
              :binary,
              :exit_status,
              args: ["exec", sandbox_name, command | args],
              env: Env.scrubbed_port_env()
            ]
          )

        {:ok, port}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def write_file(%__MODULE__{workspace_dir: workspace_dir}, path, content) do
    with {:ok, full_path} <- resolve_path(workspace_dir, path),
         :ok <- File.mkdir_p(Path.dirname(full_path)) do
      File.write(full_path, content)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def read_file(%__MODULE__{workspace_dir: workspace_dir}, path) do
    with {:ok, full_path} <- resolve_path(workspace_dir, path) do
      File.read(full_path)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def inject_env(%__MODULE__{workspace_dir: workspace_dir}, env) do
    env_file = env_file_path(workspace_dir)

    # Merge with existing env file if present
    existing =
      case File.read(env_file) do
        {:ok, content} -> parse_env_file(content)
        {:error, _} -> %{}
      end

    merged = Map.merge(existing, Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end))

    lines = Enum.map_join(merged, "\n", fn {k, v} -> "#{k}=#{v}" end)

    File.write(env_file, lines <> "\n")
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def destroy(%__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir}, _sandbox_id) do
    case System.cmd("sbx", ["rm", "--force", sandbox_name],
           stderr_to_stdout: true,
           env: Env.scrubbed_cmd_env()
         ) do
      {_output, 0} ->
        :ok

      {error_output, code} ->
        Logger.warning(
          "[Forge.DockerSandbox] Failed to remove sandbox #{sandbox_name} " <>
            "(exit #{code}): #{String.trim(error_output)}"
        )
    end

    File.rm_rf(workspace_dir)
    :ok
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def impl_module, do: __MODULE__

  # --- Private ---

  defp build_create_args(sandbox_name, agent_type, workspace_dir, spec) do
    args =
      ["create", "--name", sandbox_name]
      # Add OneCLI CA cert mount if configured
      |> maybe_add_ca_cert_mount()
      # Add any extra mounts from config
      |> add_extra_mounts()
      # Add resource-declared mounts from spec
      |> add_spec_mounts(spec)

    args ++ [agent_type, workspace_dir]
  end

  defp build_run_args(sandbox_name, agent_type, workspace_dir, args) do
    base_args = ["run", agent_type, "--name", sandbox_name]

    # Add --env-file if .forge_env exists
    env_file = env_file_path(workspace_dir)

    sbx_args =
      if File.exists?(env_file) do
        base_args ++ ["--env-file", env_file]
      else
        base_args
      end

    Enum.concat([sbx_args, ["--"], args])
  end

  defp build_exec_args(sandbox_name, workspace_dir, command) do
    # Add --env-file if .forge_env exists
    env_file = env_file_path(workspace_dir)

    args =
      if File.exists?(env_file) do
        ["exec", "--env-file", env_file]
      else
        ["exec"]
      end

    args ++ [sandbox_name, "sh", "-c", command]
  end

  defp build_exec_argv_args(sandbox_name, workspace_dir, command, command_args) do
    env_file = env_file_path(workspace_dir)

    args =
      if File.exists?(env_file) do
        ["exec", "--env-file", env_file]
      else
        ["exec"]
      end

    args ++ [sandbox_name, command | command_args]
  end

  defp exec_with_timeout(args, timeout) do
    case System.find_executable("sbx") do
      nil ->
        {"sbx: command not found", 127}

      sbx ->
        # On timeout OsCmd kills the host-side `sbx` client tree — that
        # is the fix here; the in-container command keeps running until
        # the sandbox is destroyed. The microVM contains the blast
        # radius, but a timed-out command still running inside a
        # long-lived sandbox can consume its CPU/memory and affect later
        # commands in that same sandbox. Accepted for now; revisit if
        # sbx grows a remote-cancel API.
        case OsCmd.run(sbx, args, env: Env.scrubbed_cmd_env(), timeout: timeout) do
          {_partial, :timeout} -> {"timeout after #{timeout}ms", 124}
          result -> result
        end
    end
  end

  defp sandbox_agent_type(spec) do
    case Map.get(spec, :runner, :shell) do
      :claude_code -> "claude"
      :codex -> "codex"
      :shell -> "shell"
      _ -> config_default_agent()
    end
  end

  defp resolve_path(workspace_dir, path) do
    case Path.safe_relative(path, workspace_dir) do
      {:ok, relative_path} -> {:ok, Path.join(workspace_dir, relative_path)}
      :error -> {:error, {:unsafe_path, path}}
    end
  end

  defp env_file_path(workspace_dir) do
    Path.join(workspace_dir, ".forge_env")
  end

  defp parse_env_file(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp workspace_base do
    Keyword.get(config(), :workspace_base, "/tmp/jidoclaw_forge")
  end

  defp config_default_agent do
    Keyword.get(config(), :default_agent, "shell")
  end

  defp config do
    Application.get_env(:jido_claw, :forge_docker_sandbox, [])
  end

  defp onecli_config do
    Application.get_env(:jido_claw, :onecli, [])
  end

  defp onecli_env(sandbox_id) do
    config = onecli_config()

    if Keyword.get(config, :enabled, false) do
      gateway_url = Keyword.get(config, :gateway_url)
      token = resolve_agent_token(sandbox_id, config)

      env = %{
        "HTTP_PROXY" => gateway_url,
        "HTTPS_PROXY" => gateway_url
      }

      env =
        if token do
          Map.put(env, "PROXY_AUTHORIZATION", "Bearer #{token}")
        else
          env
        end

      # Add CA cert env vars if cert path is configured
      case Keyword.get(config, :ca_cert_path) do
        nil ->
          env

        _ca_path ->
          container_cert = "/usr/local/share/ca-certificates/onecli.crt"

          env
          |> Map.put("NODE_EXTRA_CA_CERTS", container_cert)
          |> Map.put("SSL_CERT_FILE", container_cert)
      end
    else
      %{}
    end
  end

  defp resolve_agent_token(_sandbox_id, config) do
    case Keyword.get(config, :agent_tokens, []) do
      [] -> nil
      tokens -> Enum.random(tokens)
    end
  end

  defp maybe_add_ca_cert_mount(args) do
    config = onecli_config()

    if Keyword.get(config, :enabled, false) do
      case Keyword.get(config, :ca_cert_path) do
        nil ->
          args

        ca_path when is_binary(ca_path) ->
          if File.exists?(ca_path) do
            # Mount CA cert as read-only extra path
            args ++ ["--mount", "#{ca_path}:/usr/local/share/ca-certificates/onecli.crt:ro"]
          else
            Logger.warning("[Forge.DockerSandbox] OneCLI CA cert not found at #{ca_path}")
            args
          end
      end
    else
      args
    end
  end

  defp add_extra_mounts(args) do
    mounts = Keyword.get(config(), :extra_mounts, [])

    args ++
      Enum.flat_map(mounts, fn {host_path, container_path, mode} ->
        ["--mount", "#{host_path}:#{container_path}:#{mode}"]
      end)
  end

  defp add_spec_mounts(args, spec) do
    mounts = Map.get(spec, :extra_mounts, [])

    args ++
      Enum.flat_map(mounts, fn {host_path, container_path, mode} ->
        ["--mount", "#{host_path}:#{container_path}:#{mode}"]
      end)
  end
end
