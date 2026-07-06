defmodule JidoClaw.Tools.Lua.BindingsTest do
  # async: false — DB-backed binding reads; TenantCase's shared-sandbox
  # default (shared: not async) keeps rows visible to any process, and
  # the serve-mode / env toggles below are global. Scripts here eval
  # in-process (no Runner task) — the Runner's task isolation has its
  # own suite.
  #
  # Lua round-trip semantics the assertions accommodate: an EMPTY Lua
  # table decodes as %{} (array/map ambiguity), and a nil table value
  # means "key absent" — so nil-valued projection fields vanish from a
  # returned map. Shape assertions therefore check present-keys ⊆
  # allowlist rather than key-set equality.
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Tools.Lua.Bindings
  alias JidoClaw.Tools.Lua.CallTrace
  alias JidoClaw.Tools.Lua.Policy
  alias JidoClaw.Tools.OutputLimit

  @case_view_fields ~w(id kind status step_name tool_name details session_id
                       workflow_run_id decision decided_by_id decided_at
                       decision_comment inserted_at)

  @solution_view_fields ~w(signature language framework tags trust_score sharing
                           content inserted_at updated_at score match_type)

  setup do
    tenant_a = seed_tenant("lua-bind-a")
    tenant_b = seed_tenant("lua-bind-b")
    {:ok, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  # Eval a script against a freshly-installed binding table, in-process.
  defp eval_script(script, scope, opts \\ []) do
    policy = Policy.resolve(opts)
    {:ok, trace} = CallTrace.start_link()

    lua =
      [max_call_depth: policy.max_call_depth]
      |> Lua.new()
      |> Bindings.install(scope, trace, policy)

    try do
      {values, _lua} = Lua.eval!(lua, script)
      {:ok, Enum.map(values, &Bindings.normalize_lua_value/1)}
    rescue
      e in Lua.RuntimeException -> {:error, Exception.message(e)}
    after
      if Process.alive?(trace), do: Agent.stop(trace)
    end
  end

  defp scope_for(tenant_id, extra \\ %{}) do
    Map.merge(%{tenant_id: tenant_id, actor: actor_for(tenant_id)}, extra)
  end

  defp seed_run(tenant_id, name, attrs \\ %{}) do
    {:ok, run} =
      WorkflowRun.create(
        Map.merge(%{name: name, workflow_type: "audit"}, attrs),
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    run
  end

  defp seed_case(tenant_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          step_name: "tool:git_commit",
          details: %{"summary" => "commit please"},
          fingerprint: "fp-#{System.unique_integer([:positive])}",
          tool_name: "git_commit"
        },
        overrides
      )

    {:ok, case_record} =
      AgentCase.open_tool_call(attrs, tenant: tenant_id, actor: actor_for(tenant_id))

    case_record
  end

  defp seed_output(tenant_id, content, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          ref: JidoClaw.Refs.mint("out_"),
          tool: "run_command",
          command: "mix test",
          content: content,
          byte_size: byte_size(content),
          truncated: false,
          exit_code: 0
        },
        overrides
      )

    {:ok, row} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor_for(tenant_id))
    row
  end

  defp seed_solution(tenant_id, workspace_id, content) do
    {:ok, solution} =
      Solution.store(
        %{
          problem_signature:
            Base.encode16(
              :crypto.hash(:sha256, "sig-#{System.unique_integer([:positive])}"),
              case: :lower
            ),
          solution_content: content,
          language: "elixir",
          sharing: :local,
          workspace_id: workspace_id,
          embedding_status: :disabled,
          tags: ["lua-test"]
        },
        tenant: tenant_id,
        actor: actor_for(tenant_id)
      )

    solution
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

  describe "read-only invariant" do
    test "assert_read_only!/0 passes and every entry is read-only" do
      assert Bindings.assert_read_only!() == :ok
      assert Enum.all?(Bindings.docs(), & &1["read_only"])
    end

    test "docs/0 renders all seven bindings with complete doc fields" do
      docs = Bindings.docs()

      assert Enum.map(docs, & &1["name"]) == [
               "jido.runs",
               "jido.run",
               "jido.events",
               "jido.cases",
               "jido.debt",
               "jido.solutions",
               "jido.output"
             ]

      Enum.each(docs, fn doc ->
        for field <- ["signature", "description", "params", "returns", "example"] do
          assert doc[field], "#{doc["name"]} is missing docs field #{field}"
        end
      end)
    end
  end

  describe "jido.runs" do
    test "lists own-tenant runs and never another tenant's (two-tenant isolation)",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      run_a = seed_run(tenant_a, "mine")
      run_b = seed_run(tenant_b, "theirs")

      assert {:ok, [runs]} = eval_script("return jido.runs()", scope_for(tenant_a))
      ids = Enum.map(runs, & &1["run_id"])

      assert run_a.id in ids
      refute run_b.id in ids
    end

    test "status filter accepts a string and an array; limit clamps",
         %{tenant_a: tenant_a} do
      _active = seed_run(tenant_a, "active-run")

      # No failed runs seeded — an empty Lua table round-trips as %{}.
      assert {:ok, [empty]} =
               eval_script(~s|return jido.runs({status = "failed"})|, scope_for(tenant_a))

      assert empty == %{}

      assert {:ok, [runs]} =
               eval_script(
                 ~s|return jido.runs({status = {"pending", "running"}, limit = 1})|,
                 scope_for(tenant_a)
               )

      assert [_] = runs
    end

    test "unknown status and unknown option fail loudly (script-recoverable via pcall)",
         %{tenant_a: tenant_a} do
      assert {:error, message} =
               eval_script(~s|return jido.runs({status = "bogus"})|, scope_for(tenant_a))

      assert message =~ "unknown status"
      assert message =~ "running"

      assert {:error, message} =
               eval_script(~s|return jido.runs({wat = 1})|, scope_for(tenant_a))

      assert message =~ "unknown option"

      # pcall catches the bad-arg raise — by design.
      assert {:ok, [false, caught]} =
               eval_script(
                 ~s|local ok, err = pcall(function() return jido.runs({wat = 1}) end)\n| <>
                   ~s|return ok, err|,
                 scope_for(tenant_a)
               )

      assert caught =~ "unknown option"
    end
  end

  describe "jido.run" do
    test "returns the snapshot for an own-tenant run and nil across tenants",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      run_a = seed_run(tenant_a, "snap")
      run_b = seed_run(tenant_b, "hidden")

      assert {:ok, [view]} =
               eval_script(~s|return jido.run("#{run_a.id}")|, scope_for(tenant_a))

      assert view["run_id"] == run_a.id
      assert view["status"] == "pending"

      assert {:ok, [true]} =
               eval_script(~s|return jido.run("#{run_b.id}") == nil|, scope_for(tenant_a))
    end

    test "non-string id fails loudly", %{tenant_a: tenant_a} do
      assert {:error, message} = eval_script("return jido.run(42)", scope_for(tenant_a))
      assert message =~ "jido.run takes one run id string"
    end
  end

  describe "jido.events" do
    test "reads a run's feed with translated opts; cross-tenant read errors not-found",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      run_a = seed_run(tenant_a, "evented")
      run_b = seed_run(tenant_b, "hidden")

      assert {:ok, [feed]} =
               eval_script(
                 ~s|return jido.events("#{run_a.id}", {after_seq = 0, limit = 5})|,
                 scope_for(tenant_a)
               )

      assert feed["run_id"] == run_a.id
      assert feed["count"] == 0
      # No events — the empty list round-trips as an empty table (%{}).
      assert feed["events"] == %{}

      assert {:error, message} =
               eval_script(~s|return jido.events("#{run_b.id}")|, scope_for(tenant_a))

      assert message =~ "run not found"
    end

    test "non-integer limit fails loudly", %{tenant_a: tenant_a} do
      run = seed_run(tenant_a, "evented")

      assert {:error, message} =
               eval_script(
                 ~s|return jido.events("#{run.id}", {limit = "ten"})|,
                 scope_for(tenant_a)
               )

      assert message =~ "limit must be an integer"
    end
  end

  describe "jido.cases" do
    test "projection is the fixed field allowlist — no raw-struct leakage",
         %{tenant_a: tenant_a} do
      _case = seed_case(tenant_a)

      assert {:ok, [[case_view]]} = eval_script("return jido.cases()", scope_for(tenant_a))

      # Nil-valued fields drop out in the Lua round trip, so: present ⊆ allowlist.
      assert Enum.all?(Map.keys(case_view), &(&1 in @case_view_fields))

      assert case_view["kind"] == "tool_call"
      assert case_view["status"] == "pending"
      assert case_view["tool_name"] == "git_commit"
      assert case_view["step_name"] == "tool:git_commit"
      assert case_view["details"] == %{"summary" => "commit please"}
      assert is_binary(case_view["id"])
      assert is_binary(case_view["inserted_at"])

      # The sensitive/system columns stay out.
      refute Map.has_key?(case_view, "fingerprint")
      refute Map.has_key?(case_view, "gate_module")
      refute Map.has_key?(case_view, "tenant_id")
      refute Map.has_key?(case_view, "consumed_at")
    end

    test "limit clamps and two-tenant isolation holds",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      for _ <- 1..3, do: seed_case(tenant_a)
      b_case = seed_case(tenant_b)

      assert {:ok, [cases]} =
               eval_script("return jido.cases({limit = 2})", scope_for(tenant_a))

      assert [_, _] = cases

      # limit = 0 clamps up to 1, never unbounded.
      assert {:ok, [clamped]} =
               eval_script("return jido.cases({limit = 0})", scope_for(tenant_a))

      assert [_] = clamped

      assert {:ok, [all_a]} =
               eval_script("return jido.cases({limit = 50})", scope_for(tenant_a))

      refute b_case.id in Enum.map(all_a, & &1["id"])
    end

    test "session = true scopes to the calling session and errors without one",
         %{tenant_a: tenant_a} do
      {:ok, workspace} = seed_workspace(tenant_a)
      {:ok, session_one} = seed_session(tenant_a, workspace.id)
      {:ok, session_two} = seed_session(tenant_a, workspace.id)

      mine = seed_case(tenant_a, %{session_id: session_one.id})
      _other = seed_case(tenant_a, %{session_id: session_two.id})

      assert {:ok, [cases]} =
               eval_script(
                 "return jido.cases({session = true})",
                 scope_for(tenant_a, %{session_uuid: session_one.id})
               )

      assert Enum.map(cases, & &1["id"]) == [mine.id]

      assert {:error, message} =
               eval_script("return jido.cases({session = true})", scope_for(tenant_a))

      assert message =~ "needs a session scope"
    end

    test "run_id and session together fail loudly", %{tenant_a: tenant_a} do
      run = seed_run(tenant_a, "both")

      assert {:error, message} =
               eval_script(
                 ~s|return jido.cases({run_id = "#{run.id}", session = true})|,
                 scope_for(tenant_a)
               )

      assert message =~ "not both"
    end
  end

  describe "jido.solutions" do
    setup %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, ws_a} = seed_workspace(tenant_a)
      {:ok, ws_b} = seed_workspace(tenant_b)
      {:ok, ws_a: ws_a, ws_b: ws_b}
    end

    test "projection keeps allowlisted fields only and drops the vector machinery",
         %{tenant_a: tenant_a, ws_a: ws_a} do
      _sol = seed_solution(tenant_a, ws_a.id, "use FOR UPDATE to fence approvals")

      scope = scope_for(tenant_a, %{workspace_uuid: ws_a.id})

      assert {:ok, [[view | _]]} =
               eval_script(~s|return jido.solutions("fence approvals FOR UPDATE")|, scope)

      # Nil-valued fields drop out in the Lua round trip, so: present ⊆ allowlist.
      assert Enum.all?(Map.keys(view), &(&1 in @solution_view_fields))

      assert view["content"] =~ "FOR UPDATE"
      assert view["language"] == "elixir"
      assert view["sharing"] == "local"
      assert view["match_type"] in ["exact", "fuzzy"]
      assert is_number(view["score"])

      refute Map.has_key?(view, "embedding")
      refute Map.has_key?(view, "search_vector")
      refute Map.has_key?(view, "lexical_text")
      refute Map.has_key?(view, "workspace_id")
    end

    test "content is bounded to 4KB", %{tenant_a: tenant_a, ws_a: ws_a} do
      big = "needle marker " <> String.duplicate("x", 10_000)
      _sol = seed_solution(tenant_a, ws_a.id, big)

      scope = scope_for(tenant_a, %{workspace_uuid: ws_a.id})

      assert {:ok, [[view | _]]} =
               eval_script(~s|return jido.solutions("needle marker")|, scope)

      assert byte_size(view["content"]) <= 4 * 1024 + byte_size("… (truncated)")
      assert view["content"] =~ "(truncated)"
    end

    test "two-tenant isolation: tenant A cannot see tenant B's solutions",
         %{tenant_a: tenant_a, tenant_b: tenant_b, ws_a: ws_a, ws_b: ws_b} do
      _theirs = seed_solution(tenant_b, ws_b.id, "secret vault rotation runbook")

      scope = scope_for(tenant_a, %{workspace_uuid: ws_a.id})

      assert {:ok, [empty]} =
               eval_script(~s|return jido.solutions("secret vault rotation")|, scope)

      assert empty == %{}
    end

    test "missing workspace scope fails loudly", %{tenant_a: tenant_a} do
      assert {:error, message} =
               eval_script(~s|return jido.solutions("anything")|, scope_for(tenant_a))

      assert message =~ "workspace scope"
    end

    test "never resolves embeddings (no policy lookup, no Voyage) even on a :default-policy workspace",
         %{tenant_a: tenant_a} do
      # A :default-policy workspace WOULD resolve embeddings on the normal
      # matcher path; with no API key that path logs its skip-fallback line
      # ("[Matcher] Voyage embedding …"). The binding pins
      # resolve_embedding?: false, so neither resolution nor fallback ever
      # runs — no such log. (matcher_test pins the opt's own contract.)
      original_key = System.get_env("VOYAGE_API_KEY")
      System.delete_env("VOYAGE_API_KEY")

      on_exit(fn ->
        if original_key, do: System.put_env("VOYAGE_API_KEY", original_key)
      end)

      {:ok, ws} = seed_workspace(tenant_a, embedding_policy: :default)
      _sol = seed_solution(tenant_a, ws.id, "ecto sandbox ownership timeout")

      scope = scope_for(tenant_a, %{workspace_uuid: ws.id})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, [results]} =
                   eval_script(~s|return jido.solutions("ecto sandbox ownership")|, scope)

          assert [_ | _] = results
        end)

      refute log =~ "[Matcher] Voyage embedding"
    end
  end

  describe "jido.output" do
    test "reads an own-tenant ref and returns nil for another tenant's (isolation)",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      row_a = seed_output(tenant_a, "alpha output body")
      row_b = seed_output(tenant_b, "beta output body")

      scope = scope_for(tenant_a)

      assert {:ok, [slice]} =
               eval_script(~s|return jido.output("#{row_a.ref}")|, scope)

      assert slice["content"] == "alpha output body"
      assert slice["total_bytes"] == byte_size("alpha output body")
      assert slice["returned_bytes"] == slice["total_bytes"]
      assert slice["clipped"] == false
      assert slice["truncated"] == false

      assert {:ok, [true]} =
               eval_script(~s|return jido.output("#{row_b.ref}") == nil|, scope)
    end

    test "S-M2: session-scoped on non-MCP surfaces; tenant-wide under :mcp serve mode",
         %{tenant_a: tenant_a} do
      {:ok, workspace} = seed_workspace(tenant_a)
      {:ok, session_one} = seed_session(tenant_a, workspace.id)
      {:ok, session_two} = seed_session(tenant_a, workspace.id)

      other_row = seed_output(tenant_a, "session-two secret log", %{session_id: session_two.id})
      system_row = seed_output(tenant_a, "system-minted log")

      scope = scope_for(tenant_a, %{session_uuid: session_one.id})

      # Another session's row is invisible from session one…
      assert {:ok, [true]} =
               eval_script(~s|return jido.output("#{other_row.ref}") == nil|, scope)

      # …while system/cron-minted (session_id: nil) rows stay reachable.
      assert {:ok, [slice]} =
               eval_script(~s|return jido.output("#{system_row.ref}")|, scope)

      assert slice["content"] == "system-minted log"

      # Under :mcp serve mode the boot scope is tenant-wide (the documented
      # REPL-minted-ref drill-in flow).
      with_serve_mode(:mcp, fn ->
        assert {:ok, [slice]} =
                 eval_script(~s|return jido.output("#{other_row.ref}")|, scope)

        assert slice["content"] == "session-two secret log"
      end)
    end

    test "offset landing mid-codepoint yields UTF-8-safe content with honest metadata",
         %{tenant_a: tenant_a} do
      # "aé" is bytes <<97, 195, 169>> — offset 2 lands on the é continuation byte.
      row = seed_output(tenant_a, "aébcdef")

      assert {:ok, [slice]} =
               eval_script(
                 ~s|return jido.output("#{row.ref}", {offset = 2})|,
                 scope_for(tenant_a)
               )

      assert String.valid?(slice["content"])
      assert slice["content"] == "bcdef"
      assert slice["offset"] == 2
      assert slice["returned_bytes"] == byte_size("bcdef")
      assert slice["clipped"] == true
    end

    test "max_bytes is ceilinged at OutputLimit.max_bytes() so metadata never lies",
         %{tenant_a: tenant_a} do
      cap = OutputLimit.max_bytes()
      row = seed_output(tenant_a, String.duplicate("z", cap + 5_000))

      assert {:ok, [slice]} =
               eval_script(
                 ~s|return jido.output("#{row.ref}", {max_bytes = 999999999})|,
                 scope_for(tenant_a)
               )

      assert slice["returned_bytes"] == cap
      assert byte_size(slice["content"]) == cap
      assert slice["clipped"] == true
      assert slice["total_bytes"] == cap + 5_000
    end

    test "negative offset fails loudly", %{tenant_a: tenant_a} do
      row = seed_output(tenant_a, "body")

      assert {:error, message} =
               eval_script(
                 ~s|return jido.output("#{row.ref}", {offset = -1})|,
                 scope_for(tenant_a)
               )

      assert message =~ "non-negative"
    end
  end

  describe "call budget" do
    test "reserve refusal surfaces as a Lua error and latches refused?",
         %{tenant_a: tenant_a} do
      policy = Policy.resolve(max_calls: 2)
      {:ok, trace} = CallTrace.start_link()

      lua = Bindings.install(Lua.new(), scope_for(tenant_a), trace, policy)

      script = "jido.runs() jido.runs() return jido.runs()"

      assert_raise Lua.RuntimeException, ~r/budget exceeded/, fn ->
        Lua.eval!(lua, script)
      end

      assert CallTrace.refused?(trace)
      assert [_, _] = CallTrace.calls(trace)
      Agent.stop(trace)
    end
  end
end
