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

  defstruct [:sandbox_name, :workspace_dir, :sandbox_id, :workdir]

  @type t :: %__MODULE__{
          sandbox_name: String.t(),
          workspace_dir: String.t(),
          sandbox_id: String.t(),
          # AR-8b-2 F2 (1.6): the in-container working directory `exec` forces via
          # `sbx exec --workdir <dir>` — stamped from `sandbox_spec.workdir` at
          # create, read at exec. `nil` (every non-exec session) emits no flag, so
          # exec defaults to the throwaway `/tmp` workspace as before.
          workdir: String.t() | nil
        }

  @impl JidoClaw.Forge.Sandbox.Behaviour
  @spec create(map()) ::
          {:error,
           :sbx_not_found
           | {:sbx_create_failed, pos_integer(), any()}
           | {:sbx_policy_failed, String.t(), pos_integer(), any()}
           | {:workspace_dir_failed, term()}
           | {:invalid_mount, term()}
           | {:invalid_allow_network, term()}
           | {:contradictory_network_policy, term()}}
          | {:ok, t(), binary()}
  def create(spec) do
    # Spec validation runs FIRST — before the sbx lookup and before any
    # resource (workspace dir) exists, so an invalid mount/policy spec fails
    # as a deterministic error tuple with nothing to clean up.
    with :ok <- validate_create_spec(spec) do
      case System.find_executable("sbx") do
        nil ->
          {:error, :sbx_not_found}

        _path ->
          do_create(spec)
      end
    end
  end

  # Pure pre-create validation: every mount source the create will emit
  # (spec mounts + the global layer, honoring the opt-out) must be a valid
  # same-path workspace positional, and the network intent must be coherent
  # (`network: :none` contradicts a non-empty `allow_network`; no producer
  # needs both). `allow_network` entries are shape-checked here because they
  # become a `sbx policy` CSV — a stray comma/blank/wildcard would silently
  # broaden egress.
  defp validate_create_spec(spec) do
    with :ok <- validate_network_intent(spec) do
      spec
      |> collect_mounts()
      |> Enum.find(&(not valid_mount_entry?(&1)))
      |> case do
        nil -> :ok
        entry -> {:error, {:invalid_mount, entry}}
      end
    end
  end

  defp validate_network_intent(spec) do
    # ToolContext present-nil coercion: a present-nil key must read as absent.
    hosts = Map.get(spec, :allow_network) || []

    cond do
      not (is_list(hosts) and Enum.all?(hosts, &valid_network_host?/1)) ->
        {:error, {:invalid_allow_network, Map.get(spec, :allow_network)}}

      Map.get(spec, :network) == :none and hosts != [] ->
        {:error, {:contradictory_network_policy, hosts}}

      true ->
        :ok
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
          sandbox_id: sandbox_id,
          workdir: Map.get(spec, :workdir)
        }

        finalize_created_sandbox(spec, client, sandbox_id, sandbox_name)

      {error_output, code} ->
        File.rm_rf(workspace_dir)
        {:error, {:sbx_create_failed, code, error_output}}
    end
  end

  # Network policy lands POST-create (sbx 0.34.0 moved network control off
  # `create` onto `sbx policy`). A policy call that fails means the isolation
  # (or reachability) the spec requested cannot be honored — the sandbox is
  # destroyed and the create fails CLOSED, never a silent fail-open run.
  defp finalize_created_sandbox(spec, client, sandbox_id, sandbox_name) do
    case apply_network_policy(spec, sandbox_name) do
      :ok ->
        maybe_inject_onecli_env(spec, client, sandbox_id, sandbox_name)
        {:ok, client, sandbox_id}

      {:error, reason} ->
        destroy(client, sandbox_id)
        {:error, reason}
    end
  end

  # `network: :none` ⇒ a per-sandbox deny-all rule; `allow_network` ⇒ a
  # per-sandbox allow rule (the deposit-endpoint reachability grant). The two
  # are mutually exclusive by `validate_create_spec/1`; deny wins here as
  # defense in depth. Per-sandbox rules are removed by `sbx rm` (verified),
  # so destroy needs no policy cleanup.
  defp apply_network_policy(spec, sandbox_name) do
    case {Map.get(spec, :network), Map.get(spec, :allow_network) || []} do
      {:none, _hosts} -> run_policy_rule("deny", sandbox_name, "**")
      {_network, [_ | _] = hosts} -> run_policy_rule("allow", sandbox_name, Enum.join(hosts, ","))
      _no_policy -> :ok
    end
  end

  defp run_policy_rule(decision, sandbox_name, resources) do
    args = build_policy_args(decision, sandbox_name, resources)

    case System.cmd("sbx", args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env()) do
      {_output, 0} -> :ok
      {error_output, code} -> {:error, {:sbx_policy_failed, decision, code, error_output}}
    end
  end

  @doc """
  The POST-CREATE half of the AR-8b-2 F2 (D2-a) global-config opt-out:
  `build_create_args/4` skips the CA-cert mount + global `:extra_mounts`, and
  THIS separate call site skips the OneCLI proxy env injection under
  `isolate_global_config: true` (a create-arg assertion alone can't catch it).
  Public so a test can drive the skip at the real call site without a live `sbx`.
  """
  @spec maybe_inject_onecli_env(map(), t(), String.t(), String.t()) :: :ok
  def maybe_inject_onecli_env(spec, client, _sandbox_id, sandbox_name) do
    if isolate_global_config?(spec) do
      :ok
    else
      inject_onecli_env(client, sandbox_name)
      :ok
    end
  end

  # Inject OneCLI proxy env if configured. Trusted config, pre-bootstrap —
  # a failure degrades proxying but must not fail sandbox creation.
  defp inject_onecli_env(client, sandbox_name) do
    env = onecli_env()

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
  def exec(
        %__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir, workdir: workdir},
        command,
        opts
      ) do
    args = build_exec_args(sandbox_name, workspace_dir, command, workdir)
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
    sbx_args = build_exec_argv(sandbox_name, workspace_dir, nil, [command | args])
    timeout = Keyword.get(opts, :timeout)

    exec_with_timeout(sbx_args, timeout || :infinity)
  end

  # sbx 0.34.0: a vendor CLI run is `sbx exec` into the harness-created
  # sandbox — arg#2 is the in-sandbox EXECUTABLE (`HostShell.run` semantics;
  # the old `sbx run <agent>` dispatch is gone), and `opts[:name]` no longer
  # re-targets another sandbox (exec targets THIS client's sandbox). The
  # in-VM `</dev/null` wrap in `build_exec_argv/4` is load-bearing here: the
  # sbx client forwards its piped stdin, so a stdin-reading CLI would hang to
  # timeout without it.
  @impl JidoClaw.Forge.Sandbox.Behaviour
  def run(
        %__MODULE__{sandbox_name: sandbox_name, workspace_dir: workspace_dir, workdir: workdir},
        executable,
        args,
        opts
      ) do
    sbx_args = build_exec_argv(sandbox_name, workspace_dir, workdir, [executable | args])
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
         :ok <- ensure_safe_parent(workspace_dir, Path.dirname(full_path)),
         :ok <- validate_regular_or_missing(full_path) do
      atomic_workspace_write(workspace_dir, full_path, content)
    end
  end

  @impl JidoClaw.Forge.Sandbox.Behaviour
  def read_file(%__MODULE__{workspace_dir: workspace_dir}, path) do
    with {:ok, full_path} <- resolve_path(workspace_dir, path),
         :ok <- validate_path_components(workspace_dir, full_path),
         :ok <- validate_regular_file(full_path) do
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

  @doc """
  Build the `sbx create` args (sbx 0.34.0): `create --name NAME AGENT WORKSPACE
  [MOUNT...]` — every mount is a trailing workspace POSITIONAL (`path` rw /
  `path:ro`; the CLI has no `--mount`), mounted in-VM at the SAME absolute path
  as the host, so every entry must be same-path + absolute. Order matters: sbx
  treats the first PATH as the primary workspace, so mounts come AFTER
  `[agent_type, workspace_dir]`. Network control moved to post-create
  `sbx policy` — no `--network` flag exists here.

  Public so a test can assert the emitted positionals — global mounts skipped
  under `isolate_global_config: true` (AR-8b-2 F2 D2-a: a host-path mount
  survives the deny-all policy, so the no-egress bypass cannot rest on egress
  alone) — without a live `sbx`. Raises on an invalid mount entry as defense
  in depth; `create/1` validates the same entries up front and returns
  `{:error, {:invalid_mount, entry}}` instead.
  """
  @spec build_create_args(String.t(), String.t(), String.t(), map()) :: [String.t()]
  def build_create_args(sandbox_name, agent_type, workspace_dir, spec) do
    mounts =
      spec
      |> collect_mounts()
      |> Enum.map(&mount_positional!/1)

    ["create", "--name", sandbox_name, agent_type, workspace_dir] ++ mounts
  end

  # Every mount source the create emits, in layer order: the OneCLI CA-cert
  # dir + operator-global `:extra_mounts` (skipped wholesale under the global
  # opt-out), then the spec-declared mounts (the prototype / executor repo
  # mount) — always.
  defp collect_mounts(spec) do
    global =
      if isolate_global_config?(spec) do
        []
      else
        ca_cert_mounts() ++ Keyword.get(config(), :extra_mounts, [])
      end

    global ++ Map.get(spec, :extra_mounts, [])
  end

  defp mount_positional!(entry) do
    if valid_mount_entry?(entry) do
      {path, _same_path, mode} = entry
      if normalize_mount_mode(mode) == "ro", do: "#{path}:ro", else: path
    else
      raise ArgumentError,
            "[Forge.DockerSandbox] invalid mount #{inspect(entry)} — sbx 0.34.0 " <>
              "workspaces mount in-VM at the host path, so an entry must be a " <>
              "{path, path, ro|rw} same-path tuple with an absolute path"
    end
  end

  defp valid_mount_entry?({host, container, mode})
       when is_binary(host) and is_binary(container),
       do:
         host == container and Path.type(host) == :absolute and
           normalize_mount_mode(mode) in ["ro", "rw"]

  defp valid_mount_entry?(_entry), do: false

  defp normalize_mount_mode(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp normalize_mount_mode(mode) when is_binary(mode), do: mode
  defp normalize_mount_mode(mode), do: inspect(mode)

  @doc """
  Build the `sbx policy <decision> network --sandbox NAME RESOURCES` args —
  the post-create half of 0.34.0 network control (`network: :none` ⇒ a
  per-sandbox `deny … "**"`, `allow_network` ⇒ a per-sandbox allow CSV).
  Public so precommit can assert the emitted shape without a live `sbx`.
  """
  @spec build_policy_args(String.t(), String.t(), String.t()) :: [String.t()]
  def build_policy_args(decision, sandbox_name, resources)
      when decision in ["allow", "deny"] do
    ["policy", decision, "network", "--sandbox", sandbox_name, resources]
  end

  @doc """
  Whether `value` is a strict `host[:port]` entry safe to join into a
  `sbx policy` RESOURCES CSV: non-blank, no commas/whitespace/wildcards
  (a stray comma or `**` would silently broaden egress; nothing in this
  build needs a wildcard). Shared with `Forge.RecoveredSpec`, which applies
  the same rule to a jsonb-recovered `allow_network`.
  """
  @spec valid_network_host?(term()) :: boolean()
  def valid_network_host?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Za-z0-9._-]+(:\d{1,5})?$/, value)

  def valid_network_host?(_other), do: false

  @doc """
  Whether the spec opts out of all global host config (AR-8b-2 F2 D2-a). Reads
  the atom key only: the create/recovery/sync specs reaching the backend are
  atom-keyed by construction (`Forge.RecoveredSpec` re-atomizes a jsonb-recovered
  spec before it reaches the Harness). Public for the predicate unit test.
  """
  @spec isolate_global_config?(map()) :: boolean()
  def isolate_global_config?(%{isolate_global_config: true}), do: true
  def isolate_global_config?(_spec), do: false

  @doc """
  Build the `sbx exec` args for a `sh -c` command (AR-8b-2 F2 1.6). Public so
  a test can assert the `--workdir <dir>` flag is emitted for an exec session.
  A `nil`/blank workdir (every non-exec session) emits no flag — byte-identical
  to the pre-F2 args.
  """
  @spec build_exec_args(String.t(), String.t(), String.t(), String.t() | nil) :: [String.t()]
  def build_exec_args(sandbox_name, workspace_dir, command, workdir \\ nil) do
    build_exec_argv(sandbox_name, workspace_dir, workdir, ["sh", "-c", command])
  end

  @doc """
  The shared `sbx exec` argv assembly every in-sandbox invocation rides
  (`exec/3`, `exec_argv/4`, `run/4` — 0.34.0 has no separate agent-dispatch
  path here; a vendor CLI is just an in-sandbox executable): `--workdir` when
  a workdir is stamped, then `[SANDBOX, sh, -c, <wrapper> | argv]`, where the
  in-VM wrapper applies the workspace `.forge_env` (when it exists) and
  `exec`s the real argv with STDIN FROM /dev/null.

  Both wrapper halves are live-smoke findings, not style:

    * `sbx exec --env-file` is INERT on 0.34.0 (probed: the file's vars never
      reach the exec'd process, while `-e` does) — and `-e K=V` would put
      resolved vault secrets on the HOST argv (ps-visible). The env file is
      applied IN-VM instead: the workspace dir is the sandbox's primary
      same-path mount, so the file is readable at its host path inside the
      VM, and the reader assigns each `K=V` line WITHOUT shell evaluation
      (`export "$line"` expands once and never re-scans the value — a value
      containing `$(...)` stays literal; sourcing would execute it).
    * stdin-EOF does NOT come free: the `sbx` client forwards its own piped
      stdin (OsCmd's port — never EOF) into the exec, so a stdin-reading
      command hangs to timeout without the redirect (`codex exec` reads
      stdin to EOF — the HostShell `cli_exec_argv/2` finding, replayed
      in-VM). `"$0" "$@"` keeps the argv out of the shell string entirely.

  Public so precommit can assert the emitted shape without a live `sbx`.
  """
  @spec build_exec_argv(String.t(), String.t(), String.t() | nil, [String.t()]) :: [String.t()]
  def build_exec_argv(sandbox_name, workspace_dir, workdir, argv) do
    env_file = env_file_path(workspace_dir)
    prelude = if File.exists?(env_file), do: env_prelude(env_file), else: ""
    wrapper = prelude <> ~S(exec "$0" "$@" </dev/null)

    ["exec"] ++ workdir_args(workdir) ++ [sandbox_name, "sh", "-c", wrapper | argv]
  end

  defp env_prelude(env_file) do
    ~s{while IFS= read -r __fl; do case "$__fl" in *=*) export "$__fl";; esac; done } <>
      "< '#{env_file}'; "
  end

  defp workdir_args(workdir) when is_binary(workdir) and workdir != "", do: ["--workdir", workdir]
  defp workdir_args(_workdir), do: []

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

  # Host-side file helpers operate on a directory the guest can mutate. A
  # lexical `safe_relative` check is not enough: walk every observed component
  # with lstat and refuse links; create missing parent directories one component
  # at a time under the same rule. This closes planted/static symlinks. The final
  # read/rename remains pathname-based, so a concurrently-running guest can race
  # the check; docs/system/executor-seam.md records that currently-dormant
  # openat2/O_NOFOLLOW residual explicitly.
  defp ensure_safe_parent(workspace_dir, parent) do
    with :ok <- validate_workspace_root(workspace_dir),
         {:ok, relative} <- relative_within(parent, workspace_dir) do
      relative
      |> Path.split()
      |> Enum.reduce_while({:ok, workspace_dir}, fn component, {:ok, current} ->
        next = Path.join(current, component)

        case File.lstat(next) do
          {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next}}
          {:ok, %File.Stat{type: type}} -> {:halt, {:error, {:unsafe_path_type, next, type}}}
          {:error, :enoent} -> create_safe_directory(next)
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _parent} -> :ok
        error -> error
      end
    end
  end

  defp create_safe_directory(path) do
    case File.mkdir(path) do
      :ok -> {:cont, {:ok, path}}
      {:error, :eexist} -> {:halt, {:error, {:unsafe_path_race, path}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_path_components(workspace_dir, full_path) do
    with :ok <- validate_workspace_root(workspace_dir),
         {:ok, relative} <- relative_within(full_path, workspace_dir) do
      relative
      |> Path.split()
      |> Enum.reduce_while({:ok, workspace_dir}, fn component, {:ok, current} ->
        next = Path.join(current, component)

        case File.lstat(next) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, {:unsafe_symlink, next}}}

          {:ok, _stat} ->
            {:cont, {:ok, next}}

          {:error, :enoent} ->
            {:halt, {:ok, next}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _path} -> :ok
        error -> error
      end
    end
  end

  defp relative_within(path, workspace_dir) do
    relative = Path.relative_to(path, workspace_dir)

    if relative == ".." or String.starts_with?(relative, "../") do
      {:error, {:unsafe_path, path}}
    else
      {:ok, relative}
    end
  end

  defp validate_workspace_root(workspace_dir) do
    case File.lstat(workspace_dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_workspace, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two semantic wrappers over one lstat check (never a boolean-blind
  # argument at the call sites): write targets may be absent, read targets
  # must exist.
  defp validate_regular_or_missing(path), do: validate_regular(path, :allow_missing)

  defp validate_regular_file(path), do: validate_regular(path, :required)

  defp validate_regular(path, missing_mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:unsafe_symlink, path}}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_path_type, path, type}}
      {:error, :enoent} -> missing_result(missing_mode)
      {:error, reason} -> {:error, reason}
    end
  end

  defp missing_result(:allow_missing), do: :ok
  defp missing_result(:required), do: {:error, :enoent}

  defp atomic_workspace_write(workspace_dir, path, content) do
    tmp = "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    try do
      with :ok <- File.write(tmp, content, [:exclusive]),
           :ok <- validate_path_components(workspace_dir, Path.dirname(path)),
           :ok <- validate_regular_or_missing(path) do
        File.rename(tmp, path)
      end
    after
      File.rm(tmp)
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

  defp onecli_env do
    config = onecli_config()

    if Keyword.get(config, :enabled, false) do
      gateway_url = Keyword.get(config, :gateway_url)
      token = resolve_agent_token(config)

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

      # CA cert env vars, when configured — pointing at the HOST path, which
      # is in-VM identical (same-path workspace mount of the cert's parent
      # dir). Trust flows through these env consumers only: sbx 0.34.0 cannot
      # remap the cert under /usr/local/share/ca-certificates, so
      # `update-ca-certificates` never sees it.
      case Keyword.get(config, :ca_cert_path) do
        nil ->
          env

        ca_path ->
          env
          |> Map.put("NODE_EXTRA_CA_CERTS", ca_path)
          |> Map.put("SSL_CERT_FILE", ca_path)
      end
    else
      %{}
    end
  end

  defp resolve_agent_token(config) do
    case Keyword.get(config, :agent_tokens, []) do
      [] -> nil
      tokens -> Enum.random(tokens)
    end
  end

  # The OneCLI CA cert as a mount source: sbx 0.34.0 rejects FILE workspace
  # positionals (probe-verified: "workspace path exists but is not a
  # directory"), so the cert's parent DIRECTORY mounts same-path read-only
  # and the env consumers (`NODE_EXTRA_CA_CERTS`/`SSL_CERT_FILE` in
  # `onecli_env/0`) point at the original cert path.
  defp ca_cert_mounts do
    config = onecli_config()

    if Keyword.get(config, :enabled, false) do
      case Keyword.get(config, :ca_cert_path) do
        nil ->
          []

        ca_path when is_binary(ca_path) ->
          if File.exists?(ca_path) do
            dir = Path.dirname(ca_path)
            [{dir, dir, "ro"}]
          else
            Logger.warning("[Forge.DockerSandbox] OneCLI CA cert not found at #{ca_path}")
            []
          end
      end
    else
      []
    end
  end
end
