defmodule JidoClaw.Forge.ResourceProvisioner do
  @moduledoc """
  Provisions declarative resources into a sandbox environment.

  Resource types and their persistence contract:

  - `:env_vars`   - non-secret environment variables, stored verbatim.
                    Sensitive values must use `:secrets` instead.
  - `:secrets`    - references to vault keys, resolved at provision time.
                    Only references are persisted, never resolved values.
  - `:git_repo`   - clones a git repository into the sandbox.
  - `:file_mount` - handled at sandbox create time (passed through to Docker).
  """

  require Logger

  alias JidoClaw.Forge.Sandbox
  alias JidoClaw.Security.Redaction.Patterns

  @sensitive_key_pattern ~r/(?i)(password|secret|token|key|credential|auth)/
  @credentialed_url_pattern ~r{://[^/:@]+:[^/:@]+@}

  # ── Validation ──────────────────────────────────────────────────────

  @doc """
  Validates that resources follow the persistence contract.

  - `:env_vars` must not contain sensitive key names or secret-shaped values.
    Callers should use `:secrets` for anything sensitive.
  - All resource entries must have a known `:type`.

  Returns `:ok` or `{:error, reasons}` where reasons is a list of strings.
  """
  @spec validate_resources([map()]) :: :ok | {:error, [String.t()]}
  def validate_resources(resources) do
    errors =
      resources
      |> Enum.flat_map(&validate_resource/1)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_resource(%{type: :env_vars, values: values}) when is_map(values) do
    Enum.flat_map(values, fn {key, value} ->
      key_str = to_string(key)
      value_str = to_string(value)
      errors = []

      errors =
        if Regex.match?(@sensitive_key_pattern, key_str) do
          [
            "env_vars key #{inspect(key)} looks sensitive — use a :secrets resource instead"
            | errors
          ]
        else
          errors
        end

      errors =
        if value_str != Patterns.redact(value_str) do
          [
            "env_vars value for #{inspect(key)} looks like a secret — use a :secrets resource instead"
            | errors
          ]
        else
          errors
        end

      errors =
        if Regex.match?(@credentialed_url_pattern, value_str) do
          [
            "env_vars value for #{inspect(key)} contains embedded credentials — use a :secrets resource instead"
            | errors
          ]
        else
          errors
        end

      errors
    end)
  end

  defp validate_resource(%{type: :env_vars, values: values}) when not is_map(values),
    do: [":env_vars requires :values to be a map, got: #{inspect(values)}"]

  defp validate_resource(%{type: :env_vars} = r) when not is_map_key(r, :values),
    do: [":env_vars resource missing required :values key"]

  defp validate_resource(%{type: :git_repo} = r) do
    missing =
      [:source]
      |> Enum.reject(&Map.has_key?(r, &1))
      |> Enum.map(&":git_repo resource missing required #{inspect(&1)} key")

    missing
  end

  defp validate_resource(%{type: :file_mount} = r) do
    missing =
      [:source, :mount_path]
      |> Enum.reject(&Map.has_key?(r, &1))
      |> Enum.map(&":file_mount resource missing required #{inspect(&1)} key")

    missing
  end

  defp validate_resource(%{type: :secrets} = r) do
    has_env_map = is_map(r[:env_map]) and map_size(r[:env_map]) > 0
    has_vault_keys = is_list(r[:vault_keys]) and length(r[:vault_keys]) > 0

    if has_env_map or has_vault_keys do
      []
    else
      [":secrets resource requires :env_map (map) or :vault_keys (list)"]
    end
  end

  defp validate_resource(%{type: type}),
    do: ["unknown resource type: #{inspect(type)}"]

  defp validate_resource(other),
    do: ["resource missing :type key: #{inspect(other)}"]

  # ── Provisioning ────────────────────────────────────────────────────

  @doc """
  Provisions all resources in order. File mounts are skipped here as they
  are handled at sandbox creation time via sandbox_spec.

  Returns `:ok` or `{:error, resource, reason}` on the first failure.
  """
  @spec provision_all(struct(), [map()]) :: :ok | {:error, map(), term()}
  def provision_all(_client, []), do: :ok

  def provision_all(client, resources) when is_list(resources) do
    Enum.reduce_while(resources, :ok, fn resource, :ok ->
      case provision(client, resource) do
        :ok -> {:cont, :ok}
        {:skip, _reason} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, resource, reason}}
      end
    end)
  end

  @doc """
  Provisions a single resource into the sandbox.
  """
  @spec provision(struct(), map()) :: :ok | {:skip, term()} | {:error, term()}
  def provision(client, %{type: :git_repo} = spec) do
    source = Map.fetch!(spec, :source)
    mount_path = Map.get(spec, :mount_path, "/workspace/repo")
    branch = Map.get(spec, :branch)

    clone_cmd = "git clone"
    clone_cmd = if branch, do: "#{clone_cmd} --branch #{branch}", else: clone_cmd
    clone_cmd = "#{clone_cmd} #{source} #{mount_path}"

    case Sandbox.exec(client, clone_cmd) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:git_clone_failed, code, String.slice(output, 0, 500)}}
    end
  end

  def provision(_client, %{type: :file_mount}) do
    # File mounts are handled at sandbox creation time via sandbox_spec.
    # See file_mount_specs/1 which extracts these for Docker.create/1.
    {:skip, :handled_at_create}
  end

  def provision(client, %{type: :env_vars} = spec) do
    values = Map.get(spec, :values, %{})

    if map_size(values) > 0 do
      Sandbox.inject_env(client, values)
    else
      :ok
    end
  end

  def provision(client, %{type: :secrets, env_map: env_map}) when is_map(env_map) do
    vault_keys = Map.values(env_map)

    case resolve_secrets(vault_keys) do
      {:ok, resolved} ->
        env =
          Map.new(env_map, fn {env_name, vault_key} ->
            {env_name, Map.get(resolved, vault_key, "")}
          end)

        if map_size(env) > 0 do
          Sandbox.inject_env(client, env)
        else
          :ok
        end

      {:error, reason} ->
        {:error, {:secret_resolution_failed, reason}}
    end
  end

  def provision(client, %{type: :secrets} = spec) do
    vault_keys = Map.get(spec, :vault_keys, [])
    env_prefix = Map.get(spec, :env_prefix, "")

    case resolve_secrets(vault_keys) do
      {:ok, resolved} ->
        env =
          Map.new(resolved, fn {key, value} ->
            {"#{env_prefix}#{String.upcase(key)}", value}
          end)

        if map_size(env) > 0 do
          Sandbox.inject_env(client, env)
        else
          :ok
        end

      {:error, reason} ->
        {:error, {:secret_resolution_failed, reason}}
    end
  end

  def provision(_client, %{type: type}) do
    {:error, {:unknown_resource_type, type}}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  @doc """
  Extracts file_mount resources from a resource list for passing to sandbox creation.
  Returns a list of `{host_path, container_path, mode}` tuples compatible
  with Docker sandbox's mount format.
  """
  @spec file_mount_specs([map()]) :: [{String.t(), String.t(), atom()}]
  def file_mount_specs(resources) do
    resources
    |> Enum.filter(&(&1[:type] == :file_mount))
    |> Enum.map(fn spec ->
      {Map.fetch!(spec, :source), Map.fetch!(spec, :mount_path), Map.get(spec, :mode, :ro)}
    end)
  end

  # Secret resolution - delegates to application-configured resolver or returns error.
  defp resolve_secrets(vault_keys) do
    case Application.get_env(:jido_claw, :secret_resolver) do
      nil ->
        Logger.warning(
          "[ResourceProvisioner] No :secret_resolver configured, skipping #{length(vault_keys)} keys"
        )

        {:ok, %{}}

      resolver when is_function(resolver, 1) ->
        resolver.(vault_keys)

      resolver when is_atom(resolver) ->
        resolver.resolve(vault_keys)
    end
  end
end
