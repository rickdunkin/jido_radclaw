defmodule JidoClaw.Orchestration.Verify.GitTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Orchestration.Verify.Git
  alias JidoClaw.Security.Redaction.Env

  @capture_supervisor JidoClaw.Orchestration.VerifyCaptureTaskSupervisor

  setup do
    root =
      Path.join(System.tmp_dir!(), "jido_verify_git_#{System.unique_integer([:positive])}")

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    init_repo!(repo)
    File.write!(Path.join(repo, "tracked.txt"), "tracked\n")
    commit_all!(repo, "seed")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, repo: repo}
  end

  test "porcelain and digest include an untracked file and a second status-stable edit", %{
    repo: repo
  } do
    clean_digest = Git.diff_digest(repo)
    path = Path.join(repo, "new.txt")

    File.write!(path, "one\n")
    first_porcelain = Git.porcelain(repo)
    first_digest = Git.diff_digest(repo)

    assert first_porcelain == "?? new.txt\n"
    assert first_digest != clean_digest

    File.write!(path, "two\n")

    assert Git.porcelain(repo) == first_porcelain
    assert Git.diff_digest(repo) != first_digest

    File.rm!(path)
    assert Git.porcelain(repo) == ""
    assert Git.diff_digest(repo) == clean_digest
  end

  test "rename, type, and executable-mode transitions all change the digest", %{repo: repo} do
    source = Path.join(repo, "source.txt")
    renamed = Path.join(repo, "renamed.txt")
    File.write!(source, "same bytes\n")
    source_digest = Git.diff_digest(repo)

    assert :ok = File.rename(source, renamed)
    renamed_digest = Git.diff_digest(repo)
    assert renamed_digest != source_digest

    File.chmod!(renamed, 0o755)
    executable_digest = Git.diff_digest(repo)
    assert executable_digest != renamed_digest

    File.rm!(renamed)
    File.ln_s!("same bytes\n", renamed)
    symlink_digest = Git.diff_digest(repo)
    assert symlink_digest != executable_digest

    File.rm!(renamed)
    File.write!(renamed, "same bytes\n")
    assert Git.diff_digest(repo) != symlink_digest
  end

  test "exact path participates in a path fingerprint", %{repo: repo} do
    File.write!(Path.join(repo, "a.txt"), "same\n")
    File.write!(Path.join(repo, "b.txt"), "same\n")

    a = Git.path_fingerprint(repo, "a.txt")
    b = Git.path_fingerprint(repo, "b.txt")

    assert a =~ ~r/^[0-9a-f]{64}$/
    assert b =~ ~r/^[0-9a-f]{64}$/
    assert a != b
  end

  test "ignored files affect neither porcelain nor the digest", %{repo: repo} do
    File.write!(Path.join(repo, ".gitignore"), "ignored/\n")
    commit_all!(repo, "ignore artifacts")
    before_digest = Git.diff_digest(repo)

    File.mkdir_p!(Path.join(repo, "ignored"))
    File.write!(Path.join(repo, "ignored/generated.bin"), :binary.copy(<<1>>, 2_048))

    assert Git.porcelain(repo) == ""
    assert Git.diff_digest(repo) == before_digest
  end

  test "symlinks hash link text and never external target content", %{root: root, repo: repo} do
    outside_a = Path.join(root, "outside-a.txt")
    outside_b = Path.join(root, "outside-b.txt")
    File.write!(outside_a, "outside one\n")
    File.write!(outside_b, "outside two\n")

    link = Path.join(repo, "link.txt")
    File.ln_s!("../outside-a.txt", link)

    first_path_digest = Git.path_fingerprint(repo, "link.txt")
    first_tree_digest = Git.diff_digest(repo)

    File.write!(outside_a, "mutated outside content\n")
    assert Git.path_fingerprint(repo, "link.txt") == first_path_digest
    assert Git.diff_digest(repo) == first_tree_digest

    File.rm!(link)
    File.ln_s!("../outside-b.txt", link)
    assert Git.path_fingerprint(repo, "link.txt") != first_path_digest
    assert Git.diff_digest(repo) != first_tree_digest
  end

  test "a symlink in a parent component cannot escape the repo", %{root: root, repo: repo} do
    outside = Path.join(root, "outside-dir")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret\n")
    File.ln_s!("../outside-dir", Path.join(repo, "linked-dir"))

    assert Git.path_fingerprint(repo, "linked-dir/secret.txt") == nil
  end

  test "file-count, aggregate-content, and path bounds fail capture closed", %{repo: repo} do
    File.write!(Path.join(repo, "one.txt"), "1234")
    File.write!(Path.join(repo, "two.txt"), "5678")

    assert Git.diff_digest(repo, max_files: 1) == nil
    assert Git.diff_digest(repo, max_content_bytes: 7) == nil
    assert Git.diff_digest(repo, max_path_bytes: 3) == nil
    assert Git.path_fingerprint(repo, "one.txt", max_content_bytes: 3) == nil
    assert Git.path_fingerprint(repo, "one.txt", max_path_bytes: 3) == nil

    assert Git.fingerprint_limits() == %{
             max_files: 1_000,
             max_content_bytes: 10 * 1024 * 1024,
             max_path_bytes: 4_096
           }
  end

  test "invalid paths, unsupported types, read failures, and lstat races return nil", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "race.txt"), "before")

    assert Git.path_fingerprint(repo, "/absolute") == nil
    assert Git.path_fingerprint(repo, "../escape") == nil
    assert Git.path_fingerprint(repo, "bad\0path") == nil
    assert Git.path_fingerprint(repo, ".") == nil

    race_hook = fn path, _stat ->
      File.rm!(path)
      File.write!(path, "replacement with a new identity")
    end

    assert Git.path_fingerprint(repo, "race.txt", capture_hook: race_hook) == nil

    File.write!(Path.join(repo, "vanish.txt"), "before")
    delete_hook = fn path, _stat -> File.rm!(path) end
    assert Git.path_fingerprint(repo, "vanish.txt", capture_hook: delete_hook) == nil

    fifo = Path.join(repo, "special.fifo")
    assert {"", 0} = System.cmd("mkfifo", [fifo], env: Env.scrubbed_cmd_env())
    assert Git.path_fingerprint(repo, "special.fifo") == nil
  end

  test "a regular-to-FIFO or symlink-to-FIFO swap returns within the capture deadline", %{
    repo: repo
  } do
    direct = Path.join(repo, "direct-race.txt")
    linked = Path.join(repo, "linked-race.txt")
    target = Path.join(repo, "linked-target.fifo")
    File.write!(direct, "before")
    File.write!(linked, "before")

    on_exit(fn ->
      release_fifo(direct)
      release_fifo(target)
    end)

    direct_hook = fn path, _stat ->
      File.rm!(path)
      mkfifo!(path)
    end

    started = System.monotonic_time(:millisecond)

    assert Git.path_fingerprint(repo, "direct-race.txt",
             capture_hook: direct_hook,
             capture_timeout_ms: 75
           ) == nil

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert eventually(fn -> Task.Supervisor.children(@capture_supervisor) != [] end)
    assert :ok = release_fifo(direct)
    assert eventually(fn -> Task.Supervisor.children(@capture_supervisor) == [] end)
    File.rm!(direct)

    linked_hook = fn path, _stat ->
      File.rm!(path)
      mkfifo!(target)
      File.ln_s!(Path.basename(target), path)
    end

    assert Git.path_fingerprint(repo, "linked-race.txt",
             capture_hook: linked_hook,
             capture_timeout_ms: 75
           ) == nil

    assert eventually(fn -> Task.Supervisor.children(@capture_supervisor) != [] end)
    assert :ok = release_fifo(target)
    assert eventually(fn -> Task.Supervisor.children(@capture_supervisor) == [] end)
    File.rm!(linked)
    File.rm!(target)
  end

  test "diff capture is deadline-bounded and timed-out tasks consume the global capacity", %{
    repo: repo
  } do
    max_children = Git.capture_concurrency()

    paths =
      for index <- 1..max_children do
        path = Path.join(repo, "capacity-#{index}.txt")
        File.write!(path, "before")
        path
      end

    on_exit(fn -> Enum.each(paths, &release_fifo/1) end)

    for path <- paths do
      relative = Path.basename(path)

      hook = fn full_path, _stat ->
        File.rm!(full_path)
        mkfifo!(full_path)
      end

      assert Git.path_fingerprint(repo, relative,
               capture_hook: hook,
               capture_timeout_ms: 50
             ) == nil
    end

    assert eventually(fn ->
             length(Task.Supervisor.children(@capture_supervisor)) == max_children
           end)

    extra = Path.join(repo, "capacity-extra.txt")
    File.write!(extra, "before")
    parent = self()
    extra_hook = fn _path, _stat -> send(parent, :capacity_extra_started) end

    assert Git.diff_digest(repo,
             capture_hook: extra_hook,
             capture_timeout_ms: 50
           ) == nil

    refute_receive :capacity_extra_started, 100

    Enum.each(paths, fn path ->
      assert :ok = release_fifo(path)
      File.rm!(path)
    end)

    assert eventually(fn -> Task.Supervisor.children(@capture_supervisor) == [] end)
  end

  test "a same-inode same-size write between bounded reads refuses a torn fingerprint", %{
    repo: repo
  } do
    path = Path.join(repo, "same-inode.txt")
    File.write!(path, "before")
    inode = File.stat!(path).inode

    between_read_hook = fn full_path, _opened_stat ->
      # Truncate-and-rewrite preserves the directory entry/inode and final
      # size. On filesystems whose POSIX timestamps have one-second resolution,
      # metadata alone cannot distinguish this race; the repeated hash must.
      File.write!(full_path, "after!")
    end

    assert Git.path_fingerprint(repo, "same-inode.txt", between_read_hook: between_read_hook) ==
             nil

    assert File.stat!(path).inode == inode
    assert File.read!(path) == "after!"
  end

  test "findings-only callers may omit unavailable paths without relaxing global bounds", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "good.txt"), "good")
    File.mkdir_p!(Path.join(repo, "directory"))

    assert %{"good.txt" => digest} =
             Git.path_fingerprints(repo, ["good.txt", "directory"], on_error: :omit)

    assert digest =~ ~r/^[0-9a-f]{64}$/

    assert Git.path_fingerprints(repo, ["good.txt", "directory"], on_error: :fail) == nil
    assert Git.path_fingerprints(repo, ["good.txt", "directory"], max_files: 1) == nil
  end

  test "path collection halts at max_files + 1 before enumerating the full input", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "one.txt"), "one")
    File.write!(Path.join(repo, "two.txt"), "two")
    File.write!(Path.join(repo, "three.txt"), "three")

    paths =
      ["one.txt", "two.txt", "three.txt", "must-not-be-enumerated"]
      |> Stream.with_index(1)
      |> Stream.map(fn
        {_path, 4} -> raise "collector traversed past the refusal point"
        {path, _index} -> path
      end)

    assert Git.path_fingerprints(repo, paths, max_files: 2) == nil
  end

  test "sealed mode rejects an untracked file before executing checks", %{repo: repo} do
    File.write!(Path.join(repo, "untracked.txt"), "input\n")
    parent = self()

    envelope =
      Verify.build_result(
        [%{name: "must-not-run", cmd: ["false"], env: %{}, timeout_ms: nil}],
        repo: repo,
        sealed_head: Git.head(repo),
        runner: fn _check, _repo ->
          send(parent, :check_ran)
          {0, ""}
        end,
        porcelain: &Git.porcelain/1,
        head: &Git.head/1,
        diff_digest: &Git.diff_digest/1
      )

    assert envelope.tampered
    assert [%{kind: "uncommitted_state"}] = envelope.failures
    refute_receive :check_ran
  end

  defp init_repo!(repo) do
    assert {_output, 0} =
             System.cmd("git", ["init"],
               cd: repo,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    for args <- [
          ["config", "user.email", "test@example.com"],
          ["config", "user.name", "Test User"],
          ["config", "commit.gpgsign", "false"]
        ] do
      assert {"", 0} = System.cmd("git", args, cd: repo, env: Env.scrubbed_cmd_env())
    end
  end

  defp commit_all!(repo, message) do
    assert {_output, 0} =
             System.cmd("git", ["add", "-A"],
               cd: repo,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    assert {_output, 0} =
             System.cmd("git", ["commit", "-qm", message],
               cd: repo,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )
  end

  defp mkfifo!(path) do
    assert {"", 0} = System.cmd("mkfifo", [path], env: Env.scrubbed_cmd_env())
    :ok
  end

  # Use an OS child for the writer so releasing a blocked dirty-I/O open never
  # needs another BEAM file-I/O worker. Safe to call when no reader exists: the
  # port is closed after the bounded wait.
  defp release_fifo(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type in [:other, :symlink] ->
        writer =
          Port.open(
            {:spawn_executable, System.find_executable("sh")},
            [:binary, :exit_status, args: ["-c", "printf x > \"$1\"", "sh", path]]
          )

        receive do
          {^writer, {:exit_status, 0}} -> :ok
          {^writer, {:exit_status, status}} -> {:error, {:writer_exit, status}}
        after
          1_000 ->
            Port.close(writer)
            {:error, :writer_timeout}
        end

      _missing_or_regular ->
        :ok
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end
end
