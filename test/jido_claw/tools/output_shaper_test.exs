defmodule JidoClaw.Tools.OutputShaperTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.MCP.ProxyGenerator
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Tools.OutputShaper

  # Inline echo standing in for run_command: the generated wrapper runs
  # the full normalize → redact → shape → limit pipeline on whatever
  # `:result` the test hands it (same pattern as output_limit_test).
  defmodule RunCommandEcho do
    use JidoClaw.Tools.Action,
      name: "run_command",
      description: "Test-only echo standing in for run_command in shaper tests.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, _context), do: result
  end

  defmodule OtherEcho do
    use JidoClaw.Tools.Action,
      name: "tool_not_on_shaper_allowlist",
      description: "Test-only echo for the allowlist pass-through case.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, _context), do: result
  end

  defmodule GitDiffEcho do
    use JidoClaw.Tools.Action,
      name: "git_diff",
      description: "Test-only echo standing in for git_diff in shaper tests.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, _context), do: result
  end

  # Inline `mcp_`-rooted echo standing in for a generated MCP proxy: the
  # wrapper runs the full pipeline, and `mcp_test_echo` clears
  # `mcp_shapeable?/2`'s `mcp_` prefix check so the generic MCP path fires.
  defmodule McpEcho do
    use JidoClaw.Tools.Action,
      name: "mcp_test_echo",
      description: "Test-only echo standing in for an external MCP proxy in shaper tests.",
      schema: []

    @impl Jido.Action
    def run(%{result: result}, _context), do: result
  end

  defp enable_shaping(overrides \\ []) do
    original = Application.get_env(:jido_claw, :output_shaping, [])

    merged =
      original
      |> Keyword.merge(enabled?: true)
      |> Keyword.merge(overrides)

    Application.put_env(:jido_claw, :output_shaping, merged)
    on_exit(fn -> Application.put_env(:jido_claw, :output_shaping, original) end)
  end

  # :tool_output_max_bytes is global (OutputLimit reads it too), so this
  # only works because the module is async: false.
  defp cap_output_bytes(bytes) do
    original = Application.fetch_env(:jido_claw, :tool_output_max_bytes)
    Application.put_env(:jido_claw, :tool_output_max_bytes, bytes)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, :tool_output_max_bytes, value)
        :error -> Application.delete_env(:jido_claw, :tool_output_max_bytes)
      end
    end)
  end

  defp scope do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "shaper")

    %{
      tenant_id: tenant_id,
      session: session,
      context: %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: session.id,
          actor: actor_for(tenant_id)
        }
      }
    }
  end

  # Classic-format ExUnit output, padded past min_shape_bytes (2 KB).
  defp exunit_output(opts \\ []) do
    failures = Keyword.get(opts, :failures, [])
    passed = Keyword.get(opts, :passed, 5)
    extra = Keyword.get(opts, :extra, "")

    blocks =
      failures
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{name, loc}, i} ->
        """

          #{i}) test #{name} (ShaperFixtureTest)
             #{loc}
             ** (RuntimeError) boom #{name}#{extra}
             stacktrace:
               #{loc}: (test)
        """
      end)

    """
    Running ExUnit with seed: 42, max_cases: 8

    #{String.duplicate(".", 2_400)}
    #{blocks}

    Finished in 1.5 seconds (1.0s async, 0.5s sync)
    #{passed + length(failures)} tests, #{length(failures)} failures

    Randomized with seed 42
    """
  end

  defp run_shaped(output, context, params_extra \\ %{}) do
    params =
      Map.merge(
        %{command: "mix test", result: {:ok, %{output: output, exit_code: 1}}},
        params_extra
      )

    RunCommandEcho.run(params, context)
  end

  defp run_mcp(result, context), do: McpEcho.run(%{result: result}, context)

  # All-signal `mix compile` output: only warning blocks, no `Compiling`
  # noise, so `MixCompile.parse/1` matches but returns compressed?: false.
  defp all_warnings_output(warnings) do
    Enum.map_join(1..warnings, "\n", fn i ->
      """
      warning: variable "shadow#{i}" is unused
        lib/fixture/mod#{i}.ex:#{i}: Fixture.Mod#{i}.fun/1
      """
    end)
  end

  # Unified diff over `files` one-line-changed files; the per-file stat
  # header alone outgrows small caps long before the chunks do.
  defp many_file_diff(files) do
    Enum.map_join(1..files, "\n", fn i ->
      """
      diff --git a/lib/fixture/file_#{i}.ex b/lib/fixture/file_#{i}.ex
      index 000000#{i}..111111#{i} 100644
      --- a/lib/fixture/file_#{i}.ex
      +++ b/lib/fixture/file_#{i}.ex
      @@ -1,2 +1,2 @@
      -old line #{i}
      +new line #{i}
      """
    end)
  end

  describe "pass-through guards" do
    test "disabled config leaves the result byte-identical" do
      %{context: context} = scope()
      output = exunit_output(failures: [{"a", "test/a_test.exs:1"}])

      assert {:ok, result} = run_shaped(output, context)
      assert result.output == output
      refute Map.has_key?(result, :shaped)
    end

    test "errors pass through untouched, including 3-tuples with effects" do
      enable_shaping()
      %{context: context} = scope()

      assert {:error, %{message: "boom"}} =
               RunCommandEcho.run(%{command: "mix test", result: {:error, "boom"}}, context)

      assert {:error, %{message: "boom"}, %{side: 1}} =
               RunCommandEcho.run(
                 %{command: "mix test", result: {:error, "boom", %{side: 1}}},
                 context
               )
    end

    test "success 3-tuples shape the map and preserve effects" do
      enable_shaping()
      %{context: context} = scope()
      output = exunit_output()

      assert {:ok, result, %{side: :effect}} =
               RunCommandEcho.run(
                 %{
                   command: "mix test",
                   result: {:ok, %{output: output, exit_code: 0}, %{side: :effect}}
                 },
                 context
               )

      assert result.shaped
    end

    test "tools off the allowlist are untouched" do
      enable_shaping()
      %{context: context} = scope()
      output = exunit_output()

      assert {:ok, result} =
               OtherEcho.run(%{result: {:ok, %{output: output, exit_code: 0}}}, context)

      assert result.output == output
      refute Map.has_key?(result, :shaped)
    end

    test "effective streaming passes through; MCP-dropped streaming still shapes" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()
      output = exunit_output()

      # Real streaming: the user saw the live stream; the preview is bounded.
      assert {:ok, result} = run_shaped(output, context, %{stream_to_display: true})
      assert result.output == output
      refute Map.has_key?(result, :shaped)

      # Under MCP serve-mode the streaming request is dropped, so the call
      # must still be shaped. Use a session-less context: MCP recording is
      # out of scope here.
      Application.put_env(:jido_claw, :serve_mode, :mcp)
      on_exit(fn -> Application.delete_env(:jido_claw, :serve_mode) end)

      mcp_context = %{tool_context: %{tenant_id: tenant_id, actor: actor_for(tenant_id)}}

      assert {:ok, result} = run_shaped(output, mcp_context, %{stream_to_display: true})
      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
    end

    test "no tenant in tool_context passes through unshaped" do
      enable_shaping()
      output = exunit_output(failures: [{"a", "test/a_test.exs:1"}])

      assert {:ok, result} = run_shaped(output, %{tool_context: %{}})
      assert result.output == output
      refute Map.has_key?(result, :shaped)
    end

    test "output below min_shape_bytes is untouched" do
      enable_shaping()
      %{context: context} = scope()

      assert {:ok, result} = run_shaped("tiny output", context)
      assert result.output == "tiny output"
      refute Map.has_key?(result, :shaped)
    end
  end

  describe "shaping" do
    test "shaped result carries compact body, footer, ref, and metadata keys" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()

      output =
        exunit_output(
          passed: 311,
          failures: [
            {"handles nil", "test/foo_test.exs:42"},
            {"handles empty", "test/foo_test.exs:77"}
          ]
        )

      assert {:ok, result} = run_shaped(output, context)

      assert result.shaped
      assert result.exit_code == 1
      assert result.truncated == false
      assert is_integer(result.captured_bytes) and result.captured_bytes > 0
      assert result.output_ref =~ ~r/^out_[0-9a-f]{24}$/
      assert result.summary.passed == 311
      assert result.summary.failed == 2

      assert result.output =~ "mix test — 311 passed, 2 failed"
      assert result.output =~ "1) test handles nil (ShaperFixtureTest)"

      assert result.output =~
               "[full output: #{result.captured_bytes} bytes — fetch_output ref=#{result.output_ref}]"

      assert byte_size(result.output) < byte_size(output)

      # Reversibility: the stored row holds the full captured text.
      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ "Randomized with seed 42"
      assert row.content =~ String.duplicate(".", 2_400)
      assert row.tool == "run_command"
      assert row.command == "mix test"
      assert row.exit_code == 1
      assert is_binary(row.command_fingerprint)
    end

    test "transient store failure degrades to shaped-without-ref, red kept verbatim" do
      enable_shaping()
      %{tenant_id: tenant_id} = scope()

      # session_uuid with no Session row → the cross-tenant FK check fails
      # the insert deterministically (both attempts).
      broken_context = %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: Ecto.UUID.generate(),
          actor: actor_for(tenant_id)
        }
      }

      output = exunit_output(failures: [{"degraded", "test/deg_test.exs:9"}])

      assert {:ok, result} = run_shaped(output, broken_context)

      assert result.shaped
      refute Map.has_key?(result, :output_ref)
      assert result.output =~ "(full output unavailable)"
      # The single documented exception still carries the red verbatim.
      assert result.output =~ "1) test degraded (ShaperFixtureTest)"
    end

    test "internal shaping exception returns the original result" do
      enable_shaping()
      %{context: context} = scope()
      output = exunit_output()

      # A non-binary command makes format detection raise inside the
      # shaper; the rescue must hand back the unshaped result.
      assert {:ok, result} =
               RunCommandEcho.run(
                 %{command: 123, result: {:ok, %{output: output, exit_code: 0}}},
                 context
               )

      assert result.output == output
      refute Map.has_key?(result, :shaped)
    end

    test "ANSI-interrupted secrets are reassembled and re-redacted before storage" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()

      # The escape splits the key in the raw output. The upstream
      # OutputRedaction pass now strips ANSI + redacts at the root, so the
      # secret is already caught before the shaper sees it; the shaper's own
      # strip+redact (kept belt-and-suspenders) is then a no-op on the
      # already-redacted text. 24 trailing chars clear the pattern's 20-char
      # minimum.
      split_secret = "sk-ant-\e[0mabcdefghijklmnopqrstuvwx"

      output =
        exunit_output(failures: [{"leaky", "test/leak_test.exs:3"}], extra: " #{split_secret}")

      assert {:ok, result} = run_shaped(output, context)

      assert result.output =~ "[REDACTED:ANTHROPIC_KEY]"
      refute result.output =~ "abcdefghijklmnopqrstuvwx"

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ "[REDACTED:ANTHROPIC_KEY]"
      refute row.content =~ "abcdefghijklmnopqrstuvwx"
    end

    test "upstream-truncated input gets generic shaping and an honest footer" do
      enable_shaping()
      %{context: context} = scope()

      output =
        String.duplicate("log line\n", 1_500) <> SessionManager.truncation_note(false)

      assert {:ok, result} = run_shaped(output, context)

      assert result.shaped
      assert result.truncated == true
      assert result.output =~ "... [elided"
      assert result.output =~ "[captured output (truncated):"
      refute Map.has_key?(result, :summary)
    end

    test "telemetry fires with tool/format tags and bytes_saved" do
      enable_shaping()
      %{context: context} = scope()

      handler_id = "shaper-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_claw, :tool, :shaping],
        fn _event, measurements, metadata, pid ->
          send(pid, {:shaping, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _result} = run_shaped(exunit_output(), context)

      assert_received {:shaping, measurements, metadata}
      assert measurements.total == 1
      assert measurements.bytes_saved > 0
      assert metadata.tool == "run_command"
      assert metadata.format == :mix_test
    end
  end

  describe "inline cap bounding" do
    # The P1 leak: a matched-but-all-signal body used to pass through and
    # hit OutputLimit's ref-less head cut, losing the tail forever.
    test "oversized all-signal output is bounded with a ref, never ref-less truncated" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()
      cap_output_bytes(4_096)

      output = all_warnings_output(80)
      assert byte_size(output) > 4_096

      assert {:ok, result} = run_shaped(output, context, %{command: "mix compile"})

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.output) <= 4_096
      assert result.output =~ "mix compile — 0 files compiled, 80 warnings, 0 errors"
      assert result.output =~ "... [elided"
      assert String.ends_with?(result.output, "fetch_output ref=#{result.output_ref}]")
      refute result.output =~ "[tool output truncated"

      # Reversibility: the tail that the old ref-less cut dropped is stored.
      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ ~s(variable "shadow80" is unused)
    end

    test "small all-signal output still passes through byte-identical" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      output = all_warnings_output(30)
      assert byte_size(output) > OutputShaper.min_shape_bytes()
      assert byte_size(output) <= 4_096

      assert {:ok, result} = run_shaped(output, context, %{command: "mix compile"})

      assert result.output == output
      refute Map.has_key?(result, :shaped)
    end

    test "compressed body that itself exceeds the cap is bounded, footer intact" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      # MixTest always keeps the first failure block whole, so one huge
      # block makes the *shaped* body outgrow the cap.
      huge = " " <> String.duplicate("x", 6_000)
      output = exunit_output(failures: [{"huge", "test/huge_test.exs:1"}], extra: huge)

      assert {:ok, result} = run_shaped(output, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.output) <= 4_096
      assert result.output =~ "... [elided"
      assert String.ends_with?(result.output, "fetch_output ref=#{result.output_ref}]")
      refute result.output =~ "[tool output truncated"
    end

    # P3 regression: min_shape_bytes is a noise floor, not a safety gate.
    # A cap configured below it must not let sub-floor output skip the
    # shaper and hit OutputLimit's ref-less cut.
    test "cap configured below min_shape_bytes still shapes instead of ref-less truncation" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(512)

      output = String.duplicate("log line\n", 110)
      assert byte_size(output) > 512
      assert byte_size(output) < OutputShaper.min_shape_bytes()

      assert {:ok, result} = run_shaped(output, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.output) <= 512
      assert result.output =~ "... [elided"
      assert String.ends_with?(result.output, "fetch_output ref=#{result.output_ref}]")
      refute result.output =~ "[tool output truncated"
    end

    test "many-file diff whose stat header exceeds the cap is bounded with a ref" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      diff = many_file_diff(200)

      assert {:ok, result} =
               GitDiffEcho.run(%{result: {:ok, %{diff: diff}}}, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.diff) <= 4_096
      assert result.diff =~ "git diff — 200 files changed"
      assert String.ends_with?(result.diff, "fetch_output ref=#{result.output_ref}]")
      refute result.diff =~ "[tool output truncated"
    end
  end

  describe "previous-run delta" do
    test "identical failure sets prepend a same-failures line" do
      enable_shaping()
      %{context: context} = scope()

      failures = [{"flaky one", "test/f_test.exs:1"}, {"flaky two", "test/f_test.exs:2"}]

      assert {:ok, first} = run_shaped(exunit_output(failures: failures), context)
      refute first.output =~ "↻"

      assert {:ok, second} = run_shaped(exunit_output(failures: failures), context)
      assert String.starts_with?(second.output, "↻ same 2 failures as previous run\n")
    end

    test "changed failure sets report was/now with new count" do
      enable_shaping()
      %{context: context} = scope()

      prior = [
        {"a", "test/d_test.exs:1"},
        {"b", "test/d_test.exs:2"},
        {"c", "test/d_test.exs:3"}
      ]

      current = [{"a", "test/d_test.exs:1"}, {"fresh", "test/d_test.exs:9"}]

      assert {:ok, _} = run_shaped(exunit_output(failures: prior), context)
      assert {:ok, second} = run_shaped(exunit_output(failures: current), context)

      assert String.starts_with?(second.output, "↻ failures changed: was 3, now 2 (1 new)\n")
    end

    test "no delta and no noise when both runs are green" do
      enable_shaping()
      %{context: context} = scope()

      assert {:ok, _} = run_shaped(exunit_output(failures: []), context)
      assert {:ok, second} = run_shaped(exunit_output(failures: []), context)
      refute second.output =~ "↻"
    end

    test "no session_uuid means no delta but storage still succeeds" do
      enable_shaping()
      %{tenant_id: tenant_id} = scope()

      sessionless = %{tool_context: %{tenant_id: tenant_id, actor: actor_for(tenant_id)}}
      failures = [{"x", "test/x_test.exs:1"}]

      assert {:ok, _} = run_shaped(exunit_output(failures: failures), sessionless)
      assert {:ok, second} = run_shaped(exunit_output(failures: failures), sessionless)

      refute second.output =~ "↻"
      assert second.output_ref =~ ~r/^out_/
    end
  end

  describe "shapeable?/3" do
    test "is a pure config/params/context read" do
      enable_shaping()
      %{context: context} = scope()

      assert OutputShaper.shapeable?("run_command", %{}, context)
      assert OutputShaper.shapeable?("git_diff", %{}, context)
      refute OutputShaper.shapeable?("read_file", %{}, context)
      refute OutputShaper.shapeable?("fetch_output", %{}, context)
      refute OutputShaper.shapeable?("run_command", %{stream_to_display: true}, context)
      refute OutputShaper.shapeable?("run_command", %{}, %{tool_context: %{}})
      refute OutputShaper.shapeable?("run_command", %{}, nil)
    end
  end

  describe "mcp_shapeable?/2" do
    test "true only for an mcp_-rooted name with a tenant while enabled" do
      enable_shaping()
      %{context: context} = scope()

      assert OutputShaper.mcp_shapeable?("mcp_test_echo", context)
      assert OutputShaper.mcp_shapeable?("mcp_x_y", context)

      # native + non-mcp_ names never take the generic MCP path
      refute OutputShaper.mcp_shapeable?("run_command", context)
      refute OutputShaper.mcp_shapeable?("read_file", context)
      # "mcp" without the underscore delimiter is not mcp_-rooted
      refute OutputShaper.mcp_shapeable?("mcpfoo", context)
      # no tenant in scope → storage impossible → fail closed
      refute OutputShaper.mcp_shapeable?("mcp_x_y", %{tool_context: %{}})
      # non-binary tool name → fail closed
      refute OutputShaper.mcp_shapeable?(:mcp_atom, context)
    end

    test "false when shaping is disabled regardless of name/tenant" do
      %{context: context} = scope()
      refute OutputShaper.mcp_shapeable?("mcp_x_y", context)
    end
  end

  describe "external MCP generic shaping" do
    test "oversized MCP map is collapsed, ref-stored, isError lifted" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()
      cap_output_bytes(4_096)

      big = String.duplicate("x", 6_000) <> "TAILMARK"
      data = %{"content" => [%{"type" => "text", "text" => big}], "isError" => true}

      assert byte_size(Jason.encode!(data)) > 4_096

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert result["isError"] == true
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.output) <= 4_096
      assert result.output =~ "... [elided"
      assert String.ends_with?(result.output, "fetch_output ref=#{result.output_ref}]")
      refute result.output =~ "[tool output truncated"
      assert is_integer(result.captured_bytes) and result.captured_bytes > 0
      assert result.truncated == false

      # The whole model-facing wrapper must be JSON-encodable — jido_ai
      # `Jason.encode!`s it on every turn.
      assert is_binary(Jason.encode!(result))

      # Reversibility: the full pretty-JSON (with the tail) is stored.
      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ "TAILMARK"
      assert row.tool == "mcp_test_echo"
      assert row.command == nil
      assert row.command_fingerprint == nil
    end

    test "payload above capture_bytes is tail-preserved in storage" do
      enable_shaping(capture_bytes: 8_192)
      %{tenant_id: tenant_id, context: context} = scope()
      cap_output_bytes(4_096)

      filler = String.duplicate("x", 20_000)
      text = "HEAD_SENTINEL" <> filler <> "TAIL_SENTINEL"
      data = %{"content" => [%{"text" => text}], "isError" => false}

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert result.truncated == true
      assert result.output =~ "captured output (truncated)"
      assert result.output_ref =~ ~r/^out_/

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      # The capture cap is tail-preserving (Generic.fit), so the tail — where
      # MCP errors live — survives in the stored ref.
      assert byte_size(row.content) <= 8_192
      assert row.content =~ "TAIL_SENTINEL"
      assert row.content =~ "... [elided"
    end

    test "capture_bytes below the inline cap still shapes (decision keys on original size)" do
      enable_shaping(capture_bytes: 1_024)
      %{context: context} = scope()
      cap_output_bytes(4_096)

      data = %{"content" => [%{"text" => String.duplicate("y", 6_000)}]}
      assert byte_size(Jason.encode!(data)) > 4_096

      assert {:ok, result} = run_mcp({:ok, data}, context)

      # Misconfig (capture < inline cap) must NOT cap small, skip shaping, and
      # fall to OutputLimit's ref-less cut — the >cap test keys on the full
      # serialized size, so it still shapes.
      assert result.shaped
      assert byte_size(result.output) <= 4_096
      refute result.output =~ "[tool output truncated"
    end

    test "under-cap MCP result passes through structurally (shaper no-op)" do
      enable_shaping()
      %{context: context} = scope()

      data = %{"content" => [%{"text" => "small ok"}], "isError" => false}

      assert {:ok, result} = run_mcp({:ok, data}, context)

      # Shaper-relative identity: the shaper is a no-op on its already
      # OutputRedaction-processed input (here secret/ANSI-free, so == data).
      # NOT raw-tool-output identity — Part A mutates upstream by design.
      assert result == data
      refute Map.has_key?(result, :shaped)
    end

    test "a non-JSON term is force-shaped into a JSON-safe wrapper (averts jido_ai crash)" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()

      # A bare tuple is tiny but unencodable — passing it through would later
      # crash jido_ai's Jason.encode!; the shaper collapses it instead.
      data = {:not, :json, "SAFEMARK"}

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      refute Map.has_key?(result, "isError")
      # The wrapper is JSON-encodable — the whole point of force-shaping.
      assert is_binary(Jason.encode!(result))

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      # The inspect-rendered content round-trips.
      assert row.content =~ "SAFEMARK"
    end

    test "a non-UTF-8 binary under the cap is force-shaped" do
      enable_shaping()
      %{context: context} = scope()

      data = <<0xFF, 0xFE, 0xFD>>
      refute String.valid?(data)

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      # JSON-encodable wrapper despite the non-UTF-8 source.
      assert is_binary(Jason.encode!(result))
    end

    test "many small fields summing past the cap collapse (conservative total trigger)" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      data = Map.new(1..400, fn i -> {"field_#{i}", "value number #{i}"} end)
      assert byte_size(Jason.encode!(data)) > 4_096

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert byte_size(result.output) <= 4_096
      assert result.output_ref =~ ~r/^out_/
    end

    test "no tenant in tool_context skips MCP shaping (falls to OutputLimit)" do
      enable_shaping()
      cap_output_bytes(4_096)

      data = %{"content" => [%{"text" => String.duplicate("x", 8_000)}]}

      assert {:ok, result} = run_mcp({:ok, data}, %{tool_context: %{}})

      # Shaper skipped — no ref, no shaped flag; OutputLimit did the ref-less
      # cut on the oversized nested string.
      refute Map.has_key?(result, :shaped)
      refute Map.has_key?(result, :output_ref)

      text =
        result
        |> Map.fetch!("content")
        |> hd()
        |> Map.fetch!("text")

      assert String.contains?(text, "[tool output truncated")
    end

    test "error results pass through the MCP path untouched" do
      enable_shaping()
      %{context: context} = scope()

      assert {:error, %{message: "boom"}} = run_mcp({:error, "boom"}, context)

      assert {:error, %{message: "boom"}, %{side: 1}} =
               run_mcp({:error, "boom", %{side: 1}}, context)
    end

    test "3-tuple MCP success preserves effects while shaping" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      data = %{"content" => [%{"text" => String.duplicate("z", 6_000)}]}

      assert {:ok, result, %{side: :fx}} = run_mcp({:ok, data, %{side: :fx}}, context)
      assert result.shaped
    end

    test "transient store failure degrades to shaped-without-ref, still bounded" do
      enable_shaping()
      %{tenant_id: tenant_id} = scope()
      cap_output_bytes(4_096)

      # session_uuid with no Session row → the FK check fails the insert.
      broken_context = %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: Ecto.UUID.generate(),
          actor: actor_for(tenant_id)
        }
      }

      data = %{"content" => [%{"text" => String.duplicate("x", 8_000)}], "isError" => true}

      assert {:ok, result} = run_mcp({:ok, data}, broken_context)

      assert result.shaped
      assert result["isError"] == true
      refute Map.has_key?(result, :output_ref)
      assert result.output =~ "(full output unavailable)"
      assert byte_size(result.output) <= 4_096
      refute result.output =~ "[tool output truncated"
    end

    test "oversized bare-binary MCP result is shaped with a ref and no isError key" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()
      cap_output_bytes(4_096)

      data = "PREFIX " <> String.duplicate("a", 8_000) <> " TAILMARK"

      assert {:ok, result} = run_mcp({:ok, data}, context)

      assert result.shaped
      assert result.output_ref =~ ~r/^out_/
      refute Map.has_key?(result, "isError")
      assert byte_size(result.output) <= 4_096

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ "TAILMARK"
    end

    test "disabled config leaves the MCP result byte-identical" do
      %{context: context} = scope()

      data = %{"content" => [%{"text" => "under cap"}], "isError" => false}

      assert {:ok, result} = run_mcp({:ok, data}, context)
      assert result == data
      refute Map.has_key?(result, :shaped)
    end

    test "an ANSI-split secret in an under-cap MCP result is redacted upstream" do
      enable_shaping()
      %{context: context} = scope()

      # 24 trailing chars clear the pattern's 20-char minimum.
      split = "sk-ant-\e[0mabcdefghijklmnopqrstuvwx"
      data = %{"content" => [%{"text" => "leaked #{split}"}]}

      assert {:ok, result} = run_mcp({:ok, data}, context)

      # Under-cap → structured passthrough, but the upstream OutputRedaction
      # root strip already reassembled + redacted the split secret. This is
      # what makes the passthrough safe.
      text =
        result
        |> Map.fetch!("content")
        |> hd()
        |> Map.fetch!("text")

      assert text =~ "[REDACTED:ANTHROPIC_KEY]"
      refute text =~ "abcdefghijklmnopqrstuvwx"
      refute Map.has_key?(result, :shaped)
    end

    test "isError false is preserved; absent yields no isError key" do
      enable_shaping()
      %{context: context} = scope()
      cap_output_bytes(4_096)

      big = String.duplicate("x", 6_000)

      assert {:ok, r1} = run_mcp({:ok, %{"content" => big, "isError" => false}}, context)
      assert r1.shaped
      assert r1["isError"] == false

      assert {:ok, r2} = run_mcp({:ok, %{"content" => big}}, context)
      assert r2.shaped
      refute Map.has_key?(r2, "isError")
    end
  end

  describe "external MCP generic shaping (generated proxy integration)" do
    setup do
      prior = Application.get_env(:jido_claw, :mcp_stub)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:jido_claw, :mcp_stub)
          value -> Application.put_env(:jido_claw, :mcp_stub, value)
        end
      end)

      :ok
    end

    test "a real proxy re-surfaces the dep's :tool_error promotion, shapes it, scrubs outbound ANSI" do
      enable_shaping()
      %{tenant_id: tenant_id, context: context} = scope()
      cap_output_bytes(4_096)

      test_pid = self()
      big = String.duplicate("x", 8_000) <> " TAILMARK"

      # Production shape: jido_mcp promotes a domain `isError: true` result to
      # `{:error, %{type: :tool_error, details: <raw result map>}}` (NOT a bare
      # `{:ok, data}`). The proxy re-surfaces it to `{:ok, data}` so it hits the
      # generic MCP shaper — this stub exercises that real error→data→shape path.
      Application.put_env(:jido_claw, :mcp_stub, %{
        call_tool: fn _id, name, args ->
          send(test_pid, {:stub_call, name, args})

          {:error,
           %{type: :tool_error, details: %{"content" => [%{"text" => big}], "isError" => true}}}
        end
      })

      [module] = ProxyGenerator.build_modules("svc", :svc, [%{"name" => "echo"}])
      assert module.name() == "mcp_svc_echo"

      # Outbound: an ANSI-laden arg reaches the remote stub scrubbed — the
      # intentional outbound mutation from Part A's root strip.
      assert {:ok, result} = module.run(%{"q" => "plain\e[31m text"}, context)

      assert_received {:stub_call, "echo", scrubbed_args}
      assert scrubbed_args == %{"q" => "plain text"}

      # Inbound: the oversized real-proxy result is shaped + round-trips
      # (not only the inline echo).
      assert result.shaped
      assert result["isError"] == true
      assert result.output_ref =~ ~r/^out_/
      assert byte_size(result.output) <= 4_096

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content =~ "TAILMARK"
      assert row.tool == "mcp_svc_echo"
    end
  end

  describe "AR-2 Phase 2b — sensitive sanitization (sink vii)" do
    test "a marked tool_context redacts the stored content/command/summary + nils the fingerprint" do
      enable_shaping()
      %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "shaper-sens")
      secret = "ZZSHAPESECRETZZ-#{System.unique_integer([:positive])}"

      marked = %{
        tool_context: %{
          tenant_id: tenant_id,
          session_uuid: session.id,
          actor: actor_for(tenant_id),
          sanitize_sensitive_context: true
        }
      }

      output = exunit_output(passed: 311, failures: [{secret, "test/x_test.exs:1"}])

      assert {:ok, result} = run_shaped(output, marked)
      assert result.shaped

      assert {:ok, row} =
               ToolOutput.by_ref(result.output_ref,
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert row.content == "[composer-sensitive:redacted]"
      assert row.command == "[composer-sensitive:redacted]"
      assert row.summary == %{"redacted" => true}
      assert is_nil(row.command_fingerprint)
      refute row.content =~ secret
    end
  end
end
