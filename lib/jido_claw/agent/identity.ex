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

  Returns `{:ok, %JidoClaw.Agent.Identity{}}` or `{:error, :not_found}`.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :not_found}
  def load(project_dir) do
    path = identity_path(project_dir)

    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         {:ok, pub} <- Base.decode64(data["public_key"] || ""),
         {:ok, priv} <- Base.decode64(data["private_key"] || "") do
      identity = %__MODULE__{
        agent_id: data["agent_id"],
        public_key: pub,
        private_key: priv,
        created_at: data["created_at"]
      }

      {:ok, identity}
    else
      _ -> {:error, :not_found}
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

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, json) do
      File.chmod(dir, 0o700)
      File.chmod(path, 0o600)
      :ok
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
end
