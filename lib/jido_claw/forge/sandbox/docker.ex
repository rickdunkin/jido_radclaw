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
  alias JidoClaw.Forge.Sandbox
  alias JidoClaw.Security.Redaction.Env

  defstruct [:sandbox_name, :workspace_dir, :sandbox_id]

  @type t :: %__MODULE__{
          sandbox_name: String.t(),
          workspace_dir: String.t(),
          sandbox_id: String.t()
        }

  @impl JidoClaw.Forge.Sandbox.Behaviour
  @spec create(map()) ::
          {:error,
           :sbx_not_found
           | {:sbx_create_failed, pos_integer(), any()}
           | {:workspace_dir_failed, term()}}
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

    case ensure_workspace_dir(workspace_base(), sandbox_name) do
      {:ok, workspace_dir} ->
        create_sandbox(spec, sandbox_id, sandbox_name, workspace_dir)

      {:error, reason} ->
        {:error, {:workspace_dir_failed, reason}}
    end
  end

  defp create_sandbox(spec, sandbox_id, sandbox_name, workspace_dir) do
    agent_type = sandbox_agent_type(spec)
    args = build_create_args(sandbox_name, agent_type, workspace_dir, spec)

    case System.cmd("sbx", args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
      {_output, 0} ->
        client = %__MODULE__{
          sandbox_name: sandbox_name,
          workspace_dir: workspace_dir,
          sandbox_id: sandbox_id
        }

        inject_onecli_env(client, sandbox_id, sandbox_name)

        {:ok, client, sandbox_id}

      {error_output, code} ->
        File.rm_rf(workspace_dir)
        {:error, {:sbx_create_failed, code, error_output}}
    end
  end

  # Inject OneCLI proxy env if configured. Trusted config, pre-bootstrap —
  # a failure degrades proxying but must not fail sandbox creation.
  defp inject_onecli_env(client, sandbox_id, sandbox_name) do
    env = onecli_env(sandbox_id)

    if map_size(env) > 0 do
      case inject_env(client, env) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Forge.DockerSandbox] OneCLI env injection failed for #{sandbox_name}: " <>
              inspect(reason)
          )
      end
    end
  end

  # The base lives under /tmp and sandbox names are guessable
  # (sequential unique_integer), so a pre-existing entry at the
  # workspace path — including a planted symlink — is rejected rather
  # than reused, and a symlinked base is rejected before mkdir/chmod
  # can follow it. Public for tests: create/1 short-circuits when the
  # sbx CLI is absent, so this is not reachable through the public API
  # in CI.
  @doc false
  @spec ensure_workspace_dir(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_workspace_dir(base, sandbox_name) do
    path = Path.join(base, sandbox_name)

    with :ok <- File.mkdir_p(base),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(base),
         :ok <- File.mkdir(path) do
      chmod_workspace_dir(path)
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_workspace_base, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_workspace_dir(path) do
    case File.chmod(path, 0o700) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        # Never hand out a workspace dir we could not protect.
        File.rm_rf(path)
        {:error, {:chmod_failed, reason}}
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def exec(%__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir}, command, opts) do
    args = build_exec_args(sandbox_name, workspace_dir, command)
    timeout = Keyword.get(opts, :timeout)

    # No-timeout calls go through exec_with_timeout too (OsCmd accepts
    # :infinity): they get the output cap, the tree-kill, and the
    # missing-sbx guard — the raw System.cmd here *raised* :enoent.
    exec_with_timeout(args, timeout || :infinity)
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

    exec_with_timeout(sbx_args, timeout || :infinity)
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

    exec_with_timeout(sbx_args, timeout || :infinity)
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

  # `.forge_env` carries resolved vault secrets onto host disk, so it gets
  # the same treatment as `.env` (see CLI.Setup.persist_env_var/3): mode
  # 0600 before any content lands, atomic tmp+rename writes, and a
  # symlink at the path is rejected rather than followed. The merged map
  # (legacy file content included) is validated before writing — the
  # format has no escape syntax, so a key/value that cannot round-trip
  # through `K=V\n` lines is rejected outright, never encoded.
  @impl JidoClaw.Forge.Sandbox.Behaviour
  def inject_env(%__MODULE__{workspace_dir: workspace_dir}, env) do
    env_file = env_file_path(workspace_dir)
    incoming = Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)

    with {:ok, existing} <- read_existing_env(env_file),
         merged = Map.merge(existing, incoming),
         :ok <- validate_env(merged) do
      secure_write(env_file, render_env(merged))
    end
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
    case sbx_finder().("sbx") do
      nil ->
        {"sbx: command not found", 127}

      sbx ->
        # On timeout (or output cap) OsCmd kills the host-side `sbx`
        # client tree — that is the fix here; the in-container command
        # keeps running until the sandbox is destroyed. The microVM
        # contains the blast radius, but a timed-out command still
        # running inside a long-lived sandbox can consume its CPU/memory
        # and affect later commands in that same sandbox. Accepted for
        # now; revisit if sbx grows a remote-cancel API.
        case OsCmd.run(sbx, args, env: Env.scrubbed_cmd_env(), timeout: timeout) do
          {_partial, :timeout} ->
            {"timeout after #{timeout}ms", 124}

          {partial, :output_limit} ->
            {"output limit exceeded after #{byte_size(partial)} bytes",
             Sandbox.output_limit_exit_status()}

          result ->
            result
        end
    end
  end

  # Injectable finder so tests can force the missing-sbx branch
  # deterministically on machines that have sbx installed (the app-env
  # seam idiom, cf. :task_supervisor). Anything but a 1-arity fun falls
  # back to the real finder — bad config must not crash the exec path.
  defp sbx_finder do
    case Application.get_env(:jido_claw, :sbx_finder) do
      fun when is_function(fun, 1) -> fun
      _absent_or_invalid -> &System.find_executable/1
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

  # lstat (not read) first: a symlink (or anything else non-regular)
  # sitting at .forge_env must never be followed — for the read here or
  # the write later. A legacy regular file is tightened to 0600 before
  # it is read; chmod or read failure is fatal rather than "no existing
  # env", because merging past either would mean carrying forward (or
  # silently dropping) content we could not protect or see.
  defp read_existing_env(env_file) do
    case File.lstat(env_file) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- File.chmod(env_file, 0o600),
             {:ok, content} <- File.read(env_file) do
          {:ok, parse_env_file(content)}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_env_file, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Verbatim parse — split on the first `=` only, no trimming. Trimming
  # would hide exactly what validate_env/1 must catch in legacy content
  # (a padded key like " BAD"), and would silently mutate padded values
  # on round-trip.
  defp parse_env_file(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  # Byte lists (not regex) so validation also holds for non-UTF-8 legacy
  # file content. Whitespace edges are legal value content and round-trip
  # faithfully; line breaks and NUL cannot be represented in the format.
  @env_key_forbidden ["=", <<0>>, " ", "\t", "\n", "\r", "\v", "\f"]
  @env_value_forbidden ["\n", "\r", <<0>>]

  defp validate_env(env) do
    Enum.find_value(env, :ok, fn {key, value} ->
      if valid_env_key?(key) and valid_env_value?(value) do
        nil
      else
        {:error, {:invalid_env, key}}
      end
    end)
  end

  defp valid_env_key?(key) do
    key != "" and not String.contains?(key, @env_key_forbidden)
  end

  defp valid_env_value?(value) do
    not String.contains?(value, @env_value_forbidden)
  end

  defp render_env(env) do
    Enum.map_join(env, "\n", fn {k, v} -> "#{k}=#{v}" end) <> "\n"
  end

  # Atomic secret write (the H7 pattern from CLI.Setup.persist_env_var/3,
  # adapted to error tuples — Sandbox.Behaviour callers expect
  # :ok | {:error, term()} and a Harness GenServer must not crash): the
  # tmp file is 0600 before any content lands in it, and rename preserves
  # the mode, so the secrets are never world-readable, even transiently.
  defp secure_write(path, content) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.touch(tmp),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.write(tmp, content) do
        File.rename(tmp, path)
      end
    after
      # On any failure the secret-bearing tmp must not outlive the call;
      # after a successful rename this is :enoent.
      File.rm(tmp)
    end
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
