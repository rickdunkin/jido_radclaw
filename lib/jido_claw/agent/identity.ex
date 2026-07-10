defmodule JidoClaw.Agent.Identity do
  @moduledoc """
  Ed25519 cryptographic identity for agents.

  Provides key generation, signing, verification, and persistent storage
  of agent identity under `.jido/identity.json` within a project directory.
  Keys are stored as Base64-encoded strings; file permissions are locked to
  owner-only (0o600 for the file, 0o700 for the directory).
  """

  @identity_filename ".jido/identity.json"

  defstruct [:agent_id, :public_key, :private_key, :created_at]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          public_key: binary(),
          private_key: binary(),
          created_at: String.t()
        }

  @doc """
  Load existing identity from `project_dir` or generate and persist a new one.

  Returns `{:ok, %JidoClaw.Agent.Identity{}}`.
  """
  @spec init(String.t()) :: {:ok, t()} | {:error, term()}
  def init(project_dir) do
    case load(project_dir) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, :not_found} ->
        {pub, priv} = generate_keypair()
        agent_id = derive_agent_id(pub)

        identity = %__MODULE__{
          agent_id: agent_id,
          public_key: pub,
          private_key: priv,
          created_at: DateTime.to_iso8601(DateTime.utc_now())
        }

        case save(identity, project_dir) do
          :ok -> {:ok, identity}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate an Ed25519 keypair.

  Returns `{public_key, private_key}` as raw binaries.
  """
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  @doc """
  Derive a short, human-readable agent ID from a public key.

  Format: `"jido_" <> first_7_chars_of_url_safe_base64`.
  """
  @spec derive_agent_id(binary()) :: String.t()
  def derive_agent_id(public_key) do
    suffix =
      public_key
      |> Base.url_encode64(padding: false)
      |> String.slice(0, 7)

    "jido_" <> suffix
  end

  @doc """
  Sign a binary message with an Ed25519 private key.

  Returns the signature as a Base64-encoded string.
  """
  @spec sign(binary(), binary()) :: String.t()
  def sign(message, private_key) do
    sig = :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
    Base.encode64(sig)
  end

  @doc """
  Verify a Base64-encoded Ed25519 signature against a message and public key.

  Returns `true` if valid, `false` otherwise (including on decode errors).
  """
  @spec verify(binary(), String.t(), binary()) :: boolean()
  def verify(message, signature_b64, public_key) do
    case Base.decode64(signature_b64) do
      {:ok, sig} ->
        :crypto.verify(:eddsa, :none, message, sig, [public_key, :ed25519])

      :error ->
        false
    end
  end

  @doc """
  Sign solution content by first hashing it with SHA-256, then signing the digest.

  Returns a Base64-encoded signature string.
  """
  @spec sign_solution(binary(), binary()) :: String.t()
  def sign_solution(solution_content, private_key) do
    hash = :crypto.hash(:sha256, solution_content)
    sign(hash, private_key)
  end

  @doc """
  Verify a solution signature by hashing content with SHA-256 and verifying the digest.

  Returns `true` if valid, `false` otherwise.
  """
  @spec verify_solution(binary(), String.t(), binary()) :: boolean()
  def verify_solution(solution_content, signature_b64, public_key) do
    hash = :crypto.hash(:sha256, solution_content)
    verify(hash, signature_b64, public_key)
  end

  @doc """
  Load identity from `.jido/identity.json` under `project_dir`.

  Returns `{:ok, %JidoClaw.Agent.Identity{}}`, `{:error, :not_found}` only when
  the file is absent, or a distinct corruption/filesystem error. A corrupt
  identity is never silently replaced with a newly generated principal.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(project_dir) do
    dir = jido_dir(project_dir)
    path = identity_path(project_dir)

    with :ok <- validate_identity_dir_for_load(dir) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          with :ok <- chmod_identity_file(path), do: decode_identity_file(path)

        {:ok, %File.Stat{type: type}} ->
          {:error, {:invalid_identity_file, type}}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, {:identity_read_failed, reason}}
      end
    end
  end

  @doc """
  Save identity to `.jido/identity.json` under `project_dir`.

  Creates the `.jido/` directory if it does not exist.
  Sets directory permissions to 0o700 and file permissions to 0o600.

  Returns `:ok` or `{:error, reason}` if the filesystem write fails.
  """
  @spec save(t(), String.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = identity, project_dir) do
    dir = jido_dir(project_dir)
    path = identity_path(project_dir)

    json =
      Jason.encode!(%{
        "agent_id" => identity.agent_id,
        "public_key" => Base.encode64(identity.public_key),
        "private_key" => Base.encode64(identity.private_key),
        "created_at" => identity.created_at
      })

    with :ok <- validate_identity(identity),
         :ok <- ensure_secure_identity_dir(dir),
         :ok <- validate_identity_target(path) do
      atomic_secure_write(path, json)
    end
  end

  @doc """
  Quick accessor — load identity and return its `agent_id`.

  Returns `"jido_unknown"` if the identity cannot be loaded.
  """
  @spec agent_id(String.t()) :: String.t()
  def agent_id(project_dir \\ File.cwd!()) do
    case load(project_dir) do
      {:ok, %__MODULE__{agent_id: id}} -> id
      {:error, _} -> "jido_unknown"
    end
  end

  # --- Private helpers ---

  defp jido_dir(project_dir), do: Path.join(project_dir, ".jido")

  defp identity_path(project_dir), do: Path.join(project_dir, @identity_filename)

  defp decode_identity_file(path) do
    with {:ok, raw} <- read_identity(path),
         {:ok, data} <- decode_identity_json(raw),
         {:ok, identity} <- identity_from_data(data),
         :ok <- validate_identity(identity) do
      {:ok, identity}
    end
  end

  defp read_identity(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:identity_read_failed, reason}}
    end
  end

  defp decode_identity_json(raw) do
    case Jason.decode(raw) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, {:corrupt_identity, :not_an_object}}
      {:error, reason} -> {:error, {:corrupt_identity, {:invalid_json, reason}}}
    end
  end

  defp identity_from_data(data) do
    with {:ok, agent_id} <- required_string(data, "agent_id"),
         {:ok, created_at} <- required_string(data, "created_at"),
         {:ok, public_key} <- decode_key(data, "public_key"),
         {:ok, private_key} <- decode_key(data, "private_key") do
      {:ok,
       %__MODULE__{
         agent_id: agent_id,
         public_key: public_key,
         private_key: private_key,
         created_at: created_at
       }}
    end
  end

  defp required_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:corrupt_identity, {:invalid_field, key}}}
    end
  end

  defp decode_key(data, key) do
    with {:ok, encoded} <- required_string(data, key),
         {:ok, decoded} <- Base.decode64(encoded),
         true <- byte_size(decoded) == 32 do
      {:ok, decoded}
    else
      _ -> {:error, {:corrupt_identity, {:invalid_key, key}}}
    end
  end

  defp validate_identity(%__MODULE__{} = identity) do
    with true <- is_binary(identity.agent_id) and identity.agent_id != "",
         true <- is_binary(identity.public_key) and byte_size(identity.public_key) == 32,
         true <- is_binary(identity.private_key) and byte_size(identity.private_key) == 32,
         true <- identity.agent_id == derive_agent_id(identity.public_key),
         {derived_public, derived_private} <-
           :crypto.generate_key(:eddsa, :ed25519, identity.private_key),
         true <- derived_private == identity.private_key,
         true <- derived_public == identity.public_key,
         true <- valid_created_at?(identity.created_at) do
      :ok
    else
      _ -> {:error, {:corrupt_identity, :inconsistent_identity}}
    end
  rescue
    _exception in [ArgumentError, ErlangError] ->
      {:error, {:corrupt_identity, :inconsistent_identity}}
  end

  defp valid_created_at?(value) when is_binary(value),
    do: match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))

  defp valid_created_at?(_value), do: false

  defp ensure_secure_identity_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> chmod_identity_dir(dir)
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_identity_dir, type}}
      {:error, :enoent} -> create_identity_dir(dir)
      {:error, reason} -> {:error, {:identity_dir_failed, reason}}
    end
  end

  defp validate_identity_dir_for_load(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> chmod_identity_dir(dir)
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_identity_dir, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:identity_dir_failed, reason}}
    end
  end

  defp create_identity_dir(dir) do
    with :ok <- File.mkdir_p(Path.dirname(dir)),
         :ok <- File.mkdir(dir) do
      chmod_identity_dir(dir)
    else
      {:error, :eexist} -> ensure_secure_identity_dir(dir)
      {:error, reason} -> {:error, {:identity_dir_failed, reason}}
    end
  end

  defp chmod_identity_dir(dir) do
    case File.chmod(dir, 0o700) do
      :ok -> :ok
      {:error, reason} -> {:error, {:identity_chmod_failed, :directory, reason}}
    end
  end

  defp validate_identity_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_identity_file, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:identity_read_failed, reason}}
    end
  end

  # The temporary file is chmodded before secret bytes are written, fsynced,
  # then atomically renamed over the destination. A symlink at the destination
  # is rejected above rather than followed.
  defp atomic_secure_write(path, content) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    result =
      with {:ok, io} <- File.open(tmp, [:write, :binary, :exclusive]),
           :ok <- write_identity_io(io, tmp, content) do
        File.rename(tmp, path)
      end

    if result != :ok, do: File.rm(tmp)
    result
  end

  defp write_identity_io(io, tmp, content) do
    result =
      with :ok <- chmod_identity_file(tmp),
           :ok <- IO.binwrite(io, content) do
        :file.sync(io)
      end

    close_result = File.close(io)
    if result == :ok, do: close_result, else: result
  end

  defp chmod_identity_file(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:identity_chmod_failed, :file, reason}}
    end
  end
end
