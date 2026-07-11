defmodule JidoClaw.Orchestration.Verify.OsCmdRunnerTest do
  @moduledoc """
  Integration tests for the real check runner + git seam over scratch repos
  and tiny scripts — the ONLY verify file that spawns subprocesses (composer
  tests stay on the hermetic stub; nothing here runs `mix` recursively).

  async-safe with a coupling constraint: this file funnels `diff_digest`
  through the VM-wide 2-slot `VerifyCaptureTaskSupervisor` but never asserts
  its capacity; it is the supervisor's ONLY async user, which holds only
  while `verify/git_test.exs` and `route_composer/verify_stage_test.exs`
  (which do assert capacity / mutate app env) stay `async: false`.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Orchestration.Verify.OsCmdRunner
  alias JidoClaw.Security.Redaction.Env

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_verify_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    init_repo!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp check(cmd, extra \\ %{}) do
    Map.merge(%{name: "check", cmd: cmd, env: %{}, timeout_ms: nil}, extra)
  end

  defp script!(dir, relative, body) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    relative
  end

  describe "exit codes" do
    test "captures 0 / 1 / 127 verbatim from a real script", %{dir: dir} do
      script!(dir, "scripts/exit0.sh", "echo ok\nexit 0\n")
      script!(dir, "scripts/exit1.sh", "echo red\nexit 1\n")
      script!(dir, "scripts/exit127.sh", "exit 127\n")

      assert {0, "ok"} = OsCmdRunner.run(check(["./scripts/exit0.sh"]), dir)
      assert {1, "red"} = OsCmdRunner.run(check(["./scripts/exit1.sh"]), dir)
      assert {127, ""} = OsCmdRunner.run(check(["./scripts/exit127.sh"]), dir)
    end
  end

  describe "argv0 resolution (execvp-style, pre-spawn)" do
    test "an unresolvable bare argv0 is missing_tool-shaped 127 without spawning", %{dir: dir} do
      assert {127, tail} = OsCmdRunner.run(check(["definitely-not-a-real-binary-xyz"]), dir)
      assert tail =~ "command not found: definitely-not-a-real-binary-xyz"
    end

    test "a relative script argv0 resolves against the check cwd and RUNS", %{dir: dir} do
      script!(dir, "scripts/verify.sh", "echo ran-from-repo\nexit 0\n")

      assert {0, "ran-from-repo"} = OsCmdRunner.run(check(["./scripts/verify.sh"]), dir)
    end

    test "a missing relative script is missing_tool-shaped 127", %{dir: dir} do
      assert {127, tail} = OsCmdRunner.run(check(["./scripts/absent.sh"]), dir)
      assert tail =~ "command not found: ./scripts/absent.sh"
    end

    test "a bare argv0 findable only via the check's env PATH override resolves and runs",
         %{dir: dir} do
      bin_dir = Path.join(dir, "toolbin")
      script!(dir, "toolbin/myverifier", "echo via-override\nexit 0\n")

      # Without the override the tool is invisible (not on the parent PATH)…
      assert {127, _tail} = OsCmdRunner.run(check(["myverifier"]), dir)

      # …with the check env PATH override it resolves against the EFFECTIVE
      # child PATH (System.find_executable would only see the parent's).
      assert {0, "via-override"} =
               OsCmdRunner.run(check(["myverifier"], %{env: %{"PATH" => bin_dir}}), dir)
    end
  end

  describe "timeout + redaction" do
    test "a check outliving its timeout maps to the 124 sentinel with the config-lever hint",
         %{dir: dir} do
      script!(dir, "scripts/slow.sh", "sleep 5\n")

      assert {124, tail} =
               OsCmdRunner.run(check(["./scripts/slow.sh"], %{timeout_ms: 100}), dir)

      assert tail =~ "timed out"
      assert tail =~ "timeout_ms"
    end

    test "a fake secret in the output never reaches the tail (redact-before-tail)", %{dir: dir} do
      script!(
        dir,
        "scripts/leaky.sh",
        "echo token sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nexit 1\n"
      )

      assert {1, tail} = OsCmdRunner.run(check(["./scripts/leaky.sh"]), dir)
      refute tail =~ "sk-ant-"
      assert tail =~ "REDACTED"
    end
  end

  describe "tamper-during-verify against a real repo (end-to-end build_result)" do
    test "a check that edits a tracked file trips working_tree_mutation",
         %{dir: dir} do
      File.write!(Path.join(dir, "tracked.txt"), "v1\n")
      commit_all!(dir, "seed")
      tamper = script!(dir, "scripts/tamper.sh", "echo v2 > tracked.txt\nexit 0\n")
      commit_all!(dir, "add script")

      envelope =
        Verify.build_result(
          [check([Path.join(".", tamper)])],
          repo: dir,
          runner: &OsCmdRunner.run/2,
          porcelain: &Verify.Git.porcelain/1,
          head: &Verify.Git.head/1,
          diff_digest: &Verify.Git.diff_digest/1
        )

      assert envelope.tampered
      assert Enum.any?(envelope.failures, &(&1.kind == "working_tree_mutation"))
    end

    test "a check that creates an untracked artifact trips working_tree_mutation",
         %{dir: dir} do
      artifact =
        script!(dir, "scripts/artifact.sh", "echo generated > verify-output.tmp\nexit 0\n")

      commit_all!(dir, "add artifact-producing check")

      envelope =
        Verify.build_result(
          [check([Path.join(".", artifact)])],
          repo: dir,
          runner: &OsCmdRunner.run/2,
          porcelain: &Verify.Git.porcelain/1,
          head: &Verify.Git.head/1,
          diff_digest: &Verify.Git.diff_digest/1
        )

      assert envelope.tampered
      refute envelope.inconclusive
      assert Enum.any?(envelope.failures, &(&1.kind == "working_tree_mutation"))
    end

    test "a check that commits mid-verify trips head_moved", %{dir: dir} do
      File.write!(Path.join(dir, "tracked.txt"), "v1\n")
      commit_all!(dir, "seed")

      covert =
        script!(
          dir,
          "scripts/commit.sh",
          "echo v2 > tracked.txt\ngit add -A >/dev/null 2>&1\n" <>
            "git -c user.email=t@e -c user.name=t commit -qm cover-up >/dev/null 2>&1\nexit 0\n"
        )

      commit_all!(dir, "add script")

      envelope =
        Verify.build_result(
          [check([Path.join(".", covert)])],
          repo: dir,
          runner: &OsCmdRunner.run/2,
          porcelain: &Verify.Git.porcelain/1,
          head: &Verify.Git.head/1,
          diff_digest: &Verify.Git.diff_digest/1
        )

      assert envelope.tampered
      assert Enum.any?(envelope.failures, &(&1.kind == "head_moved"))
    end

    test "a check that edits an already-untracked file trips working-tree tamper", %{dir: dir} do
      File.write!(Path.join(dir, "tracked.txt"), "v1\n")
      tamper = script!(dir, "scripts/tamper-untracked.sh", "echo after > input.txt\nexit 0\n")
      commit_all!(dir, "seed")
      File.write!(Path.join(dir, "input.txt"), "before\n")

      envelope =
        Verify.build_result(
          [check([Path.join(".", tamper)])],
          repo: dir,
          runner: &OsCmdRunner.run/2,
          porcelain: &Verify.Git.porcelain/1,
          head: &Verify.Git.head/1,
          diff_digest: &Verify.Git.diff_digest/1
        )

      assert envelope.tampered
      assert Enum.any?(envelope.failures, &(&1.kind == "working_tree_mutation"))
    end
  end

  describe "Verify.Git captures" do
    test "head/porcelain/diff_digest read a real repo and nil out on a non-repo", %{dir: dir} do
      File.write!(Path.join(dir, "tracked.txt"), "v1\n")
      commit_all!(dir, "seed")

      assert Verify.Git.head(dir) =~ ~r/^[0-9a-f]{40}$/
      assert Verify.Git.porcelain(dir) == ""
      clean_digest = Verify.Git.diff_digest(dir)
      assert clean_digest =~ ~r/^[0-9a-f]{64}$/

      # A tracked edit changes the digest AND the porcelain.
      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      assert Verify.Git.porcelain(dir) =~ "tracked.txt"
      assert Verify.Git.diff_digest(dir) != clean_digest

      # Nonignored untracked content is part of both captures too.
      tracked_edit_digest = Verify.Git.diff_digest(dir)
      File.write!(Path.join(dir, "untracked.txt"), "one\n")
      assert Verify.Git.porcelain(dir) =~ "untracked.txt"
      assert Verify.Git.diff_digest(dir) != tracked_edit_digest

      non_repo =
        Path.join(System.tmp_dir!(), "jido_not_a_repo_#{System.unique_integer([:positive])}")

      File.mkdir_p!(non_repo)
      on_exit(fn -> File.rm_rf!(non_repo) end)

      assert Verify.Git.head(non_repo) == nil
      assert Verify.Git.porcelain(non_repo) == nil
      assert Verify.Git.diff_digest(non_repo) == nil
    end
  end

  defp init_repo!(dir) do
    assert {_output, 0} =
             System.cmd("git", ["init"],
               cd: dir,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    for args <- [
          ["config", "user.email", "test@example.com"],
          ["config", "user.name", "Test User"],
          ["config", "commit.gpgsign", "false"]
        ] do
      assert {"", 0} = System.cmd("git", args, cd: dir, env: Env.scrubbed_cmd_env())
    end
  end

  defp commit_all!(dir, message) do
    assert {_out, 0} =
             System.cmd("git", ["add", "-A"],
               cd: dir,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )

    assert {_out, 0} =
             System.cmd("git", ["commit", "-qm", message],
               cd: dir,
               stderr_to_stdout: true,
               env: Env.scrubbed_cmd_env()
             )
  end
end
