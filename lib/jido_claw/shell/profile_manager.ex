defmodule JidoClaw.Shell.ProfileManager do
  @moduledoc """
  Source of truth for named environment-variable profiles (dev, staging,
  prod, …) declared in `.jido/config.yaml` under the `profiles:` key.

  A singleton GenServer independent of shell-session lifecycle. Owns:

    * `profiles` — `%{name => env_map}` loaded from config
    * `default_env` — `profiles["default"]` or `%{}` when absent; serves
      as the baseline every profile inherits from
    * `active_by_workspace` — `%{workspace_id => profile_name}`, updated
      by `switch/2` after live-session env updates succeed (or
      immediately when no live sessions exist)

  The magic name `"default"` within `profiles:` is always first-class:
  `list/0` pins it first, `switch/2` always accepts it, and
  `active_env/1` falls back to it when no profile is active. There is
  no separate `active_profile:` config key.

  ## YAML shape

      profiles:
        default:
          FOO: "base-value"
        staging:
          FOO: "staging-value"
          AWS_PROFILE: "staging"

  Values are coerced to strings (integers tolerated); other non-string
  values are rejected per-key with a warn-and-skip. Non-string keys are
  rejected.

  ## Switch semantics

  A profile switch *preserves* ad-hoc `env VAR=value` mutations the user
  made in the shell. The transformation from profile A to B drops keys
  A owned that B doesn't, adds keys B owns that A didn't, upserts
  shared keys, and leaves ad-hoc-only keys untouched. See
  `SessionManager.update_env/3` for the implementation.

  ## Signals

  On every successful `switch/2` (including auto-transitions from
  `reload/0`), emits `jido_claw.shell.profile_switched` with
  `%{workspace_id, from, to, key_count, reason}`. Redundant switches
  (same profile name) short-circuit and do *not* emit a signal.
  """

  use GenServer
  require Logger

  alias JidoClaw.Config
  alias JidoClaw.Shell.SessionManager

  defstruct [
    :project_dir,
    profiles: %{},
    default_env: %{},
    active_by_workspace: %{},
    ets_mirror?: false
  ]

  @magic_default "default"

  # Name of the ETS table ProfileManager owns as a read-only mirror of
  # `active_by_workspace` overlays and the sentinel default. The table
  # is opt-in via `ets_mirror: true` in init opts (the supervised
  # singleton passes it; unregistered test instances don't, so they
  # skip creation and avoid colliding on the `:named_table` name).
  @ets_active_env :profile_active_env

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all profile names available for switching. `"default"` is
  always pinned first (even when absent from YAML — it's first-class),
  and the remainder are sorted alphabetically.
  """
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Fetch the raw env map for a named profile.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc """
  Returns the active profile name for `workspace_id`. Falls back to
  `"default"` when no switch has happened.

  Reads the ETS mirror when available so callers inside a
  `SessionManager`-blocked context (e.g., `jido status` running
  through `ShellSessionServer` while `SessionManager.handle_call({:run, ...})`
  is still in `collect_output/2`) cannot form a PM↔SM cycle with a
  concurrent `/profile switch`. Falls back to `GenServer.call/2` when
  the mirror is absent — e.g. isolated unit tests with a PM started
  without `ets_mirror: true`.
  """
  @spec current(String.t()) :: String.t()
  def current(workspace_id) when is_binary(workspace_id) do
    case :ets.whereis(@ets_active_env) do
      :undefined ->
        current_via_call(workspace_id)

      _ref ->
        case :ets.lookup(@ets_active_env, workspace_id) do
          [{^workspace_id, name, _overlay}] ->
            name

          [] ->
            case :ets.lookup(@ets_active_env, :__default__) do
              [{:__default__, name, _env}] -> name
              [] -> @magic_default
            end
        end
    end
  end

  defp current_via_call(workspace_id) do
    case Process.whereis(__MODULE__) do
      nil -> @magic_default
      _pid -> GenServer.call(__MODULE__, {:current, workspace_id})
    end
  catch
    :exit, _ -> @magic_default
  end

  @doc """
  Switch the active profile for `workspace_id`. Applies env changes to
  any live shell sessions (via `SessionManager.update_env/3`) and only
  updates the active-by-workspace map on success.

  Validation:

    * `"default"` is always accepted (even without a YAML entry —
      resolves to empty `default_env`).
    * Any other name must exist in `profiles` → `{:error, :unknown_profile}`.

  Short-circuit: if the target name equals the current active name,
  returns `{:ok, name}` without rewriting env or emitting a signal.
  """
  @spec switch(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :unknown_profile | term()}
  def switch(workspace_id, name)
      when is_binary(workspace_id) and is_binary(name) do
    GenServer.call(__MODULE__, {:switch, workspace_id, name, "user_switch"})
  end

  @doc """
  Merged env for `workspace_id`: `default_env` overlaid by the currently
  active profile's overrides. Returns `%{}` when neither exists.

  Tolerates the manager not being running (e.g. isolated unit tests
  that start `SessionManager` standalone) by returning `%{}`.
  """
  @spec active_env(String.t()) :: map()
  def active_env(workspace_id) when is_binary(workspace_id) do
    case Process.whereis(__MODULE__) do
      nil -> %{}
      _pid -> GenServer.call(__MODULE__, {:active_env, workspace_id})
    end
  catch
    :exit, _ -> %{}
  end

  @doc """
  Reload profiles from `.jido/config.yaml`. Computes transitions
  against the old in-memory state, then replaces it. Workspaces whose
  active profile was removed fall back to `"default"` with a
  `reason: "profile_removed"` signal and a warning log. Per-workspace
  best-effort: if one workspace's transition fails, others still
  complete.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc false
  # Test seam — replaces in-memory `profiles` and derives `default_env`
  # from `profiles["default"]` (or `%{}`) without touching disk.
  # Integration tests install fixture profiles this way against the
  # supervised singleton rather than swapping project_dir.
  @spec replace_profiles_for_test(map()) :: :ok
  def replace_profiles_for_test(profiles) when is_map(profiles) do
    GenServer.call(__MODULE__, {:replace_profiles_for_test, profiles})
  end

  @doc false
  # Test seam — clears the active-by-workspace map. Used by integration
  # test teardown to leave the supervised singleton clean for the next
  # test case.
  @spec clear_active_for_test() :: :ok
  def clear_active_for_test do
    GenServer.call(__MODULE__, :clear_active_for_test)
  end

  @doc """
  Returns the name of the ETS table the supervised ProfileManager uses
  as a read-only mirror of active overlays. `SessionManager` reads
  through this name rather than duplicating the literal — if the table
  is absent (isolated test PM without `ets_mirror: true`), reads
  gracefully fall back to `%{}`.
  """
  @spec ets_table() :: atom()
  def ets_table, do: @ets_active_env

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    ets_mirror? = Keyword.get(opts, :ets_mirror, false) == true

    if ets_mirror? do
      # :protected — only this process writes; outside readers are
      # welcome. :named_table means only one PM per VM can own the
      # mirror, which matches the singleton design (test instances opt
      # out via the default `ets_mirror: false`).
      :ets.new(@ets_active_env, [:set, :protected, :named_table, read_concurrency: true])
    end

    state = %__MODULE__{project_dir: project_dir, ets_mirror?: ets_mirror?}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    {profiles, default_env} = load_from_disk(state.project_dir)

    Logger.debug(
      "[ProfileManager] Loaded #{map_size(profiles)} profiles from #{config_path(state.project_dir)}"
    )

    if state.ets_mirror? do
      :ets.insert(@ets_active_env, {:__default__, @magic_default, default_env})
    end

    {:noreply, %{state | profiles: profiles, default_env: default_env}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    names =
      state.profiles
      |> Map.keys()
      |> Enum.reject(&(&1 == @magic_default))
      |> Enum.sort()

    {:reply, [@magic_default | names], state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.profiles, name) do
      {:ok, env} ->
        {:reply, {:ok, env}, state}

      :error ->
        cond do
          name == @magic_default -> {:reply, {:ok, state.default_env}, state}
          true -> {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:current, workspace_id}, _from, state) do
    {:reply, Map.get(state.active_by_workspace, workspace_id, @magic_default), state}
  end

  @impl true
  def handle_call({:active_env, workspace_id}, _from, state) do
    active = Map.get(state.active_by_workspace, workspace_id, @magic_default)
    {:reply, compose_env(state, active), state}
  end

  @impl true
  def handle_call({:switch, workspace_id, name, reason}, _from, state) do
    with :ok <- validate_profile_name(state, name) do
      current = Map.get(state.active_by_workspace, workspace_id, @magic_default)

      if current == name do
        {:reply, {:ok, name}, state}
      else
        case apply_switch(state, workspace_id, current, name, reason) do
          {:ok, new_state} -> {:reply, {:ok, name}, new_state}
          {:error, _} = error -> {:reply, error, state}
        end
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:replace_profiles_for_test, profiles}, _from, state) do
    default_env = Map.get(profiles, @magic_default, %{})

    if state.ets_mirror? do
      :ets.insert(@ets_active_env, {:__default__, @magic_default, default_env})
    end

    {:reply, :ok, %{state | profiles: profiles, default_env: default_env}}
  end

  @impl true
  def handle_call(:clear_active_for_test, _from, state) do
    if state.ets_mirror? do
      # Never leave the table without the default sentinel — later
      # tests reading the mirror after a clear would see %{} instead
      # of the default env and silently test the wrong thing.
      :ets.delete_all_objects(@ets_active_env)
      :ets.insert(@ets_active_env, {:__default__, @magic_default, state.default_env})
    end

    {:reply, :ok, %{state | active_by_workspace: %{}}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {new_profiles, new_default_env} = load_from_disk(state.project_dir)

    new_state =
      Enum.reduce(state.active_by_workspace, state, fn {ws, active_name}, acc ->
        transition_workspace(acc, ws, active_name, new_profiles, new_default_env)
      end)
      |> Map.put(:profiles, new_profiles)
      |> Map.put(:default_env, new_default_env)

    if state.ets_mirror? do
      :ets.insert(@ets_active_env, {:__default__, @magic_default, new_default_env})
    end

    Logger.info(
      "[ProfileManager] Reloaded #{map_size(new_profiles)} profiles (default? #{Map.has_key?(new_profiles, @magic_default)})"
    )

    {:reply, :ok, new_state}
  end

  # ---------------------------------------------------------------------------
  # Internals — switching
  # ---------------------------------------------------------------------------

  defp validate_profile_name(_state, @magic_default), do: :ok

  defp validate_profile_name(state, name) do
    if Map.has_key?(state.profiles, name), do: :ok, else: {:error, :unknown_profile}
  end

  defp apply_switch(state, workspace_id, from, to, reason) do
    keys_to_drop = keys_to_drop(state, from, to)
    new_overlay = compose_env(state, to)

    case SessionManager.update_env(workspace_id, keys_to_drop, new_overlay) do
      :ok ->
        new_active = Map.put(state.active_by_workspace, workspace_id, to)

        if state.ets_mirror? do
          :ets.insert(@ets_active_env, {workspace_id, to, new_overlay})
        end

        emit_switched(workspace_id, from, to, new_overlay, reason)
        {:ok, %{state | active_by_workspace: new_active}}

      {:error, _, _} = error ->
        {:error, error}

      {:error, _, _, _} = error ->
        {:error, error}

      {:error, _} = error ->
        error
    end
  end

  defp keys_to_drop(state, from, to) do
    keys_for = fn name ->
      Map.keys(state.default_env) ++ Map.keys(Map.get(state.profiles, name, %{}))
    end

    from_keys = keys_for.(from)
    to_keys = keys_for.(to)
    from_keys -- to_keys
  end

  defp compose_env(state, @magic_default), do: state.default_env

  defp compose_env(state, name) do
    Map.merge(state.default_env, Map.get(state.profiles, name, %{}))
  end

  defp emit_switched(workspace_id, from, to, overlay, reason) do
    JidoClaw.SignalBus.emit("jido_claw.shell.profile_switched", %{
      workspace_id: workspace_id,
      from: from,
      to: to,
      key_count: map_size(overlay),
      reason: reason
    })

    Logger.info(
      "[ProfileManager] Switched workspace=#{workspace_id} #{from} -> #{to} (#{map_size(overlay)} keys) reason=#{reason}"
    )
  end

  # Reload transition for one workspace. Computes drop+merge against
  # the *old* state (so removed-profile keys remain computable), then
  # returns an updated state with the workspace's active name and
  # session env adjusted.
  defp transition_workspace(state, workspace_id, active_name, new_profiles, new_default_env) do
    {target, reason} = resolve_reload_target(state, active_name, new_profiles)

    old_overlay = compose_env(state, active_name)

    # Transition target always resolves against the *new* state to compute
    # the new overlay, but we use the old profiles to compute drops so
    # keys owned by a removed profile are dropped correctly.
    new_overlay =
      if target == @magic_default do
        new_default_env
      else
        Map.merge(new_default_env, Map.get(new_profiles, target, %{}))
      end

    keys_owned_by_old = Map.keys(old_overlay)
    keys_owned_by_new = Map.keys(new_overlay)
    keys_to_drop = keys_owned_by_old -- keys_owned_by_new

    case SessionManager.update_env(workspace_id, keys_to_drop, new_overlay) do
      :ok ->
        new_active = Map.put(state.active_by_workspace, workspace_id, target)

        if state.ets_mirror? do
          :ets.insert(@ets_active_env, {workspace_id, target, new_overlay})
        end

        if target != active_name do
          emit_switched(workspace_id, active_name, target, new_overlay, reason)

          if reason == "profile_removed" do
            Logger.warning(
              "[ProfileManager] Profile '#{active_name}' removed from config; workspace=#{workspace_id} fell back to default"
            )
          end
        end

        %{state | active_by_workspace: new_active}

      {:error, reason_tag} ->
        Logger.warning(
          "[ProfileManager] Reload transition failed for workspace=#{workspace_id}: #{inspect(reason_tag)}"
        )

        state

      {:error, _, _} = error ->
        Logger.warning(
          "[ProfileManager] Reload transition failed for workspace=#{workspace_id}: #{inspect(error)}"
        )

        state

      {:error, _, _, _} = error ->
        Logger.warning(
          "[ProfileManager] Reload transition failed for workspace=#{workspace_id}: #{inspect(error)}"
        )

        state
    end
  end

  defp resolve_reload_target(_state, @magic_default, _new_profiles),
    do: {@magic_default, "reload"}

  defp resolve_reload_target(_state, active_name, new_profiles) do
    cond do
      Map.has_key?(new_profiles, active_name) -> {active_name, "reload"}
      true -> {@magic_default, "profile_removed"}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals — loading
  # ---------------------------------------------------------------------------

  defp config_path(project_dir), do: Path.join([project_dir, ".jido", "config.yaml"])

  defp load_from_disk(project_dir) do
    config = Config.load(project_dir)
    raw = Config.profiles(config)

    profiles =
      raw
      |> Enum.reduce(%{}, fn {name, env}, acc -> parse_profile(acc, name, env) end)

    default_env = Map.get(profiles, @magic_default, %{})
    {profiles, default_env}
  end

  defp parse_profile(acc, name, env) when is_binary(name) and is_map(env) do
    clean_name = String.trim(name)

    cond do
      clean_name == "" ->
        Logger.warning("[ProfileManager] Skipping profile with empty name")
        acc

      true ->
        coerced =
          Enum.reduce(env, %{}, fn {k, v}, kv -> coerce_entry(kv, clean_name, k, v) end)

        Map.put(acc, clean_name, coerced)
    end
  end

  # Binary name but non-map env: the name is safe to log (YAML strings
  # rarely carry secrets in a top-level profile key), but the env
  # payload must never be inspected.
  defp parse_profile(acc, name, other) when is_binary(name) do
    Logger.warning(
      "[ProfileManager] Profile '#{name}' env is not a mapping (got: #{type_hint(other)}) — skipping"
    )

    acc
  end

  # Non-binary name: the name itself is a structured term that could
  # carry a secret payload. Never inspect it — log only the type
  # hint, mirroring the key/value policy in `coerce_entry/4`.
  defp parse_profile(acc, name, other) do
    Logger.warning(
      "[ProfileManager] Profile with non-string name (got: #{type_hint(name)}, env: #{type_hint(other)}) — skipping"
    )

    acc
  end

  defp coerce_entry(acc, profile, key, value) do
    cond do
      not is_binary(key) ->
        Logger.warning(
          "[ProfileManager] Non-string key in profile '#{profile}' (got: #{type_hint(key)}) — skipping entry"
        )

        acc

      is_binary(value) ->
        Map.put(acc, key, value)

      is_integer(value) ->
        Map.put(acc, key, Integer.to_string(value))

      true ->
        Logger.warning(
          "[ProfileManager] Non-string value for #{profile}.#{key} (got: #{type_hint(value)}) — skipping entry"
        )

        acc
    end
  end

  # Structural type hint for rejected profile values — never the value
  # itself. A config typo like `DATABASE_PASSWORD: [prod-secret]` should
  # log `list/1`, not the secret. Keys fall through the same helper
  # because a non-string key could itself be a structured term carrying
  # sensitive data.
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
