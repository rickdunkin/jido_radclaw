defmodule JidoClaw.MCP.ConsumerTest do
  @moduledoc """
  The boot prep + attach coordinator against a stub client and a real
  `JidoClaw.Agent`: fire-and-forget attach, bounded `ensure_attached`
  (immediate / deferred / `:already` fast path / crash flush / success-empty),
  partial-registration retry semantics, and the serve-mode/test gate.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.AgentTracker
  alias JidoClaw.MCP
  alias JidoClaw.MCP.Consumer
  alias JidoClaw.MCP.ProxyGenerator

  @server %{"name" => "stub", "transport" => "streamable_http", "url" => "http://localhost:1/mcp"}
  @tool_name "mcp_stub_ping"

  setup do
    prior_stub = Application.get_env(:jido_claw, :mcp_stub)
    # `:persistent_term` is global + unsandboxed, and the success-path tests
    # publish the policy key. Snapshot it and restore-or-erase it in `on_exit`
    # so every Consumer-starting test is hygienic and order-independent.
    policy_key = MCP.policy_key()
    prior_policy = :persistent_term.get(policy_key, :__absent__)

    on_exit(fn ->
      restore(:mcp_stub, prior_stub)
      restore_policy(policy_key, prior_policy)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)

  defp restore_policy(key, :__absent__), do: :persistent_term.erase(key)
  defp restore_policy(key, value), do: :persistent_term.put(key, value)

  defp stub(map), do: Application.put_env(:jido_claw, :mcp_stub, map)

  # A streamable_http server map with an optional `templates:` reach-allowlist;
  # the discovered tool's local name is `mcp_<name>_ping`.
  defp server(name, opts \\ []) do
    base = %{"name" => name, "transport" => "streamable_http", "url" => "http://localhost:1/mcp"}
    Enum.reduce(opts, base, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
  end

  defp tool_name(server_name), do: "mcp_#{server_name}_ping"

  defp ping_tool,
    do: %{"name" => "ping", "inputSchema" => %{"type" => "object", "properties" => %{}}}

  defp start_consumer!(servers), do: start_supervised!({Consumer, servers: servers})

  defp start_agent! do
    id = "mcp-consumer-test-#{System.unique_integer([:positive])}"
    {:ok, pid} = JidoClaw.Jido.start_subagent(JidoClaw.Agent, id: id)
    # `:shutdown` is a normal-ish reason (no error log); the subagent is
    # :temporary so it is not resurrected.
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    pid
  end

  # `list_tools` that announces it is blocked (sending the task pid) and waits
  # for the test to `:release` — lets us pin the Consumer in `:preparing`.
  defp blocking_list_tools(test_pid, tools) do
    fn _id, _timeout ->
      send(test_pid, {:listing, self()})

      receive do
        :release -> {:ok, tools}
      after
        10_000 -> {:ok, tools}
      end
    end
  end

  defp assert_eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(20) && do_eventually(fun, deadline)
    end
  end

  # Pin prep in `:preparing` via a blocking `list_tools`, hard-kill the prep
  # process, and barrier until the Consumer has processed the `:DOWN`. Both the
  # fixed (`:failed`) and unfixed (`:ready`) handlers clear `prep_pid`, so this
  # barrier is a version-agnostic "DOWN handled" signal — the tests then fail at
  # the meaningful assertion, not a setup timeout. Returns the started Consumer.
  defp crash_prep! do
    stub(%{list_tools: blocking_list_tools(self(), [ping_tool()])})
    consumer = start_consumer!([@server])

    assert_receive {:listing, _task_pid}, 2_000
    Process.exit(:sys.get_state(consumer).prep_pid, :kill)
    assert_eventually(fn -> :sys.get_state(consumer).prep_pid == nil end)

    consumer
  end

  defp has_tool?(pid, name), do: match?({:ok, true}, Jido.AI.has_tool?(pid, name))

  describe "gating predicate" do
    test "start?/2 is off in :mcp serve mode and when disabled, on otherwise" do
      assert Consumer.start?(:cli, true)
      assert Consumer.start?(:gateway, true)
      assert Consumer.start?(:both, true)
      refute Consumer.start?(:mcp, true)
      refute Consumer.start?(:cli, false)
    end
  end

  describe "attach_to_agent (fire-and-forget)" do
    test "registers the discovered proxy and is idempotent" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      start_consumer!([@server])
      agent = start_agent!()

      assert :ok = MCP.attach_to_agent(agent, "main")
      assert_eventually(fn -> has_tool?(agent, @tool_name) end)

      # A second attach must not double-register.
      assert :ok = MCP.attach_to_agent(agent, "main")
      assert_eventually(fn -> has_tool?(agent, @tool_name) end)

      {:ok, tools} = Jido.AI.list_tools(agent)
      assert Enum.count(tools, &(&1.name() == @tool_name)) == 1
    end

    test "an attach during :preparing lands once prep completes (deferred)" do
      test_pid = self()
      stub(%{list_tools: blocking_list_tools(test_pid, [ping_tool()])})
      consumer = start_consumer!([@server])
      agent = start_agent!()

      assert_receive {:listing, task_pid}, 2_000
      assert :sys.get_state(consumer).status == :preparing

      assert :ok = MCP.attach_to_agent(agent, "main")
      send(task_pid, :release)

      assert_eventually(fn -> has_tool?(agent, @tool_name) end)
    end
  end

  describe "ensure_attached (bounded, request path)" do
    test "returns the tools and registers when already :ready" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert {:ok, true} = Jido.AI.has_tool?(agent, @tool_name)
    end

    test "a second ensure_attached on an attached pid fast-returns :already" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert :already = MCP.ensure_attached(agent, "main", 3_000)
    end

    test "blocks during :preparing then returns with the tool present" do
      test_pid = self()
      stub(%{list_tools: blocking_list_tools(test_pid, [ping_tool()])})
      consumer = start_consumer!([@server])
      agent = start_agent!()

      assert_receive {:listing, task_pid}, 2_000

      waiter = Task.async(fn -> MCP.ensure_attached(agent, "main", 5_000) end)
      assert_eventually(fn -> :sys.get_state(consumer).waiters != [] end)

      send(task_pid, :release)

      assert :ok = Task.await(waiter, 5_000)
      assert {:ok, true} = Jido.AI.has_tool?(agent, @tool_name)
    end

    test "success-empty prep (no tools) returns :ok and marks attached" do
      stub(%{list_tools: fn _id, _t -> {:ok, []} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert MapSet.member?(:sys.get_state(consumer).attached, agent)
    end

    test "a prep crash flushes blocked callers with :mcp_unavailable, unattached" do
      test_pid = self()
      stub(%{list_tools: blocking_list_tools(test_pid, [ping_tool()])})
      consumer = start_consumer!([@server])
      agent = start_agent!()

      assert_receive {:listing, _task_pid}, 2_000

      waiter = Task.async(fn -> MCP.ensure_attached(agent, "main", 5_000) end)
      assert_eventually(fn -> :sys.get_state(consumer).waiters != [] end)

      prep_pid = :sys.get_state(consumer).prep_pid
      Process.exit(prep_pid, :kill)

      assert :mcp_unavailable = Task.await(waiter, 5_000)
      refute MapSet.member?(:sys.get_state(consumer).attached, agent)
    end
  end

  describe "hard prep crash (:failed)" do
    test "a later ensure_attached is :mcp_unavailable and never marks attached" do
      consumer = crash_prep!()
      agent = start_agent!()

      # `:mcp_unavailable` must be the FIRST assertion: on unfixed code this
      # path returns `:ok` and fires an async `mark_attached` cast, which a
      # later `attached` check could observe non-deterministically.
      assert :mcp_unavailable = MCP.ensure_attached(agent, "main", 1_000)
      refute MapSet.member?(:sys.get_state(consumer).attached, agent)
      assert :sys.get_state(consumer).status == :failed
    end

    test "republishes an empty (fail-closed) approval policy" do
      :persistent_term.put(MCP.policy_key(), %{"mcp_stale_tool" => false})

      crash_prep!()

      assert MCP.approval_policy() == %{}
    end

    test "attach_to_agent replies :ok without crashing the Consumer" do
      consumer = crash_prep!()
      agent = start_agent!()

      assert :ok = MCP.attach_to_agent(agent, "main")
      assert Process.alive?(consumer)
      assert :sys.get_state(consumer).status == :failed
    end

    test "a mark is dropped even with a matching generation (status guard)" do
      consumer = crash_prep!()
      agent = start_agent!()

      # Even this incarnation's own generation can't re-arm a :failed Consumer —
      # the status guard drops the mark before the generation match is reached.
      generation = :sys.get_state(consumer).generation
      GenServer.cast(consumer, {:mark_attached, agent, generation})
      # `:sys.get_state` is a FIFO barrier — it flushes the cast first.
      refute MapSet.member?(:sys.get_state(consumer).attached, agent)
    end
  end

  describe "mark_attached generation fence" do
    test "a generation-mismatched mark is dropped while :ready (self-healing)" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      # A registration task from a prior (crashed) incarnation carries a stale
      # token that never matches this one, so its mark is dropped — the pid
      # stays free rather than being falsely marked against a stale module set.
      GenServer.cast(consumer, {:mark_attached, agent, make_ref()})
      refute MapSet.member?(:sys.get_state(consumer).attached, agent)

      # Self-heal: a current-generation ensure_attached still attaches normally.
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert MapSet.member?(:sys.get_state(consumer).attached, agent)
    end
  end

  describe "per-template reach" do
    setup do
      # The Consumer reads the globally-named singleton AgentTracker on
      # `:prepared` fan-out; reset it so rehydrate assertions never pick up
      # stale tracked entries (and so tests 1–5/7 fan out to an empty tracker).
      AgentTracker.reset()
      _ = AgentTracker.get_state()
      on_exit(fn -> AgentTracker.reset() end)
      :ok
    end

    test "an empty allowlist grants the tool to every template (back-compat)" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()
      researcher = start_agent!()

      assert :ok = MCP.ensure_attached(coder, "coder", 3_000)
      assert :ok = MCP.ensure_attached(researcher, "researcher", 3_000)

      assert has_tool?(coder, @tool_name)
      assert has_tool?(researcher, @tool_name)
    end

    test "a restricted allowlist grants the tool only to listed templates" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([server("stub", templates: ["coder"])])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()
      other = start_agent!()

      assert :ok = MCP.ensure_attached(coder, "coder", 3_000)
      assert has_tool?(coder, @tool_name)

      # An un-allowlisted template's empty filtered set registers vacuously, so
      # ensure_attached still reports :ok — but the tool must NOT be present.
      # The :ok-vs-has_tool? distinction is the whole point of reach: the tool
      # is withheld at *registration*, never advertised to the LLM, not merely
      # gated at call time.
      assert :ok = MCP.ensure_attached(other, "researcher", 3_000)
      refute has_tool?(other, @tool_name)
    end

    test "the fire-and-forget attach path respects the allowlist" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([server("stub", templates: ["coder"])])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()
      other = start_agent!()

      assert :ok = MCP.attach_to_agent(coder, "coder")
      assert :ok = MCP.attach_to_agent(other, "researcher")

      assert_eventually(fn -> has_tool?(coder, @tool_name) end)
      # Once `other`'s empty registration completes it is marked attached and
      # can never gain the tool — a deterministic refute.
      assert_eventually(fn -> MapSet.member?(:sys.get_state(consumer).attached, other) end)
      refute has_tool?(other, @tool_name)
    end

    test "a deferred (:preparing) fire-and-forget attach lands filtered" do
      stub(%{list_tools: blocking_list_tools(self(), [ping_tool()])})
      consumer = start_consumer!([server("stub", templates: ["coder"])])
      coder = start_agent!()
      other = start_agent!()

      assert_receive {:listing, task_pid}, 2_000
      assert :sys.get_state(consumer).status == :preparing

      assert :ok = MCP.attach_to_agent(coder, "coder")
      assert :ok = MCP.attach_to_agent(other, "researcher")
      send(task_pid, :release)

      # Exercises fan_out_to_pending using the now-used stashed per-pid template.
      assert_eventually(fn -> has_tool?(coder, @tool_name) end)
      assert_eventually(fn -> MapSet.member?(:sys.get_state(consumer).attached, other) end)
      refute has_tool?(other, @tool_name)
    end

    test "union: a pid gets every unrestricted server's tools plus the restricted ones it is listed for" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([server("alpha"), server("beta", templates: ["coder"])])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()
      researcher = start_agent!()

      assert :ok = MCP.ensure_attached(coder, "coder", 3_000)
      assert :ok = MCP.ensure_attached(researcher, "researcher", 3_000)

      # coder is allowlisted on beta and everyone is on alpha → both tools.
      assert has_tool?(coder, tool_name("alpha"))
      assert has_tool?(coder, tool_name("beta"))

      # researcher gets the unrestricted server only — the key guarantee.
      assert has_tool?(researcher, tool_name("alpha"))
      refute has_tool?(researcher, tool_name("beta"))
    end

    test "tracked fan-out registers each tracked pid's allowed subset and skips already-attached pids" do
      stub(%{list_tools: blocking_list_tools(self(), [ping_tool()])})
      consumer = start_consumer!([server("stub", templates: ["coder"])])

      assert_receive {:listing, task_pid}, 2_000

      coder = start_agent!()
      researcher = start_agent!()
      already = start_agent!()

      n = System.unique_integer([:positive])
      :ok = AgentTracker.register("reach-coder-#{n}", coder, "coder", "t")
      :ok = AgentTracker.register("reach-researcher-#{n}", researcher, "researcher", "t")
      :ok = AgentTracker.register("reach-already-#{n}", already, "coder", "t")

      # Seed `already` into the attached set so the fan-out's pid-membership
      # reject (the tracked-tuple fix) skips it — proving the reject keys on the
      # pid, not the {pid, template} tuple tracked_live_pids now returns.
      :sys.replace_state(consumer, fn s -> %{s | attached: MapSet.put(s.attached, already)} end)

      send(task_pid, :release)

      # coder (allowlisted, not yet attached) gets the tool via fan-out.
      assert_eventually(fn -> has_tool?(coder, @tool_name) end)
      # researcher (not allowlisted) is filtered out; `already` (pre-attached)
      # is skipped entirely — neither ever gains the tool.
      refute has_tool?(researcher, @tool_name)
      refute has_tool?(already, @tool_name)
    end

    test "a second ensure_attached under the same template fast-returns :already, tool set unchanged" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([server("stub", templates: ["coder"])])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()

      assert :ok = MCP.ensure_attached(coder, "coder", 3_000)
      assert has_tool?(coder, @tool_name)

      assert :already = MCP.ensure_attached(coder, "coder", 3_000)

      {:ok, tools} = Jido.AI.list_tools(coder)
      assert Enum.count(tools, &(&1.name() == @tool_name)) == 1
    end
  end

  describe "register_modules" do
    test "returns :partial onto a dead pid without crashing (per-module try/catch)" do
      [module] = ProxyGenerator.build_modules("stub", :stub, [ping_tool()])

      agent = start_agent!()
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, _reason}

      assert :partial = Consumer.register_modules(agent, [module])
    end
  end
end
