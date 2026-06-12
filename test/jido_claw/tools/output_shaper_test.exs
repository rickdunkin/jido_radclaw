defmodule JidoClaw.Tools.OutputShaperTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.ToolOutput
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
      assert result.output_ref =~ ~r/^out_[0-9a-f]{12}$/
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

      # The escape splits the key so the upstream OutputRedaction pass
      # misses it; stripping reassembles it. 24 trailing chars clear the
      # pattern's 20-char minimum.
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
      assert result.output =~ "[captured output (upstream-truncated):"
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
end
