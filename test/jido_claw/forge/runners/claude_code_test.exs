defmodule JidoClaw.Forge.Runners.ClaudeCodeTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Forge.Runners.ClaudeCode`. Mirrors the
  Codex runner test shape — exercises `init/2` against a stub sandbox
  with `:claude_home_dir` and `:forge_home` injected via app env so
  filesystem effects stay confined to tmp dirs.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Forge.Runners.ClaudeCode
  alias JidoClaw.Test.StubSandbox

  setup do
    prev_claude = Application.get_env(:jido_claw, :claude_home_dir)
    prev_forge = Application.get_env(:jido_claw, :forge_home)
    prev_keychain = Application.get_env(:jido_claw, :claude_keychain_reader)

    # Deterministic keychain MISS by default: on a darwin dev machine the
    # real reader could find the operator's actual Keychain credential and
    # flip the :no_credentials paths green. Keychain-specific tests arm
    # their own fun.
    Application.put_env(:jido_claw, :claude_keychain_reader, fn -> :error end)

    on_exit(fn ->
      restore(:claude_home_dir, prev_claude)
      restore(:forge_home, prev_forge)
      restore(:claude_keychain_reader, prev_keychain)
    end)

    :ok
  end

  describe "init/2 — :no_credentials" do
    test "returns {:error, :no_credentials} when host claude dir is missing" do
      missing = Path.join(System.tmp_dir!(), "no_claude_#{:erlang.unique_integer([:positive])}")
      Application.put_env(:jido_claw, :claude_home_dir, missing)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      events = StubSandbox.events(client)
      refute Enum.any?(events, fn {kind, _} -> kind == :write end)
    end

    test "returns {:error, :no_credentials} when host dir exists but credentials.json is missing" do
      tmp = make_tmpdir!("claude_missing_creds")
      File.write!(Path.join(tmp, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, tmp)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = ClaudeCode.init(client, %{})

      on_exit(fn -> File.rm_rf(tmp) end)
    end
  end

  describe "init/2 — happy path" do
    setup do
      host = make_tmpdir!("claude_host")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "syncs ~/.claude into the sandbox and pins permissions settings",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, state} =
               ClaudeCode.init(client, %{
                 forge_home: forge_home,
                 prompt: "do consolidator work"
               })

      assert state.forge_home == forge_home
      assert state.model == "claude-sonnet-4-20250514"

      events = StubSandbox.events(client)

      mkdirs =
        for {:exec, cmd} <- events, String.starts_with?(cmd, "mkdir -p"), do: cmd

      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/.claude"))
      assert Enum.any?(mkdirs, &String.contains?(&1, "#{forge_home}/session"))

      # Default-off makes no pwd capture — resume machinery is armed-only.
      refute {:exec, "pwd"} in events

      sync_cmds =
        for {:exec, cmd} <- events, String.contains?(cmd, "base64 -d"), do: cmd

      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{forge_home}/.claude/credentials.json"))

      # credentials.json gets chmod 600
      assert Enum.any?(events, fn
               {:exec, cmd} -> cmd == "chmod 600 #{forge_home}/.claude/credentials.json"
               _ -> false
             end)

      # The pinned settings.json overwrites whatever the sync wrote.
      pinned = StubSandbox.file(client, "#{forge_home}/.claude/settings.json")
      assert pinned == ~s({"permissions":{"allow":["*"]}})

      # The redacted prompt was dropped at session/context.md.
      assert StubSandbox.file(client, "#{forge_home}/session/context.md") =~ "consolidator work"
    end
  end

  describe "run_iteration/3" do
    setup do
      host = make_tmpdir!("claude_host_run")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude_run")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, client, _sid} = StubSandbox.create()

      {:ok, state} =
        ClaudeCode.init(client, %{forge_home: forge_home, prompt: "do work"})

      {:ok, client: client, state: state}
    end

    test "every iteration is a FRESH -p session — never a resume/continue token (PR-3)",
         %{client: client, state: state} do
      # camus SKILL.md's fresh-session-per-round rule: each composer re-review
      # wave must re-read the CURRENT tree, never resume a stale session
      # (camus C3-1's intra-attempt resume probe is deliberately not ported).
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = ClaudeCode.run_iteration(client, state, [])

      ["claude" | args] = StubSandbox.last_run_args(client)

      assert List.first(args) == "-p"
      refute Enum.any?(args, &(&1 =~ "resume"))
      refute "--continue" in args
      refute "--session-id" in args
    end

    test "timeout → harness_timeout", %{client: client, state: state} do
      StubSandbox.program_run(client, {"", :timeout})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               ClaudeCode.run_iteration(client, state, [])
    end

    test "docker-manufactured timeout (exit 124) → harness_timeout", %{
      client: client,
      state: state
    } do
      # Docker maps a harness timeout to `{"timeout after \#{t}ms", 124}`, not the
      # `:timeout` atom HostShell uses. `Sandbox.run/4` normalizes that EXACT
      # tuple back to `:timeout`, so the runner classifies it as harness_timeout
      # rather than the generic "claude cli failed" it fell into before the fix.
      StubSandbox.program_run(client, {"timeout after 5000ms", 124})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               ClaudeCode.run_iteration(client, state, timeout: 5000)
    end
  end

  # Executor-seam PR-2 knobs. Defaults (covered above) preserve the
  # consolidator byte-for-byte; these pin the vendor-executor posture —
  # env/argv assertions, not just copied files (review finding P1b).
  describe "executor knobs (PR-2)" do
    setup do
      host = make_tmpdir!("claude_host_knobs")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), ~s({"host":"settings"}))
      File.write!(Path.join(host, "CLAUDE.md"), "# host claude md\n")
      File.mkdir_p!(Path.join(host, "skills"))
      File.write!(Path.join(host, "skills/host_skill.md"), "host skill\n")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude_knobs")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "config_sync: :auth_only builds an isolated CLAUDE_CONFIG_DIR — credentials only, minimal settings, env injected",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _state} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      config_dir = "#{forge_home}/.claude"

      # The isolation is the ENV, not the copied files (P1b): claude's whole
      # config universe becomes the per-run dir.
      assert StubSandbox.env(client) == %{"CLAUDE_CONFIG_DIR" => config_dir}

      exec_cmds = for {:exec, cmd} <- StubSandbox.events(client), do: cmd
      sync_cmds = Enum.filter(exec_cmds, &String.contains?(&1, "base64 -d"))

      # The credential lands at the DOTTED in-sandbox name (what in-VM Linux
      # claude reads under CLAUDE_CONFIG_DIR) through a CHECKED write whose
      # command chmods 600 in the same exec; the minimal settings.json rides
      # the same exec-based transport — and nothing else from the host dir
      # crosses (no settings/skills/CLAUDE.md sync).
      cred_cmd = Enum.find(sync_cmds, &String.contains?(&1, "#{config_dir}/.credentials.json"))
      assert cred_cmd
      assert cred_cmd =~ "chmod 600 #{config_dir}/.credentials.json"
      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      refute Enum.any?(exec_cmds, &String.contains?(&1, "CLAUDE.md"))
      refute Enum.any?(exec_cmds, &String.contains?(&1, "skills"))

      # The minimal settings body is exactly the exec-written "{}" — never the
      # allow-all pin, and never a jailed Sandbox.write_file (which records a
      # {:write, path} event / file entry on the stub).
      settings_cmd = Enum.find(sync_cmds, &String.contains?(&1, "#{config_dir}/settings.json"))
      assert settings_cmd =~ Base.encode64("{}")
      assert StubSandbox.file(client, "#{config_dir}/settings.json") == nil
    end

    test "config_sync: :auth_only fails closed when the checked credential write fails",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # Every exec fails; the unchecked mkdirs shrug, but the CHECKED
      # credential write must surface the failure — a session without its
      # credential must not start and drift into an opaque CLI failure.
      StubSandbox.program_exec(client, {"disk full", 1})

      assert {:error, {:checked_write_failed, dest, 1}} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert dest == "#{forge_home}/.claude/.credentials.json"
    end

    test "config_sync: :auth_only fails closed when the env inject is refused",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # A refused CLAUDE_CONFIG_DIR inject means claude would read the
      # operator's REAL ~/.claude — the unisolated session must not start.
      StubSandbox.program_inject_env(client, {:error, :inject_env_refused})

      assert {:error, {:config_isolation_failed, :inject_env_refused}} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})
    end

    test "access: :read_only pins the restricted flag set (no bypass flag); add_dirs land",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()
      repo_dir = Path.join(forge_home, "repo")

      {:ok, state} =
        ClaudeCode.init(client, %{
          forge_home: forge_home,
          config_sync: :auth_only,
          access: :read_only,
          allowed_mcp_tools: ["mcp__jido_deposit__submit_structured_output"],
          add_dirs: [repo_dir],
          mcp_config_path: "/tmp/deposit.json",
          prompt: "review it"
        })

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = ClaudeCode.run_iteration(client, state, [])

      ["claude" | args] = StubSandbox.last_run_args(client)

      assert args == [
               "-p",
               "review it",
               "--model",
               "claude-sonnet-4-20250514",
               "--tools",
               "Read,Glob,Grep",
               "--allowedTools",
               "Read,Glob,Grep,mcp__jido_deposit__submit_structured_output",
               "--permission-mode",
               "dontAsk",
               "--strict-mcp-config",
               "--output-format",
               "stream-json",
               "--verbose",
               "--max-turns",
               "200",
               "--add-dir",
               repo_dir,
               "--mcp-config",
               "/tmp/deposit.json"
             ]

      refute "--dangerously-skip-permissions" in args
    end
  end

  # Docker write build (Unit C): the shared credential source for
  # `config_sync: :auth_only` — dotted host file → legacy dotless file →
  # macOS Keychain (the `:claude_keychain_reader` seam), fail
  # `:no_credentials` when all three miss. Content-based: an empty source
  # falls through to the next.
  describe "shared credential source (:auth_only)" do
    setup do
      host = make_tmpdir!("claude_cred_source")
      Application.put_env(:jido_claw, :claude_home_dir, host)
      forge_home = make_tmpdir!("forge_home_cred_source")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home, config_dir: "#{forge_home}/.claude"}
    end

    defp cred_cmd(client, config_dir) do
      Enum.find_value(StubSandbox.events(client), fn
        {:exec, cmd} ->
          if String.contains?(cmd, "base64 -d") and
               String.contains?(cmd, "#{config_dir}/.credentials.json"),
             do: cmd

        _ ->
          nil
      end)
    end

    test "the dotted host file wins over the legacy dotless file",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, ".credentials.json"), ~s({"which":"dotted"}))
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      cmd = cred_cmd(client, config_dir)
      assert cmd =~ Base.encode64(~s({"which":"dotted"}))
      refute cmd =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "the legacy dotless file is used when no dotted file exists",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "the Keychain seam is consulted when no host file exists (darwin source); blob never lands on host disk",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      Application.put_env(:jido_claw, :claude_keychain_reader, fn ->
        {:ok, ~s({"which":"keychain"})}
      end)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"keychain"}))
      # The blob rides the exec transport only — never written to the host dir.
      refute File.exists?(Path.join(host, ".credentials.json"))
      refute File.exists?(Path.join(host, "credentials.json"))
    end

    test "an empty host file falls through (content-based resolution)",
         %{host: host, forge_home: forge_home, config_dir: config_dir} do
      File.write!(Path.join(host, ".credentials.json"), "")
      File.write!(Path.join(host, "credentials.json"), ~s({"which":"legacy"}))

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert cred_cmd(client, config_dir) =~ Base.encode64(~s({"which":"legacy"}))
    end

    test "all three sources missing ⇒ {:error, :no_credentials}, nothing written",
         %{forge_home: forge_home} do
      # setup arms the keychain seam to a deterministic miss.
      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})

      assert StubSandbox.events(client) == []
    end

    test "a keychain blob that is empty ⇒ {:error, :no_credentials}",
         %{forge_home: forge_home} do
      Application.put_env(:jido_claw, :claude_keychain_reader, fn -> {:ok, ""} end)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} =
               ClaudeCode.init(client, %{forge_home: forge_home, config_sync: :auth_only})
    end
  end

  # Native CLI session resume, claude side (MC1-1; PORT sign-off Q1:
  # client-minted `--session-id` pre-spawn). The CM2-3 sanitizer invariants
  # ride these as contract tests.
  describe "armed modes (resume: :armed)" do
    setup do
      host = make_tmpdir!("claude_host_armed")
      File.write!(Path.join(host, "credentials.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "settings.json"), "{}")
      Application.put_env(:jido_claw, :claude_home_dir, host)

      forge_home = make_tmpdir!("forge_home_claude_armed")
      prev_writer = Application.get_env(:jido_claw, :forge_resume_writer)

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
        restore(:forge_resume_writer, prev_writer)
      end)

      {:ok, client, _sid} = StubSandbox.create()
      StubSandbox.program_exec(client, {"/sandbox/work\n", 0})

      {:ok, state} =
        ClaudeCode.init(client, %{forge_home: forge_home, prompt: "do work", resume: :armed})

      {:ok, client: client, state: state, forge_home: forge_home}
    end

    defp armed_uuid!(args) do
      assert idx = Enum.find_index(args, &(&1 == "--session-id"))
      uuid = Enum.at(args, idx + 1)
      assert {:ok, _} = Ecto.UUID.cast(uuid)
      uuid
    end

    test "armed init captures pwd as the workdir (only when armed)", %{state: state} do
      assert state.resume_cwd == "/sandbox/work"
      assert state.resume.workdir == "/sandbox/work"
      assert state.resume.status == :unanchored
    end

    test "fresh-armed adds --session-id with a minted UUID; anchor persists PRE-spawn",
         %{client: client, state: state} do
      test_pid = self()

      Application.put_env(:jido_claw, :forge_resume_writer, fn sid, rs, token ->
        # Snapshot the run history AT write time: pre-spawn means no CLI
        # invocation has happened yet.
        send(test_pid, {:anchor_write, sid, rs, token, StubSandbox.run_args_history(client)})
        :ok
      end)

      StubSandbox.program_run(client, {"", 0})

      assert {:ok, result} =
               ClaudeCode.run_iteration(client, state,
                 forge_session_id: "forge-sess-1",
                 incarnation_token: "tok-1",
                 incarnation_epoch: 3
               )

      ["claude" | args] = StubSandbox.last_run_args(client)
      uuid = armed_uuid!(args)

      assert_received {:anchor_write, "forge-sess-1", %JidoClaw.Forge.ResumeState{} = written,
                       "tok-1", runs_at_write_time}

      assert runs_at_write_time == []
      assert written.status == :anchored
      assert written.session_id == uuid
      assert written.ownership == :client
      assert written.epoch == 3
      assert written.revision == 1

      # The full prompt rides a fresh-armed turn.
      assert Enum.take(args, 2) == ["-p", "do work"]
      refute "--resume" in args
      refute "--continue" in args

      # metadata.state carries the anchored resume state to the harness.
      assert %{state: %{resume: rs}} = result.metadata
      assert rs.status == :anchored
      assert rs.session_id == uuid
    end

    test "no claimed session/token threaded → the pre-spawn persist skips cleanly",
         %{client: client, state: state} do
      test_pid = self()

      Application.put_env(:jido_claw, :forge_resume_writer, fn sid, rs, token ->
        send(test_pid, {:anchor_write, sid, rs, token})
        :ok
      end)

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, result} = ClaudeCode.run_iteration(client, state, [])

      refute_received {:anchor_write, _, _, _}
      # The turn still armed and returned its state.
      assert %{state: %{resume: %{status: :anchored}}} = result.metadata
    end

    test "continuation uses --resume with a GUIDANCE-ONLY prompt — the task never rides again",
         %{client: client, state: state} do
      StubSandbox.program_run_sequence(client, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      state2 = first.metadata.state
      anchor_id = state2.resume.session_id

      {:ok, second} =
        ClaudeCode.run_iteration(client, state2, guidance: "address the review findings")

      [_first_args, ["claude" | args2]] = StubSandbox.run_args_history(client)

      assert Enum.take(args2, 2) == ["-p", "address the review findings"]
      assert ["--resume", ^anchor_id] = Enum.take(Enum.drop_while(args2, &(&1 != "--resume")), 2)
      refute "--session-id" in args2
      refute "--continue" in args2
      refute Enum.any?(args2, &(&1 =~ "do work"))

      # The continued turn records source :resume in its returned state.
      assert second.metadata.state.resume.session_start_source == :resume
      assert second.metadata.state.resume.session_id == anchor_id
    end

    test "a continuation turn with no guidance never falls back to the original task",
         %{client: client, state: state} do
      StubSandbox.program_run_sequence(client, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      {:ok, _second} = ClaudeCode.run_iteration(client, first.metadata.state, [])

      [_, ["claude" | args2]] = StubSandbox.run_args_history(client)

      assert Enum.take(args2, 2) == ["-p", "Continue."]
      refute Enum.any?(args2, &(&1 =~ "do work"))
    end

    test "CM2-3 strengthened: continuation given BOTH prompt: and guidance: uses the guidance",
         %{client: client, state: state} do
      StubSandbox.program_run_sequence(client, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client, state, [])

      {:ok, _second} =
        ClaudeCode.run_iteration(client, first.metadata.state,
          prompt: "do work",
          guidance: "just the guidance"
        )

      [_, ["claude" | args2]] = StubSandbox.run_args_history(client)

      # Even a confused caller passing prompt: task to an anchored session
      # cannot put the task on a continuation argv.
      assert Enum.take(args2, 2) == ["-p", "just the guidance"]
      refute Enum.any?(args2, &(&1 =~ "do work"))
    end

    test "prevention pin: fresh-armed ignores guidance: and sends state.prompt",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})

      # Unanchored state resolves fresh-armed; the caller's continuation
      # guidance must be structurally ignored in favor of the full task.
      {:ok, _result} =
        ClaudeCode.run_iteration(client, state, guidance: "Continue the consolidation pass")

      ["claude" | args] = StubSandbox.last_run_args(client)

      assert Enum.take(args, 2) == ["-p", "do work"]
      refute Enum.any?(args, &(&1 =~ "Continue the consolidation pass"))
    end

    test "continuation delivers parked inflight text — beats guidance:, consumed at take",
         %{client: client, state: state} do
      StubSandbox.program_run_sequence(client, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client, state, [])

      parked =
        update_in(first.metadata.state, [:resume], fn rs ->
          {:ok, rs} = ResumeState.put_guidance(rs, "the parked answer")
          {:ok, rs} = ResumeState.guidance_inflight(rs)
          rs
        end)

      {:ok, second} = ClaudeCode.run_iteration(client, parked, guidance: "ignored nudge")

      [_, ["claude" | args2]] = StubSandbox.run_args_history(client)

      assert Enum.take(args2, 2) == ["-p", "the parked answer"]
      # Consumed at take: the answer rides exactly one argv, never resent.
      assert second.metadata.state.resume.pending_guidance == %{status: :consumed, text: nil}
    end

    test "fresh-armed reverts inflight guidance to pending and sends the full task",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})

      parked =
        update_in(state, [:resume], fn rs ->
          {:ok, rs} = ResumeState.put_guidance(rs, "the parked answer")
          {:ok, rs} = ResumeState.guidance_inflight(rs)
          rs
        end)

      rev_before = parked.resume.guidance_rev

      # Unanchored → fresh-armed: the turn provably never places the answer
      # on an argv, so it reverts :pending for the next continuation.
      {:ok, result} = ClaudeCode.run_iteration(client, parked, [])

      ["claude" | args] = StubSandbox.last_run_args(client)
      assert Enum.take(args, 2) == ["-p", "do work"]
      refute Enum.any?(args, &(&1 =~ "the parked answer"))

      assert result.metadata.state.resume.pending_guidance ==
               %{status: :pending, text: "the parked answer"}

      assert result.metadata.state.resume.guidance_rev > rev_before
    end

    test "CM2-3: permission flags derive only from access — never from anchor state",
         %{client: client, forge_home: forge_home} do
      {:ok, client2, _sid} = StubSandbox.create()
      _ = client
      StubSandbox.program_exec(client2, {"/sandbox/work\n", 0})

      {:ok, state} =
        ClaudeCode.init(client2, %{
          forge_home: forge_home,
          prompt: "review",
          resume: :armed,
          access: :read_only,
          allowed_mcp_tools: ["mcp__jido__deposit"]
        })

      StubSandbox.program_run_sequence(client2, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client2, state, [])
      {:ok, _} = ClaudeCode.run_iteration(client2, first.metadata.state, prompt: "go on")

      for ["claude" | args] <- StubSandbox.run_args_history(client2) do
        assert "--tools" in args
        assert "--permission-mode" in args
        refute "--dangerously-skip-permissions" in args
      end
    end

    test "resume selectors never combine; model and effort are rebuilt fresh each turn",
         %{client: client, state: state} do
      StubSandbox.program_run_sequence(client, [{"", 0}, {"", 0}])

      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      {:ok, _} = ClaudeCode.run_iteration(client, first.metadata.state, prompt: "more")

      [["claude" | args1], ["claude" | args2]] = StubSandbox.run_args_history(client)

      assert "--session-id" in args1
      refute "--resume" in args1
      assert "--resume" in args2
      refute "--session-id" in args2

      for args <- [args1, args2] do
        assert ["--model", "claude-sonnet-4-20250514"] =
                 Enum.take(Enum.drop_while(args, &(&1 != "--model")), 2)
      end
    end

    test "id-verify mismatch drops the anchor loudly — and never retries",
         %{client: client, state: state} do
      foreign =
        ~s({"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"})

      StubSandbox.program_run(client, {foreign <> "\n", 0})

      {:ok, result} = ClaudeCode.run_iteration(client, state, [])

      # Exactly one CLI invocation — runners never auto-retry.
      assert [_only_one] = StubSandbox.run_args_history(client)

      assert result.metadata.state.resume.status == :unanchored
      assert result.metadata.state.resume.session_id == nil
    end

    test "a matching echoed session id keeps the anchor", %{client: client, state: state} do
      test_pid = self()

      Application.put_env(:jido_claw, :forge_resume_writer, fn _sid, rs, _token ->
        send(test_pid, {:written, rs.session_id})
        :ok
      end)

      # Two-phase: capture the minted id from the pre-spawn write, then feed
      # it back as the CLI echo on a SECOND fresh-armed turn... simpler: run
      # once unverified, then echo THAT anchor on the continuation.
      StubSandbox.program_run(client, {"", 0})

      {:ok, first} =
        ClaudeCode.run_iteration(client, state,
          forge_session_id: "s",
          incarnation_token: "t"
        )

      anchor_id = first.metadata.state.resume.session_id
      echo = ~s({"type":"system","subtype":"init","session_id":"#{anchor_id}"})
      StubSandbox.program_run(client, {echo <> "\n", 0})

      {:ok, second} = ClaudeCode.run_iteration(client, first.metadata.state, prompt: "go")

      assert second.metadata.state.resume.status == :anchored
      assert second.metadata.state.resume.session_id == anchor_id
    end

    test "a continuation echoing a FOREIGN session id drops the anchor",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      {:ok, first} = ClaudeCode.run_iteration(client, state, [])

      foreign =
        ~s({"type":"system","subtype":"init","session_id":"22222222-2222-2222-2222-222222222222"})

      StubSandbox.program_run(client, {foreign <> "\n", 0})

      {:ok, second} = ClaudeCode.run_iteration(client, first.metadata.state, prompt: "go")

      assert second.metadata.state.resume.status == :unanchored
    end

    test "timeout terminals still return metadata.state — the pre-spawn mint reaches the harness",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", :timeout})

      {:ok, result} = ClaudeCode.run_iteration(client, state, [])

      assert result.status == :error
      assert result.error == "harness_timeout"
      assert result.metadata.state.resume.status == :anchored
      assert is_binary(result.metadata.state.resume.session_id)

      # A timeout is retryable and never poisons the anchor.
      assert result.metadata.error_details == %{
               failure_kind: :stalled_wall_clock,
               retry: true
             }
    end

    test "a rejected continuation poisons the anchor, tags resume_rejected, emits loudly — no retry",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      anchor_id = first.metadata.state.resume.session_id

      forge_sid = "claude_reject_#{:erlang.unique_integer([:positive])}"
      :ok = ForgePubSub.subscribe(forge_sid)

      # The verified live rejection shape: bare first line + JSON result line.
      rejection =
        "No conversation found with session ID: #{anchor_id}\n" <>
          ~s({"type":"result","subtype":"error_during_execution","is_error":true})

      StubSandbox.program_run(client, {rejection, 1})

      {:ok, second} =
        ClaudeCode.run_iteration(client, first.metadata.state,
          prompt: "go on",
          forge_session_id: forge_sid
        )

      # Classified in-runner; the driver's retry authorization reads these.
      assert second.metadata.error_details == %{
               failure_kind: :agent_session_poisoned,
               retry: true,
               resume_rejected: true
             }

      assert second.error =~ "No conversation found"
      assert second.metadata.state.resume.status == :poisoned
      assert second.metadata.state.resume.session_id == anchor_id

      # Exactly two CLI invocations total — the runner never auto-retried.
      assert [_, _] = StubSandbox.run_args_history(client)

      # The loud channel fired BEFORE the attempt returned.
      assert_receive {:resume_failed, payload}
      assert payload.kind == :agent_session_poisoned
      assert payload.resume_rejected == true
      assert payload.mode == :continuation
      assert payload.runner == :claude_code

      # And the poisoned id is never reused: the next turn rearms fresh.
      StubSandbox.program_run(client, {"", 0})
      {:ok, third} = ClaudeCode.run_iteration(client, second.metadata.state, [])

      assert third.metadata.state.resume.status == :anchored
      assert third.metadata.state.resume.session_id != anchor_id
    end

    test "a short bare-line failure tags {:fallback_marker, _} and poisons the anchor",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"Something went wrong. Please try again later.", 1})

      {:ok, result} = ClaudeCode.run_iteration(client, state, [])

      assert result.error ==
               {:fallback_marker, "Something went wrong. Please try again later."}

      assert result.metadata.error_details == %{
               failure_kind: :agent_fallback_message,
               retry: false
             }

      # agent_fallback_message is resume-unsafe: the pre-spawn anchor poisons.
      assert result.metadata.state.resume.status == :poisoned
    end

    test "an unrecognized multi-line failure keeps the plain label (no marker false-positive)",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"stack trace line one\nline two\nline three", 1})

      {:ok, result} = ClaudeCode.run_iteration(client, state, [])

      assert result.error == "claude cli failed"
      assert result.metadata.error_details.failure_kind == :agent_unknown
      # Unknown is not resume-unsafe — the anchor survives for the next turn.
      assert result.metadata.state.resume.status == :anchored
    end

    test "a poisoned anchor is never reused — fresh-armed rearms on a NEW id",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      {:ok, first} = ClaudeCode.run_iteration(client, state, [])

      poisoned_state = update_in(first.metadata.state, [:resume], &ResumeState.poison/1)

      poisoned_id = poisoned_state.resume.session_id

      StubSandbox.program_run(client, {"", 0})
      {:ok, second} = ClaudeCode.run_iteration(client, poisoned_state, [])

      [_first_args, ["claude" | args2]] = StubSandbox.run_args_history(client)
      new_id = armed_uuid!(args2)

      assert new_id != poisoned_id
      assert second.metadata.state.resume.status == :anchored
      assert second.metadata.state.resume.session_id == new_id
      refute second.metadata.state.resume.retry_used
    end

    test "cwd-gate: a restored anchor from another workdir resolves fresh-armed",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      anchored_state = first.metadata.state

      # Simulate recovery into a NEW sandbox: same anchor, different pwd.
      moved = %{anchored_state | resume_cwd: "/sandbox/other"}

      StubSandbox.program_run(client, {"", 0})
      {:ok, second} = ClaudeCode.run_iteration(client, moved, [])

      [_, ["claude" | args2]] = StubSandbox.run_args_history(client)

      assert "--session-id" in args2
      refute "--resume" in args2
      # The fresh anchor is a NEW conversation for the new workdir.
      assert second.metadata.state.resume.session_id != anchored_state.resume.session_id
    end

    test "serialize → jsonb → restore round-trips the anchor; the fresh pwd stays as cwd",
         %{client: client, state: state, forge_home: forge_home} do
      StubSandbox.program_run(client, {"", 0})
      {:ok, first} = ClaudeCode.run_iteration(client, state, [])
      anchored_state = first.metadata.state

      snapshot =
        anchored_state
        |> ClaudeCode.serialize_state()
        |> Jason.encode!()
        |> Jason.decode!()

      assert snapshot["resume"]["state"]["status"] == "anchored"

      # A recovered incarnation: fresh init (new pwd), snapshot overlaid.
      {:ok, client2, _sid} = StubSandbox.create()
      StubSandbox.program_exec(client2, {"/sandbox/recovered\n", 0})

      {:ok, fresh} =
        ClaudeCode.init(client2, %{forge_home: forge_home, prompt: "do work", resume: :armed})

      {:ok, restored} = ClaudeCode.restore_state(fresh, snapshot)

      assert restored.resume.status == :anchored
      assert restored.resume.session_id == anchored_state.resume.session_id
      # The anchor keeps ITS workdir; the fresh pwd is the gate input.
      assert restored.resume.workdir == "/sandbox/work"
      assert restored.resume_cwd == "/sandbox/recovered"
    end

    test "restore never re-arms a resume-off session and never guesses on a garbled copy",
         %{forge_home: forge_home} do
      {:ok, client_off, _} = StubSandbox.create()
      {:ok, off_state} = ClaudeCode.init(client_off, %{forge_home: forge_home, prompt: "p"})

      snapshot = %{
        "iteration" => 3,
        "resume" => %{"state" => %{"v" => 1, "status" => "anchored"}}
      }

      {:ok, restored_off} = ClaudeCode.restore_state(off_state, snapshot)
      assert restored_off.resume == nil
      assert restored_off.iteration == 3

      {:ok, client_armed, _} = StubSandbox.create()
      StubSandbox.program_exec(client_armed, {"/w\n", 0})

      {:ok, armed_state} =
        ClaudeCode.init(client_armed, %{forge_home: forge_home, prompt: "p", resume: :armed})

      # Garbled copy (fails whitelist decode) → fresh armed state kept.
      {:ok, restored_armed} = ClaudeCode.restore_state(armed_state, snapshot)
      assert restored_armed.resume.status == :unanchored
    end
  end

  defp make_tmpdir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
end
