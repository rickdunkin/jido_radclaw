defmodule JidoClaw.Forge.Runners.CodexTest do
  @moduledoc """
  Unit coverage for `JidoClaw.Forge.Runners.Codex`. Drives the runner
  against a `JidoClaw.Test.StubSandbox` so file effects, env injection,
  argv shape, and parser branches are observable without invoking the
  real `codex` binary.
  """
  use ExUnit.Case, async: false

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
               ~s(mcp_servers.consolidator={url="http://127.0.0.1:0/run/x"}),
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
      assert override == ~s(mcp_servers.consolidator={url="http://127.0.0.1:0/run/x"})

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

    test "parser maps thread/turn/item events to ClaudeCode-shape tool_events",
         %{client: client, state: state} do
      jsonl =
        Enum.map_join(
          [
            %{"type" => "thread.started"},
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
      assert length(events) == 3

      [tool_use, tool_result, assistant] = events
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
      assert length(result.metadata.tool_events) == 1
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
