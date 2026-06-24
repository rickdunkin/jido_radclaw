defmodule JidoClaw.VFS.SandboxTest do
  # Pure filesystem unit tests over a per-test tmp base; no DB / global state.
  use ExUnit.Case, async: true

  alias JidoClaw.VFS.Sandbox

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  setup do
    base = Path.join(System.tmp_dir!(), "sandbox-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  describe "create_prototype_dir/1" do
    test "creates a fresh .prototypes/<uuid>/ dir + id under an existing base", %{base: base} do
      assert {:ok, %{dir: dir, id: id}} = Sandbox.create_prototype_dir(base)
      assert Regex.match?(@uuid, id)
      assert Path.dirname(dir) == Path.join(Path.expand(base), ".prototypes")
      assert Path.basename(dir) == id
      assert File.dir?(dir)
    end

    test "nil / empty base → :missing_project_dir" do
      assert {:error, :missing_project_dir} = Sandbox.create_prototype_dir(nil)
      assert {:error, :missing_project_dir} = Sandbox.create_prototype_dir("")
      assert {:error, :missing_project_dir} = Sandbox.create_prototype_dir(42)
    end

    test "a non-existent base → :base_not_a_directory and creates NOTHING (phantom guard)",
         %{base: base} do
      missing = Path.join(base, "does-not-exist")

      assert {:error, :base_not_a_directory} = Sandbox.create_prototype_dir(missing)
      # The phantom-project guard: File.mkdir_p/1 must not have fabricated a tree.
      refute File.exists?(missing)
    end

    test "a planted .prototypes symlink → :symlinked_prototypes, link untouched", %{base: base} do
      target = Path.join(System.tmp_dir!(), "evil-#{System.unique_integer([:positive])}")
      File.mkdir_p!(target)
      on_exit(fn -> File.rm_rf!(target) end)

      link = Path.join(base, ".prototypes")
      File.ln_s!(target, link)

      assert {:error, :symlinked_prototypes} = Sandbox.create_prototype_dir(base)
      # The link is left in place pointing at its original target (not followed).
      assert {:ok, ^target} = File.read_link(link)
      assert File.ls!(target) == []
    end
  end

  describe "validate_root/1" do
    test "accepts a real .prototypes/<uuid>/ root", %{base: base} do
      {:ok, %{dir: dir}} = Sandbox.create_prototype_dir(base)
      assert :ok = Sandbox.validate_root(dir)
    end

    test "rejects a non-binary / nil root" do
      assert {:error, :invalid_sandbox_root} = Sandbox.validate_root(nil)
      assert {:error, :invalid_sandbox_root} = Sandbox.validate_root(123)
    end

    test "rejects <base>/.prototypes/../real-dir (lexical escape)", %{base: base} do
      File.mkdir_p!(Path.join(base, ".prototypes"))
      File.mkdir_p!(Path.join(base, "real-dir"))

      assert {:error, :not_under_prototypes} =
               Sandbox.validate_root(Path.join([base, ".prototypes", "..", "real-dir"]))
    end

    test "rejects a non-UUID child", %{base: base} do
      child = Path.join([base, ".prototypes", "not-a-uuid"])
      File.mkdir_p!(child)

      assert {:error, :child_not_uuid} = Sandbox.validate_root(child)
    end

    test "rejects a .prototypes that is itself a symlink to another .prototypes", %{base: base} do
      # The realpath-basename bypass review flagged: a `<base>/.prototypes ->
      # /elsewhere/.prototypes` link's target basename is ALSO `.prototypes`, so
      # the realpath-basename check alone would pass — the parent lstat catches it.
      elsewhere = Path.join(System.tmp_dir!(), "elsewhere-#{System.unique_integer([:positive])}")
      real_protos = Path.join(elsewhere, ".prototypes")
      uuid = Ash.UUID.generate()
      File.mkdir_p!(Path.join(real_protos, uuid))
      on_exit(fn -> File.rm_rf!(elsewhere) end)

      File.ln_s!(real_protos, Path.join(base, ".prototypes"))
      candidate = Path.join([base, ".prototypes", uuid])

      assert {:error, :symlinked_prototypes} = Sandbox.validate_root(candidate)
    end

    test "rejects a regular FILE at .prototypes/<uuid> (review P3)", %{base: base} do
      # A valid-UUID, non-symlink regular file passed every prior check
      # (basename shape, lstat symlink rejection, realpath of an existing file).
      File.mkdir_p!(Path.join(base, ".prototypes"))
      uuid = Ash.UUID.generate()
      file_at_uuid = Path.join([base, ".prototypes", uuid])
      File.write!(file_at_uuid, "i am a file, not a dir")

      assert {:error, :not_a_directory} = Sandbox.validate_root(file_at_uuid)
    end

    test "rejects a non-existent .prototypes/<uuid> child (normalized from :enoent)",
         %{base: base} do
      File.mkdir_p!(Path.join(base, ".prototypes"))
      uuid = Ash.UUID.generate()
      missing_child = Path.join([base, ".prototypes", uuid])

      refute File.exists?(missing_child)
      assert {:error, :not_a_directory} = Sandbox.validate_root(missing_child)
    end
  end

  describe "real_root/1 (AR-8b-2 F3)" do
    test "derives the real base (grandparent) from a valid prototype dir", %{base: base} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(base)

      assert {:ok, real} = Sandbox.real_root(proto)
      assert real == Path.expand(base)
      assert Path.dirname(Path.dirname(proto)) == real
    end

    test "fails closed on a non-prototype / nil / empty path", %{base: base} do
      # `base` itself is not a `.prototypes/<uuid>/` root.
      assert {:error, _} = Sandbox.real_root(base)
      assert {:error, :invalid_sandbox_root} = Sandbox.real_root(nil)
      assert {:error, :invalid_sandbox_root} = Sandbox.real_root("")
      assert {:error, :invalid_sandbox_root} = Sandbox.real_root(123)
    end

    test "fails closed on a symlink-escaping .prototypes", %{base: base} do
      elsewhere =
        Path.join(System.tmp_dir!(), "rr-elsewhere-#{System.unique_integer([:positive])}")

      real_protos = Path.join(elsewhere, ".prototypes")
      uuid = Ash.UUID.generate()
      File.mkdir_p!(Path.join(real_protos, uuid))
      on_exit(fn -> File.rm_rf!(elsewhere) end)

      File.ln_s!(real_protos, Path.join(base, ".prototypes"))
      candidate = Path.join([base, ".prototypes", uuid])

      assert {:error, :symlinked_prototypes} = Sandbox.real_root(candidate)
    end
  end

  describe "resolver_opts/1" do
    test "non-sandbox context defaults project_dir to cwd, local_only false" do
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: nil})
      assert opts[:project_dir] == File.cwd!()
      assert opts[:local_only] == false
    end

    test "non-sandbox context passes a supplied project_dir + workspace_id through" do
      assert {:ok, opts} = Sandbox.resolver_opts(%{project_dir: "/some/dir", workspace_id: "ws"})
      assert opts[:project_dir] == "/some/dir"
      assert opts[:workspace_id] == "ws"
      assert opts[:local_only] == false
    end

    test "nil / non-map context is the non-sandbox default" do
      assert {:ok, opts} = Sandbox.resolver_opts(nil)
      assert opts[:project_dir] == File.cwd!()
      assert opts[:local_only] == false
    end

    test "sandbox context with a valid .prototypes root sets local_only true", %{base: base} do
      {:ok, %{dir: proto}} = Sandbox.create_prototype_dir(base)

      assert {:ok, opts} = Sandbox.resolver_opts(%{sandbox: :prototype, project_dir: proto})
      assert opts[:project_dir] == proto
      assert opts[:local_only] == true
    end

    test "sandbox context with no project_dir fails closed" do
      assert {:error, message} = Sandbox.resolver_opts(%{sandbox: :prototype})
      assert message =~ "sketch sandbox scope missing"
    end

    test "sandbox context with a non-.prototypes project_dir fails closed", %{base: base} do
      assert {:error, message} = Sandbox.resolver_opts(%{sandbox: :prototype, project_dir: base})
      assert message =~ "sketch sandbox scope invalid"
    end
  end
end
