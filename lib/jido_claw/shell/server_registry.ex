defmodule JidoClaw.Shell.ServerRegistry do
  @moduledoc """
  Source of truth for SSH server targets declared in
  `.jido/config.yaml` under the `servers:` key.

  A singleton GenServer independent of shell-session lifecycle. Owns
  the parsed server map and exposes lookup, reload, and config-assembly
  helpers. Unlike `ProfileManager`, there is no ETS mirror — server
  lookups are off the hot path (one lookup per SSH session bootstrap,
  cached thereafter in `SessionManager`).

  ## YAML shape

      servers:
        - name: "staging"
          host: "web01.example.com"
          user: "deploy"
          port: 22
          key_path: "~/.ssh/id_ed25519"
          password_env: "SSH_PROD_PW"
          cwd: "/srv/app"
          env:
            RAILS_ENV: "staging"
          shell: "bash"
          connect_timeout: 10000

  ## Validation (per-entry warn-and-skip)

    * `name`/`host`/`user` missing or empty → drop entry.
    * Both `key_path` and `password_env` set → drop entry (ambiguous).
    * Neither set → `auth_kind: :default` (rely on ssh-agent / default
      key discovery in the user's SSH config).
    * `port` out of range or non-integer → warn and default to 22.
    * Duplicate `name` → later entry wins, warning logged.
    * `env` non-map → drop the field; per-key integers are coerced,
      other non-string values are dropped with a warning.
    * `connect_timeout` → must be a positive integer; defaults to
      `10_000`.

  ## Passphrase-protected keys (v0.5.3 limitation)

  Passphrases are **not supported** in v0.5.3. If `key_path` points at
  an encrypted private key, the SSH handshake fails at decode time and
  the user sees a "connection failed" or "authentication rejected"
  error. Use your `ssh-agent` (leave both `key_path` and `password_env`
  unset) for encrypted keys until upstream jido_shell exposes a
  passphrase hook.

  ## PermitUserEnvironment caveat

  Many OpenSSH servers default `PermitUserEnvironment no`, which
  silently discards the SSH `setenv` channel request. The backend
  wraps every command as `cd <cwd> && env VAR=val <command>`, so env
  propagation works regardless of the server policy — but if a user
  tries to inspect the raw SSH env via `printenv` without the wrapper,
  nothing will be set.

  ## Test injection

  `build_ssh_config/3` consults
  `Application.get_env(:jido_claw, :ssh_test_modules, %{})` and merges
  `:ssh_module` / `:ssh_connection_module` into the config map when
  set. Production leaves the application env unset and the backend
  falls back to Erlang's `:ssh` / `:ssh_connection`. Tests set the key
  with `Application.put_env/3` and unset on teardown — this pattern
  mirrors how `ProfileManager` is tested.
  """

  use GenServer
  require Logger

  alias JidoClaw.Config

  defmodule ServerEntry do
    @moduledoc "Parsed, validated server entry for SSH routing."

    @enforce_keys [:name, :host, :user]
    defstruct [
      :name,
      :host,
      :user,
      :port,
      :auth_kind,
      :key_path,
      :password_env,
      :cwd,
      :env,
      :shell,
      :connect_timeout
    ]

    @type auth_kind :: :key_path | :password | :default
    @type t :: %__MODULE__{
            name: String.t(),
            host: String.t(),
            user: String.t(),
            port: pos_integer(),
            auth_kind: auth_kind(),
            key_path: String.t() | nil,
            password_env: String.t() | nil,
            cwd: String.t(),
            env: %{String.t() => String.t()},
            shell: String.t(),
            connect_timeout: pos_integer()
          }
  end

  defstruct [:project_dir, servers: %{}]

  @default_port 22
  @default_cwd "/"
  @default_shell "sh"
  @default_connect_timeout 10_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns declared server names, sorted alphabetically."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Fetch a parsed `ServerEntry` by name."
  @spec get(String.t()) :: {:ok, ServerEntry.t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc """
  Reload `servers:` from `.jido/config.yaml`. Returns a diff against
  the previous in-memory state so the caller can invalidate cached
  SSH sessions for affected names.

  Does *not* call into `SessionManager` from within the registry
  GenServer — doing so would deadlock, since
  `SessionManager.run/4` already calls `ServerRegistry.get/1` on the
  hot path. The caller (REPL command, hot-reload watcher) invokes
  `JidoClaw.Shell.SessionManager.invalidate_ssh_sessions/1` with
  `added ++ changed ++ removed` after this call returns.
  """
  @spec reload() ::
          {:ok, %{added: [String.t()], changed: [String.t()], removed: [String.t()]}}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Resolve a key path against the registry's `project_dir`:

    * absolute paths pass through;
    * `~`-prefixed paths expand against `$HOME`;
    * relative paths resolve against `project_dir`.
  """
  @spec resolve_key_path(String.t(), String.t()) :: String.t()
  def resolve_key_path(path, project_dir)
      when is_binary(path) and is_binary(project_dir) do
    cond do
      String.starts_with?(path, "/") ->
        path

      String.starts_with?(path, "~") ->
        Path.expand(path)

      true ->
        Path.expand(path, project_dir)
    end
  end

  @doc """
  Resolve secrets referenced by the server entry:

    * `auth_kind: :password` → read the `password_env` env var via
      `getenv/1`. Missing and empty (`""`) env vars both return
      `{:error, {:missing_env, var}}`.
    * `auth_kind: :key_path` / `:default` → no secrets to resolve.
  """
  @spec resolve_secrets(ServerEntry.t()) ::
          {:ok, %{optional(:password) => String.t()}}
          | {:error, {:missing_env, String.t()}}
  def resolve_secrets(%ServerEntry{auth_kind: :password, password_env: var}) do
    case getenv(var) do
      nil -> {:error, {:missing_env, var}}
      value -> {:ok, %{password: value}}
    end
  end

  def resolve_secrets(%ServerEntry{}), do: {:ok, %{}}

  @doc """
  Assemble the config map for `Jido.Shell.Backend.SSH.init/1`.

  Caller provides the resolved `project_dir` (used for relative key
  paths) and the *effective* env (already composed from the server's
  declared env and the workspace's active profile). Secrets are
  resolved here; missing env vars return `{:error, {:missing_env, var}}`
  so the caller can format a clean error via `SSHError.format/2`.

  Injects `:ssh_module` / `:ssh_connection_module` from
  `Application.get_env(:jido_claw, :ssh_test_modules, %{})` when
  present — production leaves the key unset.
  """
  @spec build_ssh_config(ServerEntry.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def build_ssh_config(%ServerEntry{} = entry, project_dir, effective_env)
      when is_binary(project_dir) and is_map(effective_env) do
    with {:ok, secrets} <- resolve_secrets(entry) do
      base = %{
        host: entry.host,
        port: entry.port,
        user: entry.user,
        cwd: entry.cwd,
        env: effective_env,
        shell: entry.shell,
        connect_timeout: entry.connect_timeout
      }

      auth =
        case entry.auth_kind do
          :key_path -> %{key_path: resolve_key_path(entry.key_path, project_dir)}
          :password -> %{password: Map.fetch!(secrets, :password)}
          :default -> %{}
        end

      config =
        base
        |> Map.merge(auth)
        |> Map.merge(test_module_overrides())

      {:ok, config}
    end
  end

  @doc false
  # Runtime test seam — swaps the in-memory server map without
  # touching disk. Consistent with `ProfileManager.replace_profiles_for_test/1`.
  @spec replace_servers_for_test(%{String.t() => ServerEntry.t()}) :: :ok
  def replace_servers_for_test(servers) when is_map(servers) do
    GenServer.call(__MODULE__, {:replace_servers_for_test, servers})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    state = %__MODULE__{project_dir: project_dir}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    servers = load_from_disk(state.project_dir)

    Logger.debug(
      "[ServerRegistry] Loaded #{map_size(servers)} servers from #{config_path(state.project_dir)}"
    )

    {:noreply, %{state | servers: servers}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.servers |> Map.keys() |> Enum.sort(), state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    reply =
      case Map.fetch(state.servers, name) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    new_servers = load_from_disk(state.project_dir)
    diff = diff_servers(state.servers, new_servers)

    Logger.info(
      "[ServerRegistry] Reloaded #{map_size(new_servers)} servers " <>
        "(added: #{length(diff.added)}, changed: #{length(diff.changed)}, removed: #{length(diff.removed)})"
    )

    {:reply, {:ok, diff}, %{state | servers: new_servers}}
  end

  @impl true
  def handle_call({:replace_servers_for_test, servers}, _from, state) do
    {:reply, :ok, %{state | servers: servers}}
  end

  # ---------------------------------------------------------------------------
  # Internals — loading & validation
  # ---------------------------------------------------------------------------

  defp config_path(project_dir), do: Path.join([project_dir, ".jido", "config.yaml"])

  defp load_from_disk(project_dir) do
    project_dir |> Config.load() |> Config.servers() |> parse_servers()
  end

  defp parse_servers(list) when is_list(list) do
    Enum.reduce(list, %{}, fn raw, acc ->
      case parse_entry(raw) do
        {:ok, entry} ->
          if Map.has_key?(acc, entry.name) do
            Logger.warning(
              "[ServerRegistry] Duplicate server name '#{entry.name}' — later entry wins"
            )
          end

          Map.put(acc, entry.name, entry)

        :skip ->
          acc
      end
    end)
  end

  defp parse_entry(raw) when is_map(raw) do
    with {:ok, name} <- fetch_required_string(raw, "name", "(missing)"),
         {:ok, host} <- fetch_required_string(raw, "host", name),
         {:ok, user} <- fetch_required_string(raw, "user", name),
         {:ok, auth_kind, key_path, password_env} <- parse_auth(raw, name) do
      {:ok,
       %ServerEntry{
         name: name,
         host: host,
         user: user,
         port: parse_port(raw, name),
         auth_kind: auth_kind,
         key_path: key_path,
         password_env: password_env,
         cwd: parse_string(raw, "cwd", @default_cwd),
         env: parse_env(raw, name),
         shell: parse_string(raw, "shell", @default_shell),
         connect_timeout: parse_connect_timeout(raw, name)
       }}
    else
      :skip -> :skip
    end
  end

  defp parse_entry(_other) do
    Logger.warning("[ServerRegistry] Skipping non-map server entry")
    :skip
  end

  defp fetch_required_string(raw, key, name_for_log) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            Logger.warning(
              "[ServerRegistry] Server '#{name_for_log}' has empty '#{key}' — skipping entry"
            )

            :skip

          trimmed ->
            {:ok, trimmed}
        end

      _ ->
        Logger.warning(
          "[ServerRegistry] Server '#{name_for_log}' missing required '#{key}' — skipping entry"
        )

        :skip
    end
  end

  defp parse_auth(raw, name) do
    key_path = string_or_nil(Map.get(raw, "key_path"))
    password_env = string_or_nil(Map.get(raw, "password_env"))

    case {key_path, password_env} do
      {nil, nil} ->
        {:ok, :default, nil, nil}

      {kp, nil} when is_binary(kp) ->
        {:ok, :key_path, kp, nil}

      {nil, pe} when is_binary(pe) ->
        {:ok, :password, nil, pe}

      {_, _} ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' has both key_path and password_env — skipping entry"
        )

        :skip
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(_), do: nil

  defp parse_port(raw, name) do
    case Map.get(raw, "port") do
      nil ->
        @default_port

      value when is_integer(value) and value >= 1 and value <= 65_535 ->
        value

      other ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' has invalid port #{inspect(other)} — defaulting to 22"
        )

        @default_port
    end
  end

  defp parse_string(raw, key, default) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp parse_env(raw, name) do
    case Map.get(raw, "env") do
      nil ->
        %{}

      map when is_map(map) ->
        Enum.reduce(map, %{}, fn {k, v}, acc -> coerce_env_entry(acc, name, k, v) end)

      other ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' env is not a map (got: #{type_hint(other)}) — ignoring"
        )

        %{}
    end
  end

  defp coerce_env_entry(acc, name, key, value) do
    cond do
      not is_binary(key) ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' has non-string env key (got: #{type_hint(key)}) — skipping entry"
        )

        acc

      is_binary(value) ->
        Map.put(acc, key, value)

      is_integer(value) ->
        Map.put(acc, key, Integer.to_string(value))

      true ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' env.#{key} is #{type_hint(value)} — skipping entry"
        )

        acc
    end
  end

  defp parse_connect_timeout(raw, name) do
    case Map.get(raw, "connect_timeout") do
      nil ->
        @default_connect_timeout

      value when is_integer(value) and value > 0 ->
        value

      other ->
        Logger.warning(
          "[ServerRegistry] Server '#{name}' has invalid connect_timeout #{inspect(other)} — defaulting to #{@default_connect_timeout}"
        )

        @default_connect_timeout
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — diff + secrets + test injection
  # ---------------------------------------------------------------------------

  defp diff_servers(old, new) do
    old_names = MapSet.new(Map.keys(old))
    new_names = MapSet.new(Map.keys(new))

    added = MapSet.difference(new_names, old_names) |> Enum.sort()
    removed = MapSet.difference(old_names, new_names) |> Enum.sort()

    changed =
      new_names
      |> MapSet.intersection(old_names)
      |> Enum.filter(fn name -> Map.get(old, name) != Map.get(new, name) end)
      |> Enum.sort()

    %{added: added, changed: changed, removed: removed}
  end

  defp getenv(var) when is_binary(var) do
    case System.get_env(var) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp test_module_overrides do
    Application.get_env(:jido_claw, :ssh_test_modules, %{})
    |> Map.take([:ssh_module, :ssh_connection_module])
  end

  defp type_hint(value) when is_binary(value), do: "string"
  defp type_hint(value) when is_integer(value), do: "integer"
  defp type_hint(value) when is_float(value), do: "float"
  defp type_hint(value) when is_boolean(value), do: "boolean"
  defp type_hint(nil), do: "nil"
  defp type_hint(value) when is_atom(value), do: "atom"
  defp type_hint(value) when is_list(value), do: "list/#{length(value)}"
  defp type_hint(value) when is_map(value), do: "map/#{map_size(value)}"
  defp type_hint(value) when is_tuple(value), do: "tuple/#{tuple_size(value)}"
  defp type_hint(_), do: "term"
end
