defmodule JidoClaw.Tools.FetchOutputTest do
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Tools.FetchOutput

  @content """
  line one
  line two ERROR here
  line three
  line four
  line five ERROR again
  line six
  """

  defp seed_output(tenant_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          ref: JidoClaw.Refs.mint("out_"),
          tool: "run_command",
          command: "mix test",
          content: String.trim_trailing(@content, "\n"),
          byte_size: byte_size(@content),
          truncated: false,
          exit_code: 1
        },
        overrides
      )

    {:ok, row} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
    row
  end

  defp context_for(tenant_id) do
    %{tool_context: %{tenant_id: tenant_id, actor: actor_for(tenant_id)}}
  end

  defp context_for(tenant_id, session_uuid) do
    %{
      tool_context: %{
        tenant_id: tenant_id,
        actor: actor_for(tenant_id),
        session_uuid: session_uuid
      }
    }
  end

  # :serve_mode is global; safe to toggle only because this module is async: false.
  defp with_serve_mode(mode, fun) do
    original = Application.fetch_env(:jido_claw, :serve_mode)
    Application.put_env(:jido_claw, :serve_mode, mode)

    try do
      fun.()
    after
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, :serve_mode, value)
        :error -> Application.delete_env(:jido_claw, :serve_mode)
      end
    end
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

  defp many_line_content(lines) do
    Enum.map_join(1..lines, "\n", fn i ->
      "match line #{i} padded#{String.duplicate("x", 20)}"
    end)
  end

  defp seed_many_lines(tenant_id, lines) do
    content = many_line_content(lines)
    seed_output(tenant_id, %{content: content, byte_size: byte_size(content)})
  end

  test "default offset/limit window returns everything with line counts" do
    tenant_id = seed_tenant("fetch")
    row = seed_output(tenant_id)

    assert {:ok, result} = FetchOutput.run(%{ref: row.ref}, context_for(tenant_id))

    assert result.total_lines == 6
    assert result.returned_lines == 6
    assert result.content =~ "line one"
    assert result.content =~ "line six"
    assert result.truncated == false
    assert result.captured_bytes == byte_size(@content)
  end

  test "grep returns matching lines with line numbers" do
    tenant_id = seed_tenant("fetch-grep")
    row = seed_output(tenant_id)

    assert {:ok, result} =
             FetchOutput.run(%{ref: row.ref, grep: "ERROR"}, context_for(tenant_id))

    assert result.returned_lines == 2
    assert result.content == "2: line two ERROR here\n5: line five ERROR again"
    assert result.total_lines == 6
  end

  test "grep takes precedence over tail/head/offset" do
    tenant_id = seed_tenant("fetch-prec")
    row = seed_output(tenant_id)

    assert {:ok, result} =
             FetchOutput.run(
               %{ref: row.ref, grep: "ERROR", tail: 1, head: 1, offset: 3},
               context_for(tenant_id)
             )

    assert result.returned_lines == 2
  end

  test "tail and head slice line windows" do
    tenant_id = seed_tenant("fetch-slices")
    row = seed_output(tenant_id)
    context = context_for(tenant_id)

    assert {:ok, tail} = FetchOutput.run(%{ref: row.ref, tail: 2}, context)
    assert tail.content == "line five ERROR again\nline six"
    assert tail.returned_lines == 2

    assert {:ok, head} = FetchOutput.run(%{ref: row.ref, head: 2}, context)
    assert head.content == "line one\nline two ERROR here"

    assert {:ok, window} = FetchOutput.run(%{ref: row.ref, offset: 2, limit: 2}, context)
    assert window.content == "line three\nline four"
    assert window.returned_lines == 2
  end

  test "invalid grep regex returns a clean tool error" do
    tenant_id = seed_tenant("fetch-badre")
    row = seed_output(tenant_id)

    assert {:error, %{message: message}} =
             FetchOutput.run(%{ref: row.ref, grep: "(unclosed"}, context_for(tenant_id))

    assert message =~ "invalid grep regex:"
  end

  test "missing ref returns a clean error" do
    tenant_id = seed_tenant("fetch-miss")

    assert {:error, %{message: message}} =
             FetchOutput.run(%{ref: "out_does_not_exist"}, context_for(tenant_id))

    assert message =~ "no stored output for ref out_does_not_exist"
  end

  test "another tenant's ref is not fetchable" do
    tenant_a = seed_tenant("fetch-tenant-a")
    tenant_b = seed_tenant("fetch-tenant-b")
    row = seed_output(tenant_a)

    assert {:error, %{message: message}} =
             FetchOutput.run(%{ref: row.ref}, context_for(tenant_b))

    assert message =~ "no stored output for ref"
  end

  test "no tenant scope returns a clean error" do
    assert {:error, %{message: message}} =
             FetchOutput.run(%{ref: "out_whatever"}, %{tool_context: %{}})

    assert message =~ "requires a tenant scope"
  end

  test "passes the truncated flag through from the stored row" do
    tenant_id = seed_tenant("fetch-trunc")
    row = seed_output(tenant_id, %{truncated: true})

    assert {:ok, result} = FetchOutput.run(%{ref: row.ref}, context_for(tenant_id))
    assert result.truncated == true
  end

  describe "clipping to the inline cap" do
    # The P2 lie: OutputLimit used to cut `content` AFTER returned_lines
    # was computed, so the metadata claimed the full selection came back.
    test "grep selecting more than fits clips with honest counts and a note" do
      tenant_id = seed_tenant("fetch-clip-grep")
      cap_output_bytes(512)
      row = seed_many_lines(tenant_id, 100)

      assert {:ok, result} =
               FetchOutput.run(%{ref: row.ref, grep: "match line"}, context_for(tenant_id))

      assert result.clipped == true
      assert result.selected_lines == 100
      assert result.returned_lines < 100
      assert byte_size(result.content) <= 512
      assert String.starts_with?(result.content, "1: match line 1 ")

      assert result.content =~
               "[fetch_output clipped: showing first #{result.returned_lines} of 100 " <>
                 "selected lines — refine with grep/head/tail/offset+limit]"

      assert String.ends_with?(result.content, "offset+limit]")
      refute result.content =~ "[tool output truncated"
    end

    test "tail clip keeps the last lines with the note on top" do
      tenant_id = seed_tenant("fetch-clip-tail")
      cap_output_bytes(512)
      row = seed_many_lines(tenant_id, 100)

      assert {:ok, result} = FetchOutput.run(%{ref: row.ref, tail: 50}, context_for(tenant_id))

      assert result.clipped == true
      assert result.selected_lines == 50
      assert result.returned_lines < 50
      assert byte_size(result.content) <= 512

      assert String.starts_with?(
               result.content,
               "[fetch_output clipped: showing last #{result.returned_lines} of 50 selected lines"
             )

      assert String.ends_with?(
               result.content,
               "match line 100 padded" <> String.duplicate("x", 20)
             )

      refute result.content =~ "[tool output truncated"
    end

    test "a single line larger than the cap is cut direction-aware" do
      tenant_id = seed_tenant("fetch-clip-line")
      cap_output_bytes(512)
      huge = "START" <> String.duplicate("m", 2_000) <> "END"
      row = seed_output(tenant_id, %{content: huge, byte_size: byte_size(huge)})
      context = context_for(tenant_id)

      assert {:ok, head} = FetchOutput.run(%{ref: row.ref, head: 1}, context)
      assert head.clipped == true
      assert head.returned_lines == 1
      assert byte_size(head.content) <= 512
      assert String.starts_with?(head.content, "START")
      refute head.content =~ "END"

      assert {:ok, tail} = FetchOutput.run(%{ref: row.ref, tail: 1}, context)
      assert tail.clipped == true
      assert byte_size(tail.content) <= 512
      assert String.ends_with?(tail.content, "END")
      refute tail.content =~ "START"
    end

    # P3 follow-up regression: a cap smaller than the note itself must
    # drop the note and spend the cap on content — never overflow into
    # the wrapper's OutputLimit marker.
    test "cap smaller than the note still self-caps: note dropped, never OutputLimit-cut" do
      tenant_id = seed_tenant("fetch-tiny-cap")
      cap_output_bytes(50)
      row = seed_many_lines(tenant_id, 100)
      context = context_for(tenant_id)

      assert {:ok, head} = FetchOutput.run(%{ref: row.ref, head: 50}, context)

      assert head.clipped == true
      assert head.selected_lines == 50
      assert head.returned_lines == 1
      assert byte_size(head.content) <= 50
      assert String.starts_with?(head.content, "match line 1 ")
      refute head.content =~ "[fetch_output clipped"
      refute head.content =~ "[tool output truncated"

      assert {:ok, tail} = FetchOutput.run(%{ref: row.ref, tail: 50}, context)

      assert tail.clipped == true
      assert byte_size(tail.content) <= 50

      assert String.ends_with?(
               tail.content,
               "match line 100 padded" <> String.duplicate("x", 20)
             )

      refute tail.content =~ "[fetch_output clipped"
      refute tail.content =~ "[tool output truncated"
    end

    test "unclipped fetch reports clipped: false and matching counts" do
      tenant_id = seed_tenant("fetch-noclip")
      row = seed_output(tenant_id)

      assert {:ok, result} = FetchOutput.run(%{ref: row.ref}, context_for(tenant_id))

      assert result.clipped == false
      assert result.selected_lines == result.returned_lines
      refute result.content =~ "[fetch_output clipped"
    end
  end

  describe "session-scoped fetch (S-M2)" do
    test "a session fetches its own ref and nil-session refs, but not a foreign session's ref" do
      %{tenant_id: tenant_id, workspace: workspace, session: session_a} =
        seed_full(tenant_label: "fetch-scoped")

      {:ok, session_b} = seed_session(tenant_id, workspace.id)

      own = seed_output(tenant_id, %{session_id: session_a.id})
      cron = seed_output(tenant_id, %{session_id: nil})

      # Session A resolves its own row...
      assert {:ok, %{content: _}} =
               FetchOutput.run(%{ref: own.ref}, context_for(tenant_id, session_a.id))

      # ...a cron / nil-session ref stays reachable from a session surface...
      assert {:ok, %{content: _}} =
               FetchOutput.run(%{ref: cron.ref}, context_for(tenant_id, session_a.id))

      # ...but session B cannot fetch session A's row (the cross-session peek).
      assert {:error, %{message: message}} =
               FetchOutput.run(%{ref: own.ref}, context_for(tenant_id, session_b.id))

      assert message =~ "no stored output for ref"
    end

    test "no session_uuid in context stays tenant-wide (unchanged)" do
      %{tenant_id: tenant_id, session: session_a} = seed_full(tenant_label: "fetch-nosess")
      own = seed_output(tenant_id, %{session_id: session_a.id})

      # A context WITHOUT a session_uuid falls back to the tenant-wide by_ref, so a
      # session-bearing ref still resolves — the no-session surfaces are unaffected.
      assert {:ok, %{content: _}} = FetchOutput.run(%{ref: own.ref}, context_for(tenant_id))
    end

    test "under :mcp serve-mode the boot scope stays tenant-wide (REPL-minted-ref drill-in)" do
      # A REPL-minted ref carries a session_id; the MCP boot scope carries its OWN,
      # different session_uuid. Under :mcp the read is tenant-wide, so the ref is
      # still fetchable (the documented drill-in). Off :mcp the SAME context is
      # session-scoped and misses — proving the :mcp branch is what keeps drill-in
      # open, not the absence of a session. (mcp_server_test.exs is metadata-only /
      # no DB sandbox, so this DB-backed behavior is unit-tested here.)
      %{tenant_id: tenant_id, workspace: workspace, session: repl_session} =
        seed_full(tenant_label: "fetch-mcp")

      {:ok, mcp_session} = seed_session(tenant_id, workspace.id)
      repl_ref = seed_output(tenant_id, %{session_id: repl_session.id})

      with_serve_mode(:mcp, fn ->
        assert {:ok, %{content: _}} =
                 FetchOutput.run(%{ref: repl_ref.ref}, context_for(tenant_id, mcp_session.id))
      end)

      # Off :mcp, the mcp_session context is session-scoped and CANNOT reach the
      # repl_session's ref.
      assert {:error, _} =
               FetchOutput.run(%{ref: repl_ref.ref}, context_for(tenant_id, mcp_session.id))
    end
  end
end
