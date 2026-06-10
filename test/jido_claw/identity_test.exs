defmodule JidoClaw.Agent.IdentityTest do
  use ExUnit.Case, async: true
  # async: Identity is pure functions with isolated tmp dirs — no shared global state.

  alias JidoClaw.Agent.Identity

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_identity_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # generate_keypair/0
  # ---------------------------------------------------------------------------

  describe "generate_keypair/0" do
    test "returns a {public_key, private_key} two-element tuple" do
      result = Identity.generate_keypair()
      assert is_tuple(result)
      assert tuple_size(result) == 2
    end

    test "both keys are 32-byte binaries (Ed25519 key size)" do
      {pub, priv} = Identity.generate_keypair()
      assert byte_size(pub) == 32
      assert byte_size(priv) == 32
    end

    test "generates a different keypair on each call" do
      {pub1, priv1} = Identity.generate_keypair()
      {pub2, priv2} = Identity.generate_keypair()
      refute pub1 == pub2
      refute priv1 == priv2
    end
  end

  # ---------------------------------------------------------------------------
  # derive_agent_id/1
  # ---------------------------------------------------------------------------

  describe "derive_agent_id/1" do
    test "result starts with \"jido_\"" do
      {pub, _priv} = Identity.generate_keypair()
      assert String.starts_with?(Identity.derive_agent_id(pub), "jido_")
    end

    test "result is exactly 12 characters (5-char prefix + 7-char suffix)" do
      {pub, _priv} = Identity.generate_keypair()
      assert String.length(Identity.derive_agent_id(pub)) == 12
    end

    test "is deterministic — same public key always yields same agent_id" do
      {pub, _priv} = Identity.generate_keypair()
      id1 = Identity.derive_agent_id(pub)
      id2 = Identity.derive_agent_id(pub)
      assert id1 == id2
    end

    test "different public keys produce different agent IDs" do
      {pub1, _} = Identity.generate_keypair()
      {pub2, _} = Identity.generate_keypair()
      refute Identity.derive_agent_id(pub1) == Identity.derive_agent_id(pub2)
    end
  end

  # ---------------------------------------------------------------------------
  # sign/2 and verify/3
  # ---------------------------------------------------------------------------

  describe "sign/2 and verify/3" do
    test "sign and verify a message successfully" do
      {pub, priv} = Identity.generate_keypair()
      message = "hello agent"
      sig = Identity.sign(message, priv)
      assert Identity.verify(message, sig, pub)
    end

    test "verification fails with a different public key" do
      {_pub1, priv} = Identity.generate_keypair()
      {pub2, _priv2} = Identity.generate_keypair()
      message = "hello agent"
      sig = Identity.sign(message, priv)
      refute Identity.verify(message, sig, pub2)
    end

    test "verification fails when the message is tampered" do
      {pub, priv} = Identity.generate_keypair()
      sig = Identity.sign("original message", priv)
      refute Identity.verify("tampered message", sig, pub)
    end

    test "verification fails with an invalid (non-base64) signature" do
      {pub, _priv} = Identity.generate_keypair()
      refute Identity.verify("any message", "not!!valid==base64", pub)
    end

    test "sign/2 returns a Base64-encoded string" do
      {_pub, priv} = Identity.generate_keypair()
      sig = Identity.sign("test", priv)
      assert is_binary(sig)
      assert {:ok, _} = Base.decode64(sig)
    end
  end

  # ---------------------------------------------------------------------------
  # sign_solution/2 and verify_solution/3
  # ---------------------------------------------------------------------------

  describe "sign_solution/2 and verify_solution/3" do
    test "sign and verify solution content successfully" do
      {pub, priv} = Identity.generate_keypair()
      content = "solution payload"
      sig = Identity.sign_solution(content, priv)
      assert Identity.verify_solution(content, sig, pub)
    end

    test "verification fails when solution content is tampered" do
      {pub, priv} = Identity.generate_keypair()
      sig = Identity.sign_solution("original solution", priv)
      refute Identity.verify_solution("tampered solution", sig, pub)
    end

    test "verification fails with a wrong public key" do
      {_pub1, priv} = Identity.generate_keypair()
      {pub2, _priv2} = Identity.generate_keypair()
      sig = Identity.sign_solution("solution", priv)
      refute Identity.verify_solution("solution", sig, pub2)
    end

    test "sign_solution/2 and sign/2 produce different signatures for the same raw bytes" do
      # sign_solution hashes first; sign does not — so the two must differ
      {_pub, priv} = Identity.generate_keypair()
      payload = "same content"
      sig_raw = Identity.sign(payload, priv)
      sig_solution = Identity.sign_solution(payload, priv)
      refute sig_raw == sig_solution
    end
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "creates an identity when none exists", %{tmp_dir: tmp_dir} do
      assert {:ok, %Identity{}} = Identity.init(tmp_dir)
    end

    test "loads an existing identity on second call (no new keypair generated)", %{
      tmp_dir: tmp_dir
    } do
      {:ok, identity1} = Identity.init(tmp_dir)
      {:ok, identity2} = Identity.init(tmp_dir)
      assert identity1.agent_id == identity2.agent_id
      assert identity1.public_key == identity2.public_key
    end

    test "returns the same agent_id on repeated calls", %{tmp_dir: tmp_dir} do
      {:ok, %Identity{agent_id: id1}} = Identity.init(tmp_dir)
      {:ok, %Identity{agent_id: id2}} = Identity.init(tmp_dir)
      assert id1 == id2
    end

    test "creates .jido/identity.json file", %{tmp_dir: tmp_dir} do
      Identity.init(tmp_dir)
      assert File.exists?(Path.join(tmp_dir, ".jido/identity.json"))
    end

    test "sets identity.json file permissions to 0o600", %{tmp_dir: tmp_dir} do
      Identity.init(tmp_dir)
      path = Path.join(tmp_dir, ".jido/identity.json")
      {:ok, %{mode: mode}} = File.stat(path)
      # Mask to permission bits only (lower 9 bits)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "returned identity has a non-nil agent_id, public_key, private_key, and created_at", %{
      tmp_dir: tmp_dir
    } do
      {:ok, identity} = Identity.init(tmp_dir)
      assert is_binary(identity.agent_id)
      assert is_binary(identity.public_key)
      assert is_binary(identity.private_key)
      assert is_binary(identity.created_at)
    end
  end

  # ---------------------------------------------------------------------------
  # load/1
  # ---------------------------------------------------------------------------

  describe "load/1" do
    test "returns {:ok, identity} when identity file exists", %{tmp_dir: tmp_dir} do
      {:ok, _} = Identity.init(tmp_dir)
      assert {:ok, %Identity{}} = Identity.load(tmp_dir)
    end

    test "returns {:error, :not_found} when no identity file exists", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} = Identity.load(tmp_dir)
    end

    test "returns {:error, :not_found} when the identity file is corrupt", %{tmp_dir: tmp_dir} do
      jido_dir = Path.join(tmp_dir, ".jido")
      File.mkdir_p!(jido_dir)
      File.write!(Path.join(jido_dir, "identity.json"), "not valid json }{")
      assert {:error, :not_found} = Identity.load(tmp_dir)
    end

    test "loaded identity has the same agent_id as the one that was saved", %{tmp_dir: tmp_dir} do
      {:ok, original} = Identity.init(tmp_dir)
      {:ok, loaded} = Identity.load(tmp_dir)
      assert loaded.agent_id == original.agent_id
    end

    test "loaded identity has the same public and private keys as the original", %{
      tmp_dir: tmp_dir
    } do
      {:ok, original} = Identity.init(tmp_dir)
      {:ok, loaded} = Identity.load(tmp_dir)
      assert loaded.public_key == original.public_key
      assert loaded.private_key == original.private_key
    end
  end

  # ---------------------------------------------------------------------------
  # save/2
  # ---------------------------------------------------------------------------

  describe "save/2" do
    test "writes identity.json to the .jido/ directory", %{tmp_dir: tmp_dir} do
      {pub, priv} = Identity.generate_keypair()

      identity = %Identity{
        agent_id: Identity.derive_agent_id(pub),
        public_key: pub,
        private_key: priv,
        created_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      :ok = Identity.save(identity, tmp_dir)
      assert File.exists?(Path.join(tmp_dir, ".jido/identity.json"))
    end

    test "creates the .jido/ directory when it does not exist", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "newproject")
      File.mkdir_p!(subdir)

      {pub, priv} = Identity.generate_keypair()

      identity = %Identity{
        agent_id: Identity.derive_agent_id(pub),
        public_key: pub,
        private_key: priv,
        created_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      :ok = Identity.save(identity, subdir)
      assert File.exists?(Path.join(subdir, ".jido/identity.json"))
    end

    test "produces valid JSON that can be loaded back via load/1", %{tmp_dir: tmp_dir} do
      {pub, priv} = Identity.generate_keypair()
      agent_id = Identity.derive_agent_id(pub)

      identity = %Identity{
        agent_id: agent_id,
        public_key: pub,
        private_key: priv,
        created_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      :ok = Identity.save(identity, tmp_dir)
      {:ok, loaded} = Identity.load(tmp_dir)

      assert loaded.agent_id == agent_id
      assert loaded.public_key == pub
      assert loaded.private_key == priv
    end

    test "returns :ok", %{tmp_dir: tmp_dir} do
      {pub, priv} = Identity.generate_keypair()

      identity = %Identity{
        agent_id: Identity.derive_agent_id(pub),
        public_key: pub,
        private_key: priv,
        created_at: DateTime.to_iso8601(DateTime.utc_now())
      }

      assert :ok = Identity.save(identity, tmp_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # agent_id/1
  # ---------------------------------------------------------------------------

  describe "agent_id/1" do
    test "returns the agent_id when an identity exists", %{tmp_dir: tmp_dir} do
      {:ok, identity} = Identity.init(tmp_dir)
      assert Identity.agent_id(tmp_dir) == identity.agent_id
    end

    test "returns \"jido_unknown\" when no identity file exists", %{tmp_dir: tmp_dir} do
      assert Identity.agent_id(tmp_dir) == "jido_unknown"
    end

    test "returns \"jido_unknown\" when identity file is corrupt", %{tmp_dir: tmp_dir} do
      jido_dir = Path.join(tmp_dir, ".jido")
      File.mkdir_p!(jido_dir)
      File.write!(Path.join(jido_dir, "identity.json"), "{bad json")
      assert Identity.agent_id(tmp_dir) == "jido_unknown"
    end
  end
end
