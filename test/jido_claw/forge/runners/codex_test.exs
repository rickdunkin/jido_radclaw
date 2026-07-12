defmodule JidoClaw.Forge.Runners.CodexTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Forge.Runners.Codex`. Drives the runner
  against a `JidoClaw.Test.StubSandbox` so file effects, env injection,
  argv shape, and parser branches are observable without invoking the
  real `codex` binary.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Forge.PubSub, as: ForgePubSub
  alias JidoClaw.Forge.ResumeState
  alias JidoClaw.Forge.Runners.Codex
  alias JidoClaw.Test.StubSandbox

  setup do
    prev_codex = Application.get_env(:jido_claw, :codex_home_dir)
    prev_forge = Application.get_env(:jido_claw, :forge_home)

    on_exit(fn ->
      restore(:codex_home_dir, prev_codex)
      restore(:forge_home, prev_forge)
    end)

    :ok
  end

  describe "init/2 — :no_credentials" do
    test "returns {:error, :no_credentials} when host codex dir is missing" do
      missing = Path.join(System.tmp_dir!(), "no_codex_#{:erlang.unique_integer([:positive])}")
      Application.put_env(:jido_claw, :codex_home_dir, missing)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = Codex.init(client, %{})
      events = StubSandbox.events(client)
      refute Enum.any?(events, fn {kind, _} -> kind == :write end)
    end

    test "returns {:error, :no_credentials} when host dir exists but auth.json is missing" do
      tmp = make_tmpdir!("codex_missing_auth")
      File.write!(Path.join(tmp, "config.toml"), "# config\n")
      Application.put_env(:jido_claw, :codex_home_dir, tmp)

      {:ok, client, _sid} = StubSandbox.create()

      assert {:error, :no_credentials} = Codex.init(client, %{})

      on_exit(fn -> File.rm_rf(tmp) end)
    end
  end

  describe "init/2 — happy path" do
    setup do
      host = make_tmpdir!("codex_host")
      File.write!(Path.join(host, "auth.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "config.toml"), "# host config\n")
      Application.put_env(:jido_claw, :codex_home_dir, host)

      forge_home = make_tmpdir!("forge_home")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "syncs auth + config and injects CODEX_HOME",
         %{forge_home: forge_home} do
      codex_home = Path.join(forge_home, ".codex")
      mcp_url = "http://127.0.0.1:54321/run/abc"

      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, state} =
               Codex.init(client, %{
                 forge_home: forge_home,
                 codex_home: codex_home,
                 mcp_server_url: mcp_url,
                 prompt: "hello consolidator"
               })

      assert state.forge_home == forge_home
      assert state.codex_home == codex_home
      assert state.model == "gpt-5-codex"
      assert state.mcp_server_url == mcp_url

      events = StubSandbox.events(client)

      mkdir_cmds =
        for {:exec, cmd} <- events, String.starts_with?(cmd, "mkdir -p"), do: cmd

      assert Enum.any?(mkdir_cmds, &String.contains?(&1, codex_home))
      assert Enum.any?(mkdir_cmds, &String.contains?(&1, "#{forge_home}/session"))

      # auth.json + config.toml are synced verbatim — host provider/profile
      # config is preserved.
      sync_cmds =
        for {:exec, cmd} <- events, String.contains?(cmd, "base64 -d"), do: cmd

      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{codex_home}/auth.json"))
      assert Enum.any?(sync_cmds, &String.contains?(&1, "#{codex_home}/config.toml"))

      # No consolidator MCP block is appended to config.toml — that table
      # is injected on the `codex exec` argv via `-c` (see the
      # run_iteration/3 test below) so we don't risk a duplicate-table
      # error against a host config that already names the server.
      refute Enum.any?(events, fn
               {:exec, cmd} -> String.contains?(cmd, ">> #{codex_home}/config.toml")
               _ -> false
             end)

      # auth.json gets chmod 600
      assert Enum.any?(events, fn
               {:exec, cmd} -> cmd == "chmod 600 #{codex_home}/auth.json"
               _ -> false
             end)

      assert StubSandbox.env(client) == %{"CODEX_HOME" => codex_home}

      # context.md written with the prompt body
      assert StubSandbox.file(client, "#{forge_home}/session/context.md") == "hello consolidator"
    end
  end

  describe "run_iteration/3" do
    setup do
      host = make_tmpdir!("codex_host_run")
      File.write!(Path.join(host, "auth.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "config.toml"), "# host config\n")
      Application.put_env(:jido_claw, :codex_home_dir, host)

      forge_home = make_tmpdir!("forge_home_run")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, client, _sid} = StubSandbox.create()
      codex_home = Path.join(forge_home, ".codex")

      {:ok, state} =
        Codex.init(client, %{
          forge_home: forge_home,
          codex_home: codex_home,
          mcp_server_url: "http://127.0.0.1:0/run/x",
          prompt: "do work"
        })

      {:ok, client: client, state: state, forge_home: forge_home}
    end

    test "passes the expected argv to codex exec", %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      assert args == [
               "exec",
               "-c",
               ~s(mcp_servers.consolidator=) <>
                 ~s({url="http://127.0.0.1:0/run/x", default_tools_approval_mode="approve"}),
               "-m",
               "gpt-5-codex",
               "--dangerously-bypass-approvals-and-sandbox",
               "--json",
               "--ephemeral",
               "--skip-git-repo-check",
               "--ignore-rules",
               "-C",
               state.forge_home,
               "do work"
             ]
    end

    test "consolidator MCP server is injected via -c override on the argv",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      # `exec` is followed immediately by `-c <override>`. The override
      # is an inline-table replacement of the whole `consolidator` MCP
      # entry — not a sub-key write — so a host config with a stdio
      # `command = "..."` sibling can't end up merged with our `url`.
      assert ["exec", "-c", override | _rest] = args
      # The approve mode rides the same inline table — headless codex
      # auto-cancels MCP tool calls without it (PR-2 live smoke).
      assert override ==
               ~s(mcp_servers.consolidator=) <>
                 ~s({url="http://127.0.0.1:0/run/x", default_tools_approval_mode="approve"})

      events = StubSandbox.events(client)

      # No write/exec event mutated $CODEX_HOME/config.toml to add
      # `[mcp_servers.consolidator]` — the table is supplied via argv only.
      refute Enum.any?(events, fn
               {:exec, cmd} ->
                 String.contains?(cmd, ">> #{state.codex_home}/config.toml")

               _ ->
                 false
             end)
    end

    test "omits -c override when mcp_server_url is not configured",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()
      codex_home = Path.join(forge_home, ".codex")

      {:ok, state} =
        Codex.init(client, %{
          forge_home: forge_home,
          codex_home: codex_home,
          prompt: "do work"
        })

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      refute Enum.any?(args, &(&1 == "-c"))
      refute Enum.any?(args, &String.starts_with?(&1, "mcp_servers."))
    end

    test "an ANSI-split secret is redacted at BOTH egress sites — context.md and argv (PR-3)",
         %{forge_home: forge_home} do
      # The escape splits the key mid-prefix; the PromptRedaction ANSI
      # pre-pass reassembles it so the pattern scan catches it at egress.
      {:ok, client, _sid} = StubSandbox.create()
      secret_prompt = "use sk-ant-\e[0maaaabbbbccccddddeeeeffff to auth"

      {:ok, state} =
        Codex.init(client, %{
          forge_home: forge_home,
          codex_home: Path.join(forge_home, ".codex"),
          prompt: secret_prompt
        })

      context = StubSandbox.file(client, "#{forge_home}/session/context.md")
      assert context =~ "[REDACTED:ANTHROPIC_KEY]"
      refute context =~ "aaaabbbbccccddddeeeeffff"

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)
      assert Enum.any?(args, &(&1 =~ "[REDACTED:ANTHROPIC_KEY]"))
      refute Enum.any?(args, &(&1 =~ "aaaabbbbccccddddeeeeffff"))
    end

    test "every iteration is a FRESH session — --ephemeral, never a resume token (PR-3)",
         %{client: client, state: state} do
      # camus SKILL.md's fresh-session-per-round rule: each composer re-review
      # wave must re-read the CURRENT tree, never resume a stale session
      # (camus C3-1's intra-attempt resume probe is deliberately not ported).
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      assert "--ephemeral" in args
      refute Enum.any?(args, &(&1 =~ "resume"))
      refute "--continue" in args
    end

    test "exit-127 → runner_unavailable", %{client: client, state: state} do
      StubSandbox.program_run(client, {"codex: command not found", 127})

      assert {:ok, %{status: :error, error: "runner_unavailable", output: out}} =
               Codex.run_iteration(client, state, [])

      assert out =~ "command not found"
    end

    test "exit-non-zero (other) → 'codex cli failed'", %{client: client, state: state} do
      StubSandbox.program_run(client, {"some failure", 1})

      assert {:ok, %{status: :error, error: "codex cli failed"}} =
               Codex.run_iteration(client, state, [])
    end

    test "timeout → harness_timeout", %{client: client, state: state} do
      StubSandbox.program_run(client, {"", :timeout})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               Codex.run_iteration(client, state, [])
    end

    test "docker-manufactured timeout (exit 124) → harness_timeout", %{
      client: client,
      state: state
    } do
      # Docker maps a harness timeout to `{"timeout after \#{t}ms", 124}`, not the
      # `:timeout` atom HostShell uses. `Sandbox.run/4` normalizes that EXACT
      # tuple (built from the same `:timeout` opt in play) back to `:timeout`, so
      # the runner classifies it as harness_timeout — not the generic
      # "codex cli failed" it fell into before the fix.
      StubSandbox.program_run(client, {"timeout after 5000ms", 124})

      assert {:ok, %{status: :error, error: "harness_timeout"}} =
               Codex.run_iteration(client, state, timeout: 5000)
    end

    test "parser maps thread/turn/item events to ClaudeCode-shape tool_events",
         %{client: client, state: state} do
      jsonl =
        Enum.map_join(
          [
            %{"type" => "thread.started", "thread_id" => "0198a5a0-0000-7000-8000-000000000001"},
            %{"type" => "turn.started"},
            %{
              "type" => "item.started",
              "item" => %{
                "id" => "item-1",
                "type" => "mcp_tool_call",
                "server" => "consolidator",
                "tool" => "list_clusters",
                "arguments" => %{}
              }
            },
            %{
              "type" => "item.completed",
              "item" => %{
                "id" => "item-1",
                "type" => "mcp_tool_call",
                "server" => "consolidator",
                "tool" => "list_clusters",
                "arguments" => %{},
                "result" => %{"content" => "ok"},
                "status" => "completed"
              }
            },
            %{
              "type" => "item.completed",
              "item" => %{"id" => "item-2", "type" => "agent_message", "text" => "all done"}
            },
            %{
              "type" => "turn.completed",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      StubSandbox.program_run(client, {jsonl, 0})

      assert {:ok, result} = Codex.run_iteration(client, state, [])
      assert result.status == :done
      events = result.metadata.tool_events

      # thread.started + turn.started are dropped as system noise.
      assert [tool_use, tool_result, assistant] = events
      assert tool_use["type"] == "tool_use"
      assert tool_use["name"] == "list_clusters"
      assert tool_use["server"] == "consolidator"
      assert tool_use["id"] == "item-1"

      assert tool_result["type"] == "tool_result"
      assert tool_result["tool_use_id"] == "item-1"
      assert tool_result["content"] == "ok"
      assert tool_result["is_error"] == false

      assert assistant["type"] == "assistant"
      assert assistant["text"] == "all done"

      # usage was captured into metadata
      assert result.metadata.usage == %{"input_tokens" => 10, "output_tokens" => 5}

      # The backend thread id is captured (armed resume reads it); the
      # `{"type":"thread.started","thread_id":…}` key shape is verified live
      # against codex 0.144.1.
      assert result.metadata.thread_id == "0198a5a0-0000-7000-8000-000000000001"
    end

    test "turn.failed maps to :error with the embedded message",
         %{client: client, state: state} do
      jsonl =
        Enum.map_join(
          [
            %{"type" => "thread.started"},
            %{"type" => "turn.failed", "error" => %{"message" => "model_overloaded"}}
          ],
          "\n",
          &Jason.encode!/1
        )

      StubSandbox.program_run(client, {jsonl, 0})

      assert {:ok, %{status: :error, error: "model_overloaded"}} =
               Codex.run_iteration(client, state, [])
    end

    test "stream with no terminal event → :done (parser fallback)",
         %{client: client, state: state} do
      jsonl =
        Enum.map_join(
          [
            %{"type" => "thread.started"},
            %{
              "type" => "item.completed",
              "item" => %{"type" => "agent_message", "text" => "partial"}
            }
          ],
          "\n",
          &Jason.encode!/1
        )

      StubSandbox.program_run(client, {jsonl, 0})

      assert {:ok, result} = Codex.run_iteration(client, state, [])
      assert result.status == :done
      assert [_] = result.metadata.tool_events
    end
  end

  # Executor-seam PR-2 knobs. Defaults (covered above) preserve the
  # consolidator byte-for-byte; these pin the vendor-executor posture.
  describe "executor knobs (PR-2)" do
    setup do
      host = make_tmpdir!("codex_host_knobs")
      File.write!(Path.join(host, "auth.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "config.toml"), "# host config\n")
      Application.put_env(:jido_claw, :codex_home_dir, host)

      forge_home = make_tmpdir!("forge_home_knobs")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, host: host, forge_home: forge_home}
    end

    test "config_sync: :auth_only syncs auth.json alone — the host config.toml never crosses",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      assert {:ok, _state} =
               Codex.init(client, %{
                 forge_home: forge_home,
                 codex_home: Path.join(forge_home, ".codex"),
                 config_sync: :auth_only
               })

      sync_cmds =
        for {:exec, cmd} <- StubSandbox.events(client),
            String.contains?(cmd, "base64 -d"),
            do: cmd

      assert Enum.any?(sync_cmds, &String.contains?(&1, "auth.json"))
      refute Enum.any?(sync_cmds, &String.contains?(&1, "config.toml"))
    end

    test "config_sync: :auth_only fails closed when the env inject is refused",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # A refused CODEX_HOME inject means codex would read the operator's
      # REAL ~/.codex (host config.toml, host MCP servers) — the unisolated
      # session must not start.
      StubSandbox.program_inject_env(client, {:error, :inject_env_refused})

      assert {:error, {:config_isolation_failed, :inject_env_refused}} =
               Codex.init(client, %{
                 forge_home: forge_home,
                 codex_home: Path.join(forge_home, ".codex"),
                 config_sync: :auth_only
               })
    end

    test "config_sync: :full keeps best-effort on a refused inject (consolidator byte-for-byte)",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()

      # Deliberate asymmetry: under :full the synced auth.json/config.toml are
      # host copies, so a refused inject degrades hygiene (mutable session/cache
      # state lands in the host dir), not isolation — init stays best-effort.
      StubSandbox.program_inject_env(client, {:error, :inject_env_refused})

      assert {:ok, _state} =
               Codex.init(client, %{
                 forge_home: forge_home,
                 codex_home: Path.join(forge_home, ".codex")
               })
    end

    test "access: :read_only swaps the bypass flag for -s read-only; mcp_server_name + cwd land",
         %{forge_home: forge_home} do
      {:ok, client, _sid} = StubSandbox.create()
      repo_dir = Path.join(forge_home, "repo")

      {:ok, state} =
        Codex.init(client, %{
          forge_home: forge_home,
          codex_home: Path.join(forge_home, ".codex"),
          mcp_server_url: "http://127.0.0.1:0/deposit/ref-1",
          mcp_server_name: "jido_deposit",
          access: :read_only,
          config_sync: :auth_only,
          cwd: repo_dir,
          prompt: "review it"
        })

      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      assert args == [
               "exec",
               "-c",
               ~s(mcp_servers.jido_deposit=) <>
                 ~s({url="http://127.0.0.1:0/deposit/ref-1", default_tools_approval_mode="approve"}),
               "-m",
               "gpt-5-codex",
               "-s",
               "read-only",
               "--json",
               "--ephemeral",
               "--skip-git-repo-check",
               "--ignore-rules",
               "-C",
               repo_dir,
               "review it"
             ]

      refute "--dangerously-bypass-approvals-and-sandbox" in args
    end
  end

  # Native CLI session resume, codex side (MC1-1; PORT sign-off Q2:
  # backend-issued anchor, provisional until a clean exit — CH2-6). The
  # exec-opts-before-`resume` ordering and the `--` guidance separator are
  # verified live against codex 0.144.1.
  describe "armed modes (resume: :armed)" do
    setup do
      host = make_tmpdir!("codex_host_armed")
      File.write!(Path.join(host, "auth.json"), ~s({"token":"sk-test"}\n))
      File.write!(Path.join(host, "config.toml"), "# host config\n")
      Application.put_env(:jido_claw, :codex_home_dir, host)

      forge_home = make_tmpdir!("forge_home_codex_armed")

      on_exit(fn ->
        File.rm_rf(host)
        File.rm_rf(forge_home)
      end)

      {:ok, client, _sid} = StubSandbox.create()

      {:ok, state} =
        Codex.init(client, %{
          forge_home: forge_home,
          codex_home: Path.join(forge_home, ".codex"),
          mcp_server_url: "http://127.0.0.1:0/run/x",
          prompt: "do work",
          resume: :armed
        })

      {:ok, client: client, state: state, forge_home: forge_home}
    end

    defp thread_started_jsonl(thread_id, terminal) do
      events =
        [%{"type" => "thread.started", "thread_id" => thread_id}] ++
          case terminal do
            :done -> [%{"type" => "turn.completed", "usage" => %{}}]
            {:failed, msg} -> [%{"type" => "turn.failed", "error" => %{"message" => msg}}]
            :none -> []
          end

      Enum.map_join(events, "\n", &Jason.encode!/1)
    end

    test "armed init records the -C cwd as the anchor workdir", %{state: state} do
      assert state.resume.workdir == state.cwd
      assert state.resume.status == :unanchored
    end

    test "fresh-armed drops --ephemeral ONLY — argv otherwise byte-identical",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})
      assert {:ok, _} = Codex.run_iteration(client, state, [])

      ["codex" | args] = StubSandbox.last_run_args(client)

      assert args == [
               "exec",
               "-c",
               ~s(mcp_servers.consolidator=) <>
                 ~s({url="http://127.0.0.1:0/run/x", default_tools_approval_mode="approve"}),
               "-m",
               "gpt-5-codex",
               "--dangerously-bypass-approvals-and-sandbox",
               "--json",
               "--skip-git-repo-check",
               "--ignore-rules",
               "-C",
               state.forge_home,
               "do work"
             ]

      refute "--ephemeral" in args
      refute "resume" in args
      refute "--last" in args
    end

    test "a clean :done exit promotes the captured thread to a trusted anchor (CH2-6)",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-00000000aaaa"
      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})

      {:ok, result} = Codex.run_iteration(client, state, [])

      assert result.status == :done
      assert result.metadata.state.resume.status == :anchored
      assert result.metadata.state.resume.session_id == tid
      assert result.metadata.state.resume.ownership == :backend
    end

    test "a failed turn keeps the captured thread PROVISIONAL — and never continues on it",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-00000000bbbb"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, {:failed, "model_overloaded"}), 0},
        {"", 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])

      assert first.status == :error
      assert first.metadata.state.resume.status == :provisional
      assert first.metadata.state.resume.session_id == tid

      # The provisional anchor never continues: the next turn is fresh-armed.
      {:ok, _second} = Codex.run_iteration(client, first.metadata.state, [])
      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      refute "resume" in args2
      refute "--ephemeral" in args2
    end

    test "no thread.started in the stream leaves the state unanchored",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})

      {:ok, result} = Codex.run_iteration(client, state, [])

      assert result.metadata.state.resume.status == :unanchored
      assert result.metadata.state.resume.session_id == nil
    end

    test "continuation: exec-level opts BEFORE `resume`, guidance behind `--` (codex 0.144.1)",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-00000000cccc"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :done), 0},
        {thread_started_jsonl(tid, :done), 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])

      {:ok, second} =
        Codex.run_iteration(client, first.metadata.state, guidance: "address the findings")

      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      assert args2 == [
               "exec",
               "-c",
               ~s(mcp_servers.consolidator=) <>
                 ~s({url="http://127.0.0.1:0/run/x", default_tools_approval_mode="approve"}),
               "-m",
               "gpt-5-codex",
               "--dangerously-bypass-approvals-and-sandbox",
               "--json",
               "--skip-git-repo-check",
               "--ignore-rules",
               "-C",
               state.forge_home,
               "resume",
               tid,
               "--",
               "address the findings"
             ]

      refute "--ephemeral" in args2
      refute "--last" in args2
      # The original task never rides a continuation argv (CM2-3).
      refute Enum.any?(args2, &(&1 =~ "do work"))

      assert second.metadata.state.resume.status == :anchored
      assert second.metadata.state.resume.session_start_source == :resume
    end

    test "a continuation with no guidance uses the neutral nudge, never the task",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-00000000dddd"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :done), 0},
        {"", 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])
      {:ok, _} = Codex.run_iteration(client, first.metadata.state, [])

      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      assert ["resume", ^tid, "--", "Continue."] = Enum.take(args2, -4)
      refute Enum.any?(args2, &(&1 =~ "do work"))
    end

    test "CM2-3 strengthened: continuation given BOTH prompt: and guidance: uses the guidance",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000001111"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :done), 0},
        {"", 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])

      {:ok, _} =
        Codex.run_iteration(client, first.metadata.state,
          prompt: "do work",
          guidance: "just the guidance"
        )

      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      assert ["resume", ^tid, "--", "just the guidance"] = Enum.take(args2, -4)
      refute Enum.any?(args2, &(&1 =~ "do work"))
    end

    test "prevention pin: fresh-armed ignores guidance: and sends state.prompt",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", 0})

      {:ok, _result} =
        Codex.run_iteration(client, state, guidance: "Continue the consolidation pass")

      ["codex" | args] = StubSandbox.last_run_args(client)

      assert Enum.take(args, -1) == ["do work"]
      refute "resume" in args
      refute Enum.any?(args, &(&1 =~ "Continue the consolidation pass"))
    end

    test "continuation delivers parked inflight text — beats guidance:, consumed at take",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000002222"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :done), 0},
        {"", 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])

      parked =
        update_in(first.metadata.state, [:resume], fn rs ->
          {:ok, rs} = ResumeState.put_guidance(rs, "the parked answer")
          {:ok, rs} = ResumeState.guidance_inflight(rs)
          rs
        end)

      {:ok, second} = Codex.run_iteration(client, parked, guidance: "ignored nudge")

      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      assert ["resume", ^tid, "--", "the parked answer"] = Enum.take(args2, -4)
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

      {:ok, result} = Codex.run_iteration(client, parked, [])

      ["codex" | args] = StubSandbox.last_run_args(client)
      assert Enum.take(args, -1) == ["do work"]
      refute Enum.any?(args, &(&1 =~ "the parked answer"))

      assert result.metadata.state.resume.pending_guidance ==
               %{status: :pending, text: "the parked answer"}

      assert result.metadata.state.resume.guidance_rev > rev_before
    end

    test "F8/CH2-6: a terminal-less exit-0 stream keeps the anchor PROVISIONAL",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000003333"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :none), 0},
        {"", 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])

      # The nil-fallthrough result posture stays Runner.done (deliberate,
      # pinned below) — but the truncated stream is not promotion evidence.
      assert first.status == :done
      assert first.metadata.state.resume.status == :provisional
      assert first.metadata.state.resume.session_id == tid

      # And a provisional anchor never continues: the next turn is fresh-armed.
      {:ok, _second} = Codex.run_iteration(client, first.metadata.state, [])
      [_, ["codex" | args2]] = StubSandbox.run_args_history(client)

      refute "resume" in args2
      refute "--ephemeral" in args2
    end

    test "a continuation echoing a DIFFERENT thread drops the anchor",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-00000000eeee"
      other = "0198a5a0-0000-7000-8000-00000000ffff"

      StubSandbox.program_run_sequence(client, [
        {thread_started_jsonl(tid, :done), 0},
        {thread_started_jsonl(other, :done), 0}
      ])

      {:ok, first} = Codex.run_iteration(client, state, [])
      {:ok, second} = Codex.run_iteration(client, first.metadata.state, prompt: "go")

      assert second.metadata.state.resume.status == :unanchored
    end

    test "timeout and CLI-failure terminals still return metadata.state",
         %{client: client, state: state} do
      StubSandbox.program_run(client, {"", :timeout})
      {:ok, timed_out} = Codex.run_iteration(client, state, [])

      assert timed_out.status == :error
      assert timed_out.error == "harness_timeout"
      assert timed_out.metadata.state.resume.status == :unanchored

      assert timed_out.metadata.error_details == %{
               failure_kind: :stalled_wall_clock,
               retry: true
             }

      # Multi-line unrecognized output keeps the plain label; exit 127 keeps
      # runner_unavailable and classifies missing-executable.
      StubSandbox.program_run(client, {"boom\ncrash\ntrace", 1})
      {:ok, failed} = Codex.run_iteration(client, state, [])

      assert failed.error == "codex cli failed"
      assert failed.metadata.error_details.failure_kind == :agent_unknown
      assert %{resume: %ResumeState{}} = failed.metadata.state

      StubSandbox.program_run(client, {"codex: command not found", 127})
      {:ok, missing} = Codex.run_iteration(client, state, [])

      assert missing.error == "runner_unavailable"

      assert missing.metadata.error_details.failure_kind ==
               :agent_runtime_missing_executable
    end

    test "a rejected continuation poisons the anchor, tags resume_rejected, emits loudly — no retry",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000004444"
      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})
      {:ok, first} = Codex.run_iteration(client, state, [])

      forge_sid = "codex_reject_#{:erlang.unique_integer([:positive])}"
      :ok = ForgePubSub.subscribe(forge_sid)

      # The verified live rejection shape (codex 0.144.1, exit 1).
      rejection =
        "Error: thread/resume: thread/resume failed: no rollout found for thread id #{tid} (code -32600)"

      StubSandbox.program_run(client, {rejection, 1})

      {:ok, second} =
        Codex.run_iteration(client, first.metadata.state,
          prompt: "go on",
          forge_session_id: forge_sid
        )

      assert second.metadata.error_details == %{
               failure_kind: :agent_session_poisoned,
               retry: true,
               resume_rejected: true
             }

      assert second.error =~ "no rollout found"
      assert second.metadata.state.resume.status == :poisoned

      # Exactly two CLI invocations — the runner never auto-retried.
      assert [_, _] = StubSandbox.run_args_history(client)

      assert_receive {:resume_failed, payload}
      assert payload.kind == :agent_session_poisoned
      assert payload.resume_rejected == true
      assert payload.runner == :codex
    end

    test "a short bare-line failure tags {:fallback_marker, _}",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000005555"
      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})
      {:ok, first} = Codex.run_iteration(client, state, [])

      StubSandbox.program_run(client, {"Please try again later.", 1})
      {:ok, second} = Codex.run_iteration(client, first.metadata.state, prompt: "go")

      assert second.error == {:fallback_marker, "Please try again later."}

      assert second.metadata.error_details == %{
               failure_kind: :agent_fallback_message,
               retry: false
             }

      # Resume-unsafe: the trusted anchor poisons.
      assert second.metadata.state.resume.status == :poisoned
    end

    test "a poisoned thread id is never reused; a NEW backend id rearms",
         %{client: client, state: state} do
      tid = "0198a5a0-0000-7000-8000-000000001111"
      fresh_tid = "0198a5a0-0000-7000-8000-000000002222"

      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})
      {:ok, first} = Codex.run_iteration(client, state, [])

      poisoned_state = update_in(first.metadata.state, [:resume], &ResumeState.poison/1)

      # Pathological echo of the poisoned id: the rearm refuses reuse.
      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})
      {:ok, second} = Codex.run_iteration(client, poisoned_state, [])
      assert second.metadata.state.resume.status == :poisoned

      # A NEW backend id rearms (provisional → trusted on the clean exit).
      StubSandbox.program_run(client, {thread_started_jsonl(fresh_tid, :done), 0})
      {:ok, third} = Codex.run_iteration(client, second.metadata.state, [])

      assert third.metadata.state.resume.status == :anchored
      assert third.metadata.state.resume.session_id == fresh_tid
      refute third.metadata.state.resume.retry_used
    end

    test "serialize → jsonb → restore round-trips; a foreign workdir resolves fresh-armed",
         %{client: client, state: state, forge_home: forge_home} do
      tid = "0198a5a0-0000-7000-8000-000000003333"
      StubSandbox.program_run(client, {thread_started_jsonl(tid, :done), 0})
      {:ok, first} = Codex.run_iteration(client, state, [])

      snapshot =
        first.metadata.state
        |> Codex.serialize_state()
        |> Jason.encode!()
        |> Jason.decode!()

      assert snapshot["resume"]["state"]["status"] == "anchored"

      # Recovered incarnation in a DIFFERENT cwd: the anchor restores but the
      # cwd-gate resolves the next turn fresh-armed.
      other_cwd = make_tmpdir!("codex_other_cwd")
      on_exit(fn -> File.rm_rf(other_cwd) end)

      {:ok, client2, _sid} = StubSandbox.create()

      {:ok, fresh} =
        Codex.init(client2, %{
          forge_home: forge_home,
          codex_home: Path.join(forge_home, ".codex"),
          prompt: "do work",
          resume: :armed,
          cwd: other_cwd
        })

      {:ok, restored} = Codex.restore_state(fresh, snapshot)

      assert restored.resume.session_id == tid
      assert restored.resume.workdir == state.cwd

      StubSandbox.program_run(client2, {"", 0})
      {:ok, _} = Codex.run_iteration(client2, restored, [])

      ["codex" | args] = StubSandbox.last_run_args(client2)
      refute "resume" in args
      refute "--ephemeral" in args
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp make_tmpdir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)
end
