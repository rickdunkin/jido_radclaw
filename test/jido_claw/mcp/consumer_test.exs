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

  alias JidoClaw.AgentTracker
  alias JidoClaw.MCP
  alias JidoClaw.MCP.Consumer
  alias JidoClaw.MCP.ProxyGenerator

  @server %{"name" => "stub", "transport" => "streamable_http", "url" => "http://localhost:1/mcp"}
  @tool_name "mcp_stub_ping"
  @pong_name "mcp_stub_pong"

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

  defp ping_tool(schema \\ %{"type" => "object", "properties" => %{}}),
    do: %{"name" => "ping", "inputSchema" => schema}

  defp pong_tool,
    do: %{"name" => "pong", "inputSchema" => %{"type" => "object", "properties" => %{}}}

  # A second `ping` schema → a different content-addressed module atom for the
  # SAME local name `mcp_stub_ping` (the atom mismatch the reconcile prunes).
  defp ping_schema_b,
    do: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}

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

  # Pin prep in `:preparing` via a blocking `list_tools`, hard-kill the prep
  # process, and barrier until the Consumer registered the scheduled retry. One
  # crash now lands in `:preparing` (a retry), not `:failed`; the monotonic
  # `reprep_attempts >= 1` proves the retry happened (default 0 so a missing
  # field fails the barrier rather than false-passing). Returns the Consumer.
  defp crash_prep! do
    stub(%{list_tools: blocking_list_tools(self(), [ping_tool()])})
    consumer = start_consumer!([@server])

    assert_receive {:listing, _child}, 2_000
    Process.exit(:sys.get_state(consumer).prep_pid, :kill)
    assert_eventually(fn -> Map.get(:sys.get_state(consumer), :reprep_attempts, 0) >= 1 end)

    consumer
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
    [module] = ProxyGenerator.build_modules("stub", :stub, [ping_tool(schema)])
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

    test "every prep crash republishes an empty (fail-closed) approval policy" do
      :persistent_term.put(MCP.policy_key(), %{"mcp_stale_tool" => false})

      crash_prep!()

      assert MCP.approval_policy() == %{}
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
    test "a generation-mismatched mark is dropped while :ready (self-healing)" do
      stub(%{list_tools: fn _id, _t -> {:ok, [ping_tool()]} end})
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)
      agent = start_agent!()

      # A registration task from a prior (crashed) incarnation carries a stale
      # token that never matches this one, so its mark is dropped — the pid
      # stays free rather than being falsely marked against a stale module set.
      GenServer.cast(consumer, {:mark_attached, agent, make_ref(), "main"})
      refute Map.has_key?(:sys.get_state(consumer).attached, agent)

      # Self-heal: a current-generation ensure_attached still attaches normally.
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert Map.has_key?(:sys.get_state(consumer).attached, agent)
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

      # Seed `already` into the attached map so the fan-out's pid-membership
      # reject (the tracked-tuple fix) skips it — proving the reject keys on the
      # pid, not the {pid, template} tuple tracked_live_pids now returns.
      :sys.replace_state(consumer, fn s ->
        %{s | attached: Map.put(s.attached, already, "coder")}
      end)

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

    test "a changed tool (same local name, new schema) is unregistered then re-registered" do
      mod_a = ping_module()
      mod_b = ping_module(ping_schema_b())
      refute mod_a == mod_b

      stub(
        counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(ping_schema_b())]})
      )

      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert current_ping_module(agent) == mod_a

      send(consumer, :rediscover)
      # The agent ends with the NEW proxy module — proving the atom-mismatch
      # unregister-then-register, not the add-only `register_modules` skip.
      assert_eventually(fn -> current_ping_module(agent) == mod_b end)
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

    test "an in-flight attach's stale mark is dropped by the generation bump; the pid self-heals" do
      stub(counter_stub(self(), %{1 => {:ok, [ping_tool()]}}, {:ok, [ping_tool(), pong_tool()]}))
      consumer = start_consumer!([@server])
      assert_eventually(fn -> :sys.get_state(consumer).status == :ready end)

      agent = start_agent!()
      # The generation a register task spawned just before the tick would carry.
      old_gen = :sys.get_state(consumer).generation

      send(consumer, :rediscover)
      # A tool-set change mints a fresh generation.
      assert_eventually(fn -> :sys.get_state(consumer).generation != old_gen end)

      # The in-flight task's late mark (old generation) is dropped — the pid is
      # NOT falsely marked attached against the superseded module set.
      GenServer.cast(consumer, {:mark_attached, agent, old_gen, "main"})
      refute Map.has_key?(:sys.get_state(consumer).attached, agent)

      # Self-heal: a current ensure_attached re-registers the current reach and
      # marks the pid (the added tool is now present too).
      assert :ok = MCP.ensure_attached(agent, "main", 3_000)
      assert Map.has_key?(:sys.get_state(consumer).attached, agent)
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
      send(consumer, {:rediscovered, self(), [], %{}, %{}})

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
end
