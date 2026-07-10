defmodule JidoClaw.MCP.ConsumerTest do
  @moduledoc """
  The boot prep + attach coordinator against a stub client and a real
  `JidoClaw.Agent`: fire-and-forget attach, bounded `ensure_attached`
  (immediate / deferred / `:already` fast path / crash flush / success-empty),
  partial-registration retry semantics, the serve-mode/test gate, bounded
  crash-recovery re-prep (transient recovery + max-attempts exhaustion), and
  periodic re-discovery (added/removed/changed tools, refresh-on-failure, the
  in-flight-attach generation fence, no-op ticks, stale results, crash).
  """
  use ExUnit.Case, async: false

  alias Jido.Agent.Strategy.State, as: StrategyState
  alias JidoClaw.AgentTracker
  alias JidoClaw.MCP
  alias JidoClaw.MCP.AgentAPIStub
  alias JidoClaw.MCP.Consumer
  alias JidoClaw.MCP.EndpointConfig
  alias JidoClaw.MCP.ProxyGenerator

  @server %{"name" => "stub", "transport" => "streamable_http", "url" => "http://localhost:1/mcp"}
  @tool_name "mcp_stub_ping"
  @pong_name "mcp_stub_pong"

  setup do
    prior_stub = Application.get_env(:jido_claw, :mcp_stub)
    prior_agent_api_stub = Application.get_env(:jido_claw, :mcp_agent_api_stub)
    # `:persistent_term` is global + unsandboxed, and the success-path tests
    # publish the policy key. Snapshot it and restore-or-erase it in `on_exit`
    # so every Consumer-starting test is hygienic and order-independent.
    policy_key = MCP.policy_key()
    prior_policy = :persistent_term.get(policy_key, :__absent__)

    on_exit(fn ->
      restore(:mcp_stub, prior_stub)
      restore(:mcp_agent_api_stub, prior_agent_api_stub)
      restore_policy(policy_key, prior_policy)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:jido_claw, key)
  defp restore(key, value), do: Application.put_env(:jido_claw, key, value)

  defp restore_policy(key, :__absent__), do: :persistent_term.erase(key)
  defp restore_policy(key, value), do: :persistent_term.put(key, value)

  defp stub(map), do: Application.put_env(:jido_claw, :mcp_stub, map)

  # Override the `:mcp` config (backoff / interval) for one test, restoring the
  # test.exs baseline afterward.
  defp put_mcp_env(overrides) do
    prior = Application.get_env(:jido_claw, :mcp)
    Application.put_env(:jido_claw, :mcp, overrides)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:jido_claw, :mcp, prior),
        else: Application.delete_env(:jido_claw, :mcp)
    end)
  end

  # A streamable_http server map with an optional `templates:` reach-allowlist;
  # the discovered tool's local name is `mcp_<name>_ping`.
  defp server(name, opts \\ []) do
    base = %{"name" => name, "transport" => "streamable_http", "url" => "http://localhost:1/mcp"}
    Enum.reduce(opts, base, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
  end

  defp tool_name(server_name), do: "mcp_#{server_name}_ping"

  defp endpoint_ids(servers) do
    {specs, []} = EndpointConfig.parse(servers)
    Map.new(specs, &{&1.name, &1.endpoint.id})
  end

  defp ping_tool(schema \\ %{"type" => "object", "properties" => %{}}),
    do: %{"name" => "ping", "inputSchema" => schema}

  defp pong_tool,
    do: %{"name" => "pong", "inputSchema" => %{"type" => "object", "properties" => %{}}}

  # A second `ping` schema → the same stable module with a new definition digest;
  # re-discovery must refresh the agent's cached ReqLLM metadata.
  defp ping_schema_b,
    do: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}

  defp start_consumer!(servers, opts \\ []) do
    start_supervised!({Consumer, Keyword.put(opts, :servers, servers)})
  end

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

  # An Agent-counter-gated `list_tools`: call N is looked up in `by_attempt`
  # (`%{n => result}`); `:block` announces the task pid and blocks forever (so a
  # test can hard-kill that prep), any other value is returned as-is, and calls
  # past the last mapping fall to `default`. Single-sourced so the recovery and
  # re-discovery tests share one shape.
  defp counter_stub(test_pid, by_attempt, default) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    fun = fn _id, _timeout ->
      n = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

      case Map.get(by_attempt, n, default) do
        :block ->
          send(test_pid, {:listing, self()})

          receive do
            :release -> default
          after
            10_000 -> default
          end

        result ->
          result
      end
    end

    %{list_tools: fun}
  end

  # A `list_tools` that fails until `refresh_endpoint` flips an Agent flag, so a
  # success genuinely PROVES the refresh-on-failure path ran (a stub that simply
  # succeeded on the 2nd call would pass without ever refreshing).
  defp refresh_gated_stub(test_pid) do
    {:ok, flag} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(flag), do: Agent.stop(flag) end)

    %{
      list_tools: fn _id, _timeout ->
        if Agent.get(flag, & &1), do: {:ok, [ping_tool()]}, else: {:error, :unreachable}
      end,
      refresh_endpoint: fn _id ->
        Agent.update(flag, fn _ -> true end)
        send(test_pid, :refreshed)
        :ok
      end
    }
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

  # Drive the bounded re-prep to exhaustion: with `reprep_max_attempts: 2`, the
  # 1st/2nd kills retry and the 3rd exhausts to a terminal `:failed`.
  defp exhaust_prep! do
    stub(%{list_tools: blocking_list_tools(self(), [ping_tool()])})
    consumer = start_consumer!([@server])

    for _ <- 1..3 do
      before = :sys.get_state(consumer).reprep_attempts
      assert_receive {:listing, _child}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).reprep_attempts > before end)
    end

    assert_eventually(fn -> :sys.get_state(consumer).status == :failed end)
    consumer
  end

  defp has_tool?(pid, name), do: match?({:ok, true}, Jido.AI.has_tool?(pid, name))

  defp ping_module(schema \\ %{"type" => "object", "properties" => %{}}) do
    %{"stub" => endpoint_id} = endpoint_ids([@server])
    [module] = ProxyGenerator.build_modules("stub", endpoint_id, [ping_tool(schema)])
    module
  end

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

    test "long cross-server prefixes cannot collide or overwrite approval policy" do
      shared = "server_" <> String.duplicate("x", 80)
      server_a = server(shared <> "a", require_approval: false)
      server_b = server(shared <> "b", require_approval: true)

      stub(%{list_tools: fn _id, _timeout -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([server_a, server_b])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      [module_a, module_b] = :sys.get_state(consumer).modules
      refute module_a.name() == module_b.name()

      policy = MCP.approval_policy()
      assert policy[module_a.name()] == false
      assert policy[module_b.name()] == true
      assert map_size(Map.take(policy, [module_a.name(), module_b.name()])) == 2
    end

    test "short boundary collisions keep backend, approval, and reach bindings under reorder" do
      server_a =
        server("collisioncase",
          require_approval: false,
          templates: ["main"]
        )

      server_a_b =
        server("collisioncase_part",
          require_approval: true,
          templates: ["coder"]
        )

      ids = endpoint_ids([server_a, server_a_b])
      id_a = ids["collisioncase"]
      id_a_b = ids["collisioncase_part"]

      stub(%{
        list_tools: fn endpoint_id, _timeout ->
          tools =
            case endpoint_id do
              ^id_a ->
                [%{"name" => "part_ping", "inputSchema" => %{}}]

              ^id_a_b ->
                [ping_tool()]
            end

          {:ok, tools}
        end
      })

      snapshot = fn consumer ->
        state = :sys.get_state(consumer)
        policy = MCP.approval_policy()

        Map.new(state.modules, fn module ->
          definition = ProxyGenerator.definition!(module)

          {definition.endpoint_id,
           %{
             module: module,
             name: module.name(),
             remote: definition.remote_name,
             approval: policy[module.name()],
             templates: state.module_templates[module]
           }}
        end)
      end

      first_consumer = start_consumer!([server_a, server_a_b])
      assert_eventually(fn -> :sys.get_state(first_consumer).status == :ready end)
      first = snapshot.(first_consumer)

      a = first[ids["collisioncase"]]
      a_b = first[ids["collisioncase_part"]]

      refute a.name == a_b.name
      assert a.remote == "part_ping"
      assert a.approval == false
      assert a.templates == ["main"]
      assert a_b.remote == "ping"
      assert a_b.approval == true
      assert a_b.templates == ["coder"]

      :ok = stop_supervised(Consumer)

      reordered_consumer = start_consumer!([server_a_b, server_a])
      assert_eventually(fn -> :sys.get_state(reordered_consumer).status == :ready end)

      assert snapshot.(reordered_consumer) == first
    end

    test "collision removal tombstones the disambiguated names; re-add reuses identity AND policy" do
      # Identity reuse alone (proxy_generator_test) doesn't prove policy
      # publication — this drives the full Consumer lifecycle:
      # collision → partner removed → collision restored.
      server_a = server("lifecase", require_approval: false)
      server_a_b = server("lifecase_part", require_approval: true)

      ids = endpoint_ids([server_a, server_a_b])
      id_a = ids["lifecase"]
      id_a_b = ids["lifecase_part"]

      stub(%{
        list_tools: fn endpoint_id, _timeout ->
          tools =
            case endpoint_id do
              ^id_a -> [%{"name" => "part_ping", "inputSchema" => %{}}]
              ^id_a_b -> [ping_tool()]
            end

          {:ok, tools}
        end
      })

      snapshot = fn consumer ->
        state = :sys.get_state(consumer)

        Map.new(state.modules, fn module ->
          {ProxyGenerator.definition!(module).endpoint_id, %{module: module, name: module.name()}}
        end)
      end

      # Round 1: collision — both members disambiguated, each with its
      # configured policy.
      collided = start_consumer!([server_a, server_a_b])
      assert_eventually(fn -> :sys.get_state(collided).status == :ready end)
      first = snapshot.(collided)
      a1 = first[id_a]
      a_b1 = first[id_a_b]

      refute a1.name == a_b1.name
      assert MCP.approval_policy()[a1.name] == false
      assert MCP.approval_policy()[a_b1.name] == true

      :ok = stop_supervised(Consumer)

      # Round 2: the collision partner is removed. The survivor moves to its
      # previously-unseen PLAIN name (carrying its configured policy) while
      # BOTH obsolete disambiguated names become force-gated tombstones.
      solo = start_consumer!([server_a])
      assert_eventually(fn -> :sys.get_state(solo).status == :ready end)

      [solo_module] = :sys.get_state(solo).modules
      solo_name = solo_module.name()

      refute solo_name == a1.name
      policy = MCP.approval_policy()
      assert policy[solo_name] == false
      assert policy[a1.name] == true
      assert policy[a_b1.name] == true

      :ok = stop_supervised(Consumer)

      # Round 3: restoring the collision re-activates the ORIGINAL
      # disambiguated identities with their configured policies (the plain
      # name is tombstoned in turn).
      restored = start_consumer!([server_a, server_a_b])
      assert_eventually(fn -> :sys.get_state(restored).status == :ready end)
      third = snapshot.(restored)

      assert third[id_a].module == a1.module
      assert third[id_a_b].module == a_b1.module
      assert MCP.approval_policy()[a1.name] == false
      assert MCP.approval_policy()[a_b1.name] == true
      assert MCP.approval_policy()[solo_name] == true
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
      assert Map.has_key?(:sys.get_state(consumer).attached, agent)
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
      refute Map.has_key?(:sys.get_state(consumer).attached, agent)
    end
  end

  describe "prep crash recovery and exhaustion" do
    test "re-prep recovers to :ready after a transient hard crash; the counter resets" do
      stub(counter_stub(self(), %{1 => :block}, {:ok, [ping_tool()]}))
      consumer = start_consumer!([@server])

      # Call 1 blocks; kill it. The scheduled re-prep's call 2 succeeds → :ready.
      assert_receive {:listing, _child}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)

      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      assert :sys.get_state(consumer).reprep_attempts == 0

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @tool_name)
    end

    test "max-attempts exhaustion terminates in :failed and serves :mcp_unavailable" do
      consumer = exhaust_prep!()
      agent = start_agent!()

      # `:mcp_unavailable` must be the FIRST assertion: were this :ready it would
      # return :ok and fire an async mark_attached an `attached` check could race.
      assert :mcp_unavailable = MCP.ensure_attached(agent, "main", 1_000)
      refute Map.has_key?(:sys.get_state(consumer).attached, agent)
      assert :sys.get_state(consumer).status == :failed
    end

    test "hard crash preserves gated LKG policy and empty re-prep prunes a tracked stale tool" do
      AgentTracker.reset()
      on_exit(fn -> AgentTracker.reset() end)

      agent = start_agent!()

      [stale_module] =
        ProxyGenerator.build_modules("crash_stale", :crash_stale_endpoint, [ping_tool()])

      stale_name = stale_module.name()
      assert :ok = Consumer.register_modules(agent, [stale_module])
      assert has_tool?(agent, stale_name)

      tracker_id = "crash-stale-#{System.unique_integer([:positive])}"
      :ok = AgentTracker.register(tracker_id, agent, "coder", "t")
      :persistent_term.put(MCP.policy_key(), %{stale_name => true})

      # Initial prep hard-crashes; its refresh re-prep fails gracefully and
      # accepts the empty fallback target. Exact tracked fan-out must prune the
      # old proxy, while its explicit gated policy survives as a tombstone.
      stub(counter_stub(self(), %{1 => :block}, {:error, :offline}))
      consumer = start_consumer!([server("crash_empty")])

      assert_receive {:listing, _child}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).reprep_attempts >= 1 end)
      assert MCP.approval_policy()[stale_name] == true

      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      assert_eventually(fn -> not has_tool?(agent, stale_name) end)
      assert MCP.approval_policy()[stale_name] == true
    end

    test "hard crash preserves an explicitly TRUSTED (=> false) LKG policy too" do
      # POLICY CHOICE canonized by the 2026-07-10 review (finding 6): an
      # explicitly trusted (require_approval: false) server's tools keep
      # last-known-good trust through a prep-death outage window — the inverse
      # of the gated-survives rule above. Wiping to %{} would void explicit
      # GATES under a trusted global posture, the worse trade.
      AgentTracker.reset()
      on_exit(fn -> AgentTracker.reset() end)

      agent = start_agent!()

      [trusted_module] =
        ProxyGenerator.build_modules("crash_trusted", :crash_trusted_endpoint, [ping_tool()])

      trusted_name = trusted_module.name()
      assert :ok = Consumer.register_modules(agent, [trusted_module])
      assert has_tool?(agent, trusted_name)

      tracker_id = "crash-trusted-#{System.unique_integer([:positive])}"
      :ok = AgentTracker.register(tracker_id, agent, "coder", "t")
      :persistent_term.put(MCP.policy_key(), %{trusted_name => false})

      stub(counter_stub(self(), %{1 => :block}, {:error, :offline}))
      consumer = start_consumer!([server("crash_trusted_empty")])

      assert_receive {:listing, _child}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).reprep_attempts >= 1 end)
      assert MCP.approval_policy()[trusted_name] == false

      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      assert_eventually(fn -> not has_tool?(agent, trusted_name) end)
      assert MCP.approval_policy()[trusted_name] == false
    end

    test "attach_to_agent replies :ok on a terminal :failed Consumer without crashing it" do
      consumer = exhaust_prep!()
      agent = start_agent!()

      assert :ok = MCP.attach_to_agent(agent, "main")
      assert Process.alive?(consumer)
      assert :sys.get_state(consumer).status == :failed
    end

    test "a mark is dropped on :failed even with a matching generation (status guard)" do
      consumer = exhaust_prep!()
      agent = start_agent!()

      # Even this incarnation's own generation can't re-arm a :failed Consumer —
      # the status guard drops the mark before the generation match is reached.
      generation = :sys.get_state(consumer).generation
      GenServer.cast(consumer, {:mark_attached, agent, generation, "main"})
      # `:sys.get_state` is a FIFO barrier — it flushes the cast first.
      refute Map.has_key?(:sys.get_state(consumer).attached, agent)
    end

    test "an ensure_attached arriving during the recovery window defers and is served" do
      stub(counter_stub(self(), %{1 => :block, 2 => :block}, {:ok, [ping_tool()]}))
      consumer = start_consumer!([@server])
      agent = start_agent!()

      assert_receive {:listing, _child1}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).reprep_attempts >= 1 end)

      # The caller arrives while :preparing (post-crash) → deferred as a waiter.
      waiter = Task.async(fn -> MCP.ensure_attached(agent, "main", 5_000) end)
      assert_eventually(fn -> :sys.get_state(consumer).waiters != [] end)

      # Release the re-prep's call 2 → :ready → the deferred waiter is served.
      assert_receive {:listing, child2}, 2_000
      send(child2, :release)

      assert :ok = Task.await(waiter, 5_000)
      assert has_tool?(agent, @tool_name)
    end

    test "a fire-and-forget attach during the recovery window lands via retained pending" do
      stub(counter_stub(self(), %{1 => :block, 2 => :block}, {:ok, [ping_tool()]}))
      consumer = start_consumer!([@server])
      agent = start_agent!()

      assert_receive {:listing, _child1}, 2_000
      Process.exit(:sys.get_state(consumer).prep_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).reprep_attempts >= 1 end)

      # Fire-and-forget during :preparing → retained in `pending`.
      assert :ok = MCP.attach_to_agent(agent, "main")

      assert_receive {:listing, child2}, 2_000
      send(child2, :release)

      assert_eventually(fn -> has_tool?(agent, @tool_name) end)
    end
  end

  describe "mark_attached generation fence" do
    test "a generation-mismatched mark exact-reconciles current reach while ready" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      # A registration task from a prior incarnation carries a stale token. It
      # must not mark directly; the Consumer first exact-reconciles current reach
      # and only the current-generation task may mark the pid attached.
      GenServer.cast(consumer, {:mark_attached, agent, make_ref(), "main"})
      assert_eventually(fn -> Map.has_key?(:sys.get_state(consumer).attached, agent) end)
      assert has_tool?(agent, @tool_name)
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

    test "a sandboxed template attaches ZERO external tools even from an :all server (AR-8b)" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      # @server carries no `templates:` allowlist → :all (every template reaches it).
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      sandboxed = start_agent!()
      normal = start_agent!()

      assert :ok = MCP.ensure_attached(sandboxed, "sketch_build", 3_000)
      assert :ok = MCP.ensure_attached(normal, "coder", 3_000)

      # The sandboxed template is withheld every external tool at *registration*
      # (external_tools?/1 is false), even though the server admits :all. A normal
      # template still gets the :all server's tool.
      refute has_tool?(sandboxed, @tool_name)
      assert has_tool?(normal, @tool_name)
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
      assert_eventually(fn -> Map.has_key?(:sys.get_state(consumer).attached, other) end)
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
      assert_eventually(fn -> Map.has_key?(:sys.get_state(consumer).attached, other) end)
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

    test "tracked fan-out exact-reconciles pre-attached pids and each allowed subset" do
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

      # Seed `already` into the attached map. A successful preparation must
      # exact-reconcile both previously attached and newly tracked agents.
      :sys.replace_state(consumer, fn s ->
        %{s | attached: Map.put(s.attached, already, "coder")}
      end)

      send(task_pid, :release)

      # Both coder agents are allowlisted, including the one marked attached
      # before the generation became ready.
      assert_eventually(fn -> has_tool?(coder, @tool_name) end)
      assert_eventually(fn -> has_tool?(already, @tool_name) end)

      # researcher is outside the server's template allowlist.
      refute has_tool?(researcher, @tool_name)
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

  describe "periodic re-discovery" do
    test "picks up an added tool and registers it on a live agent" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(), pong_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @tool_name)
      refute has_tool?(agent, @pong_name)

      send(consumer, :rediscover)
      assert_eventually(fn -> has_tool?(agent, @pong_name) end)
      assert has_tool?(agent, @tool_name)
    end

    test "removes a vanished tool from a live agent" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool(), pong_tool()]}}, {:ok, [ping_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @pong_name)

      send(consumer, :rediscover)
      assert_eventually(fn -> not has_tool?(agent, @pong_name) end)
      # The surviving tool stays.
      assert has_tool?(agent, @tool_name)
    end

    test "a removed gated name stays force-gated while async prune is retrying" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool(), pong_tool()]}}, {:ok, [ping_tool()]}))

      {:ok, failed_once} = Agent.start_link(fn -> false end)
      on_exit(fn -> if Process.alive?(failed_once), do: Agent.stop(failed_once) end)
      test_pid = self()

      Application.put_env(:jido_claw, :mcp_agent_api_stub, %{
        unregister_tool: fn pid, name, opts ->
          first_pong? =
            name == @pong_name and
              Agent.get_and_update(failed_once, fn seen? -> {not seen?, true} end)

          if first_pong? do
            send(test_pid, :pong_prune_blocked)
            {:error, :transient_unregister_failure}
          else
            Jido.AI.unregister_tool(pid, name, opts)
          end
        end
      })

      consumer =
        start_consumer!([server("stub", require_approval: true)], agent_api: AgentAPIStub)

      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @pong_name)

      send(consumer, :rediscover)
      assert_receive :pong_prune_blocked, 3_000

      # The stale proxy is still callable by name, so its tombstone must remain
      # explicitly gated even if the global MCP posture is trusted.
      assert has_tool?(agent, @pong_name)
      assert MCP.approval_policy()[@pong_name] == true

      send(consumer, :rediscover)
      assert_eventually(fn -> not has_tool?(agent, @pong_name) end)
      assert MCP.approval_policy()[@pong_name] == true
    end

    test "a changed tool (same local name, new schema) is unregistered then re-registered" do
      mod_a = ping_module()
      digest_a = ProxyGenerator.definition_digest(mod_a)
      mod_b = ping_module(ping_schema_b())
      digest_b = ProxyGenerator.definition_digest(mod_b)
      assert mod_a == mod_b
      refute digest_a == digest_b

      stub(
        counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(ping_schema_b())]})
      )

      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert current_ping_module(agent) == mod_a
      before_digest = :sys.get_state(consumer).definition_digests[mod_a]

      send(consumer, :rediscover)

      assert_eventually(fn ->
        :sys.get_state(consumer).definition_digests[mod_a] != before_digest
      end)

      # Identity is stable (no atom/code churn); the digest change forces a
      # name-level unregister/register so the agent refreshes cached metadata.
      assert current_ping_module(agent) == mod_b
    end

    test "a transient changed-definition unregister failure retries on the next no-op tick" do
      stub(
        counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(ping_schema_b())]})
      )

      {:ok, unregister_calls} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(unregister_calls), do: Agent.stop(unregister_calls) end)

      test_pid = self()

      Application.put_env(:jido_claw, :mcp_agent_api_stub, %{
        unregister_tool: fn pid, name, opts ->
          call = Agent.get_and_update(unregister_calls, fn count -> {count + 1, count + 1} end)

          if call == 1 do
            send(test_pid, :unregister_failed_once)
            {:error, :transient_unregister_failure}
          else
            Jido.AI.unregister_tool(pid, name, opts)
          end
        end
      })

      consumer = start_consumer!([@server], agent_api: AgentAPIStub)
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      refute Map.has_key?(cached_ping_schema(agent)["properties"], "x")

      send(consumer, :rediscover)
      assert_receive :unregister_failed_once, 3_000

      # The stable module now exposes the accepted definition, but the agent's
      # ReqLLM metadata cache is still old because unregister failed. The name
      # remains pending even after the digest diff has been committed.
      refute Map.has_key?(cached_ping_schema(agent)["properties"], "x")

      assert_eventually(fn ->
        consumer
        |> :sys.get_state()
        |> Map.get(:definition_refreshes)
        |> Map.get(agent, MapSet.new())
        |> MapSet.member?(@tool_name)
      end)

      # Discovery is now a no-op (same new digest). The retained name forces a
      # second unregister/register and clears only after the task confirms :ok.
      send(consumer, :rediscover)

      assert_eventually(fn ->
        Map.has_key?(cached_ping_schema(agent)["properties"], "x") and
          not Map.has_key?(:sys.get_state(consumer).definition_refreshes, agent)
      end)

      assert Agent.get(unregister_calls, & &1) >= 2
    end

    test "an ordinary discovery failure preserves last-known-good tools" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:error, :offline}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @tool_name)
      before = :sys.get_state(consumer).modules

      send(consumer, :rediscover)
      assert_eventually(fn -> :sys.get_state(consumer).rediscover_ref == nil end)

      assert :sys.get_state(consumer).modules == before
      assert has_tool?(agent, @tool_name)
    end

    test "a partial multi-server failure rolls back a successful server's staged definition" do
      {:ok, calls} = Agent.start_link(fn -> %{} end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
      servers = [server("alpha"), server("beta")]
      %{"alpha" => alpha_id, "beta" => beta_id} = endpoint_ids(servers)

      list_tools = fn endpoint_id, _timeout ->
        attempt =
          Agent.get_and_update(calls, fn counts ->
            next = Map.get(counts, endpoint_id, 0) + 1
            {next, Map.put(counts, endpoint_id, next)}
          end)

        case {endpoint_id, attempt} do
          {^alpha_id, 1} -> {:ok, [ping_tool()]}
          {^beta_id, 1} -> {:ok, [ping_tool()]}
          {^alpha_id, _later} -> {:ok, [ping_tool(ping_schema_b())]}
          {^beta_id, _later} -> {:error, :offline}
        end
      end

      stub(%{list_tools: list_tools, refresh_endpoint: fn _id -> :ok end})
      consumer = start_consumer!(servers)
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      before_state = :sys.get_state(consumer)
      alpha = Enum.find(before_state.modules, &(&1.name() == tool_name("alpha")))
      before_digest = ProxyGenerator.definition_digest(alpha)
      before_schema = alpha.schema()

      send(consumer, :rediscover)
      assert_eventually(fn -> :sys.get_state(consumer).rediscover_ref == nil end)

      assert :sys.get_state(consumer).modules == before_state.modules
      assert ProxyGenerator.definition_digest(alpha) == before_digest
      assert alpha.schema() == before_schema
      refute Map.has_key?(alpha.schema()["properties"], "x")
    end

    test "a hard-killed partial aggregate cannot publish definitions or consume identities" do
      {:ok, calls} = Agent.start_link(fn -> %{} end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
      test_pid = self()
      servers = [server("alpha"), server("beta")]
      %{"alpha" => alpha_id, "beta" => beta_id} = endpoint_ids(servers)

      list_tools = fn endpoint_id, _timeout ->
        attempt =
          Agent.get_and_update(calls, fn counts ->
            next = Map.get(counts, endpoint_id, 0) + 1
            {next, Map.put(counts, endpoint_id, next)}
          end)

        case {endpoint_id, attempt} do
          {id, 1} when id in [alpha_id, beta_id] ->
            {:ok, [ping_tool()]}

          {^alpha_id, _later} ->
            send(test_pid, {:alpha_staging_task, self()})
            {:ok, [ping_tool(ping_schema_b()), %{"name" => "fresh_after_boot"}]}

          {^beta_id, _later} ->
            send(test_pid, {:beta_blocked, self()})

            receive do
              :release -> {:ok, [ping_tool()]}
            after
              10_000 -> {:ok, [ping_tool()]}
            end
        end
      end

      stub(%{list_tools: list_tools})
      consumer = start_consumer!(servers)
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      before_state = :sys.get_state(consumer)
      alpha = Enum.find(before_state.modules, &(&1.name() == tool_name("alpha")))
      before_digest = ProxyGenerator.definition_digest(alpha)
      before_identities = ProxyGenerator.identity_count()

      send(consumer, :rediscover)
      assert_receive {:alpha_staging_task, alpha_task}, 2_000
      assert_receive {:beta_blocked, _beta_task}, 2_000

      # The alpha task exits only after it has built its complete inert stage.
      alpha_ref = Process.monitor(alpha_task)
      assert_receive {:DOWN, ^alpha_ref, :process, ^alpha_task, _reason}, 2_000

      assert ProxyGenerator.definition_digest(alpha) == before_digest
      assert alpha.schema()["properties"] == %{}
      assert ProxyGenerator.identity_count() == before_identities

      rediscover_pid = :sys.get_state(consumer).rediscover_pid
      Process.exit(rediscover_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).rediscover_ref == nil end)

      assert ProxyGenerator.definition_digest(alpha) == before_digest
      assert alpha.schema()["properties"] == %{}
      assert ProxyGenerator.identity_count() == before_identities
    end

    test "a server unreachable at boot attaches only after refresh_endpoint runs" do
      stub(refresh_gated_stub(self()))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      # Boot discovery failed (list_tools errored), so the agent attaches empty.
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      refute has_tool?(agent, @tool_name)

      send(consumer, :rediscover)
      # The refresh callback is what flips list_tools to success.
      assert_receive :refreshed, 2_000
      assert_eventually(fn -> has_tool?(agent, @tool_name) end)
    end

    test "reconcile honors the allowlist — a tool a template can no longer reach is unregistered" do
      # Boot: server is unrestricted (coder gets ping). Rediscover: same tool but
      # now allowlisted to "researcher" only → coder's ping is pruned. The spec
      # comes from `:mcp_servers` config (re-read each tick), so the Consumer is
      # started with `servers: nil` and the config is swapped between ticks.
      prior_servers = Application.get_env(:jido_claw, :mcp_servers)
      on_exit(fn -> restore(:mcp_servers, prior_servers) end)

      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      Application.put_env(:jido_claw, :mcp_servers, [server("stub")])

      consumer = start_consumer!(nil)
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      coder = start_agent!()
      assert :ok = MCP.ensure_attached(coder, "coder", 3_000)
      assert has_tool?(coder, @tool_name)

      Application.put_env(:jido_claw, :mcp_servers, [server("stub", templates: ["researcher"])])

      send(consumer, :rediscover)
      assert_eventually(fn -> not has_tool?(coder, @tool_name) end)
    end

    test "a stale attach mark immediately exact-reconciles against the new generation" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(), pong_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      # The generation a register task spawned just before the tick would carry.
      old_gen = :sys.get_state(consumer).generation

      send(consumer, :rediscover)
      # A tool-set change mints a fresh generation.
      assert_eventually(fn -> :sys.get_state(consumer).generation != old_gen end)

      [late_stale] =
        ProxyGenerator.build_modules("late_stale", :late_stale_endpoint, [ping_tool()])

      assert :ok = Consumer.register_modules(agent, [late_stale])
      assert has_tool?(agent, late_stale.name())

      # A pre-rediscovery attach can finish after the changed tick and re-add an
      # old tool. Its stale success mark must queue an immediate exact reconcile,
      # not wait for the next turn or five-minute rediscovery cadence.
      GenServer.cast(consumer, {:mark_attached, agent, old_gen, "main"})

      assert_eventually(fn -> Map.has_key?(:sys.get_state(consumer).attached, agent) end)
      assert_eventually(fn -> not has_tool?(agent, late_stale.name()) end)
      assert has_tool?(agent, @tool_name)
      assert has_tool?(agent, @pong_name)
    end

    test "a no-op tick runs idempotent reconcile, no generation bump, tool set stable" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)

      policy_before = MCP.approval_policy()
      gen_before = :sys.get_state(consumer).generation

      send(consumer, :rediscover)
      assert_eventually(fn -> :sys.get_state(consumer).rediscover_ref == nil end)

      # No tool-set change ⇒ reconcile still runs but is idempotent (no atom
      # differs ⇒ no unregister; the present tool ⇒ a skipped register), so no
      # generation bump, the policy stays value-equal (not republished), and the
      # tool set is unchanged.
      assert :sys.get_state(consumer).generation == gen_before
      assert MCP.approval_policy() == policy_before
      assert has_tool?(agent, @tool_name)
    end

    test "a no-op tick prunes a stale tool left on an attached agent" do
      # Discovery never changes (always [ping]) so the tick is a no-op
      # (tools_changed? == false). The stale `pong` is planted by hand — not by
      # any discovery diff — so ONLY the every-tick reconcile can remove it. With
      # reconcile gated on tools_changed? (the bug) this times out; with
      # reconcile running every tick the planted tool is pruned.
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @tool_name)

      # Plant a stale mcp_* tool directly on the agent (race-free: registered on
      # the agent, never produced by discovery, so reconcile is the only remover).
      [pong_module] = ProxyGenerator.build_modules("stub", :stub, [pong_tool()])
      assert :ok = Consumer.register_modules(agent, [pong_module])
      assert has_tool?(agent, @pong_name)

      send(consumer, :rediscover)

      # The no-op tick reconciles the attached pid against its reach ([ping]), so
      # the planted `pong` (absent from reach) is unregistered; `ping` survives.
      assert_eventually(fn -> not has_tool?(agent, @pong_name) end)
      assert has_tool?(agent, @tool_name)
    end

    test "a stale {:rediscovered} with a non-matching pid is ignored" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      modules_before = :sys.get_state(consumer).modules

      # Idle ⇒ rediscover_pid is nil; a result tagged with a foreign pid drops.
      send(consumer, {:rediscovered, self(), [], %{}, %{}, %{}})

      after_state = :sys.get_state(consumer)
      assert after_state.status == :ready
      assert after_state.modules == modules_before
    end

    @tag :capture_log
    test "a re-discovery prep crash keeps :ready with existing tools and re-arms" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}, 2 => :block}, {:ok, [ping_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)

      send(consumer, :rediscover)
      # The blocked re-discovery prep is in flight.
      assert_receive {:listing, _child}, 2_000
      redisc_pid = :sys.get_state(consumer).rediscover_pid
      assert is_pid(redisc_pid)

      Process.exit(redisc_pid, :kill)
      assert_eventually(fn -> :sys.get_state(consumer).rediscover_ref == nil end)

      assert :sys.get_state(consumer).status == :ready
      assert has_tool?(agent, @tool_name)
    end

    test "auto-arms the next re-discovery on the configured interval" do
      put_mcp_env(
        reprep_backoff_ms: 50,
        reprep_backoff_max_ms: 100,
        reprep_max_attempts: 2,
        rediscovery_interval_ms: 50
      )

      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(), pong_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert has_tool?(agent, @tool_name)

      # No manual :rediscover — the armed timer fires it.
      assert_eventually(fn -> has_tool?(agent, @pong_name) end)
    end

    test "policy_changed?/2 is true only on a value difference" do
      refute Consumer.policy_changed?(%{"a" => true}, %{"a" => true})
      assert Consumer.policy_changed?(%{"a" => true}, %{"a" => false})
      assert Consumer.policy_changed?(%{"a" => true}, %{})
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

  # The live module currently registered on `pid` for the @tool_name local name.
  defp current_ping_module(pid) do
    case Jido.AI.list_tools(pid) do
      {:ok, modules} -> Enum.find(modules, &(&1.name() == @tool_name))
      _other -> nil
    end
  end

  defp cached_ping_schema(pid) do
    {:ok, state} = Jido.AgentServer.state(pid)
    strategy = StrategyState.get(state.agent, %{})

    strategy
    |> get_in([:config, :reqllm_tools])
    |> Enum.find(&(&1.name == @tool_name))
    |> Map.fetch!(:parameter_schema)
  end
end
