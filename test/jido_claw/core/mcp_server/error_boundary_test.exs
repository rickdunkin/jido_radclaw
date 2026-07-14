defmodule JidoClaw.MCPServer.ErrorBoundaryTest do
  @moduledoc """
  PD1-2 wire exactness: drives the PATCHED `Jido.MCP.Server.Runtime`
  `handle_tool_call/5` end-to-end with scripted action modules and asserts
  the dual-content error shape — `content[0]` byte-identical legacy inspect
  text, `content[1]` the canonical registry-enforced JSON envelope — plus
  the reduction tiers, the never-escalate guarantee, the retry call-count
  regression, native typed-error adaptation, and the non-public servers'
  byte-identical legacy arm.
  """

  # async: false — tweaks the :jido_action default-timeout app env for the
  # exec-timeout row.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Jido.Action.Error, as: JidoActionError
  alias Jido.Action.Error.ConfigurationError
  alias Jido.Action.Error.ExecutionFailureError
  alias Jido.Action.Error.InternalError
  alias Jido.Action.Error.InvalidInputError
  alias Jido.Action.Error.TimeoutError
  alias Jido.Exec.Compensation
  alias Jido.MCP.Server.Runtime
  alias JidoClaw.Agent.LoopGuard
  alias JidoClaw.MCPServer.ErrorBoundary
  alias JidoClaw.TestSupport.HostileInspect

  # Test-local foreign exception carrying an arbitrary-width field — the
  # tier-4 bignum row (a foreign exception rides verbatim through exec and
  # unwraps at tier 4, where the message reuses content[0]'s one render).
  defmodule BigFieldError do
    @moduledoc false
    defexception [:message, :big]
  end

  # Test-local NON-exception struct whose fields collide with the wrap shape:
  # exec's extract_error_fields struct clause converts it to the same
  # %{code:, details:} details map a canonical envelope produces — the
  # stamp-condition pin (PORT-PD1-2-EXEC): the pre-wrap term was no envelope,
  # so the wrap must stay unstamped and tier 3 must hold.
  defmodule CollidingStruct do
    @moduledoc false
    defstruct [:message, :code, :details]
  end

  @public JidoClaw.MCPServer
  @consolidator JidoClaw.Memory.Consolidator.MCPServer

  # ── Scripted actions ─────────────────────────────────────────────────────

  # Returns whatever the test staged under `key` in the Scripts agent —
  # arbitrary error terms can't ride MCP arguments, so they ride a named
  # process instead. Also counts executions per key (the retry row).
  defmodule ScriptedTool do
    use Jido.Action,
      name: "boundary_scripted_tool",
      description: "Test-only scripted error producer.",
      schema: [key: [type: :string, required: true]]

    alias JidoClaw.MCPServer.ErrorBoundaryTest.Scripts

    @impl Jido.Action
    def run(%{key: key}, _context) do
      Scripts.bump(key)
      Scripts.fetch(key)
    end
  end

  defmodule OkTool do
    use Jido.Action,
      name: "boundary_ok_tool",
      description: "Test-only success producer.",
      schema: []

    @impl Jido.Action
    def run(_params, _context), do: {:ok, %{value: 42}}
  end

  defmodule SleepyTool do
    use Jido.Action,
      name: "boundary_sleepy_tool",
      description: "Test-only sleeper for the exec-timeout row.",
      schema: []

    @impl Jido.Action
    def run(_params, _context) do
      Process.sleep(2_000)
      {:ok, %{late: true}}
    end
  end

  defmodule Scripts do
    @moduledoc false
    use Agent

    @spec start_link(term()) :: Agent.on_start()
    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    @spec stage(String.t(), term()) :: :ok
    def stage(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, {value, 0}))

    @spec bump(String.t()) :: :ok
    def bump(key) do
      Agent.update(__MODULE__, fn state ->
        Map.update(state, key, {nil, 1}, fn {value, count} -> {value, count + 1} end)
      end)
    end

    @spec fetch(String.t()) :: term()
    def fetch(key), do: Agent.get(__MODULE__, fn state -> elem(Map.fetch!(state, key), 0) end)

    @spec count(String.t()) :: non_neg_integer()
    def count(key) do
      Agent.get(__MODULE__, fn state ->
        case Map.get(state, key) do
          {_value, count} -> count
          nil -> 0
        end
      end)
    end
  end

  @tools [ScriptedTool, OkTool, SleepyTool]

  setup_all do
    {:ok, _pid} = start_supervised(Scripts)
    :ok
  end

  defp call_tool(key, value, server \\ @public) do
    Scripts.stage(key, value)

    Runtime.handle_tool_call(
      @tools,
      "boundary_scripted_tool",
      %{key: key},
      %Frame{},
      server
    )
  end

  defp wire(response), do: Response.to_protocol(response)

  defp decode_item!(wire_map, index) do
    %{"type" => "text", "text" => text} = Enum.at(wire_map["content"], index)
    Jason.decode!(text)
  end

  defp unique_key(label), do: "#{label}-#{System.unique_integer([:positive])}"

  # ── (a) exactness ────────────────────────────────────────────────────────

  test "(a) a failing served tool's content[1] decodes to the EXACT code + message + details" do
    key = unique_key("exact")

    envelope = %{
      code: :unknown_skill,
      message: "Skill 'zorp' not found.",
      details: %{retry: false, skill: "zorp", available: ["a_skill", "b_skill"]}
    }

    assert {:reply, response, %Frame{}} = call_tool(key, {:error, envelope})
    out = wire(response)

    assert out["isError"] == true
    assert [_legacy, _structured] = out["content"]

    assert decode_item!(out, 1) == %{
             "code" => "unknown_skill",
             "message" => "Skill 'zorp' not found.",
             "details" => %{
               "retry" => false,
               "skill" => "zorp",
               "available" => ["a_skill", "b_skill"]
             }
           }
  end

  # ── (b) unregistered codes ───────────────────────────────────────────────

  test "(b) a foreign unregistered atom re-codes to tool_error + unregistered_code" do
    key = unique_key("unregistered")
    envelope = %{code: :zorblax_unknown, message: "weird", details: %{origin: "test"}}

    log =
      capture_log(fn ->
        assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
        decoded = decode_item!(wire(response), 1)

        assert decoded["code"] == "tool_error"
        assert decoded["message"] == "weird"
        assert decoded["details"]["unregistered_code"] == ":zorblax_unknown"
        assert decoded["details"]["origin"] == "test"
      end)

    assert log =~ "unregistered error code :zorblax_unknown"
  end

  test "(b) a module-atom CODE inside a canonical envelope survives as a string" do
    key = unique_key("module-code")
    envelope = %{code: Enum.Weird.Never, message: "m", details: %{}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "tool_error"
      # Pre-JsonSafe stringification: a module atom as a map value would
      # otherwise be dropped entirely.
      assert decoded["details"]["unregistered_code"] == "Enum.Weird.Never"
    end)
  end

  test "(b) a PLAIN {:error, Module} maps to execution_error via the native tier, NOT the fallback" do
    key = unique_key("bare-atom")

    assert {:reply, response, _frame} = call_tool(key, {:error, Enum})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "execution_error"
    refute Map.has_key?(decoded["details"], "unregistered_code")
    # Exec's atom wrap carries retry: Error.retryable?(Enum) == false.
    assert decoded["details"]["retry"] == false
  end

  # ── (c) content[0] byte identity ─────────────────────────────────────────

  test "(c) content[0] is byte-identical to the legacy inspect for ordinary terms" do
    for reason <- [
          %ExecutionFailureError{message: "boom", details: %{code: :x}},
          %{code: :unknown_skill, message: "m", details: %{}},
          {:some, "tuple"},
          :bare_atom
        ] do
      response = ErrorBoundary.error_response(reason, @public)
      out = wire(response)

      assert %{"type" => "text", "text" => text} = hd(out["content"])
      assert text == inspect(reason)
      assert out["isError"] == true
    end
  end

  # ── (d) non-public servers keep the byte-identical legacy arm ────────────

  test "(d) consolidator + deposit servers emit the single-item legacy shape" do
    reason = %{code: :unknown_skill, message: "m", details: %{}}

    for server <- [
          JidoClaw.Memory.Consolidator.MCPServer,
          JidoClaw.Skills.Steps.ForgeExecutor.DepositServer
        ] do
      out = wire(ErrorBoundary.error_response(reason, server))

      assert out == %{
               "content" => [%{"type" => "text", "text" => inspect(reason)}],
               "isError" => true
             }
    end
  end

  test "(d) a consolidator-server tool failure through the runtime stays single-item" do
    key = unique_key("consolidator")

    assert {:reply, response, _frame} =
             call_tool(key, {:error, %{code: :x, message: "m", details: %{}}}, @consolidator)

    out = wire(response)
    assert out["isError"] == true
    assert [_single_item] = out["content"]
  end

  # ── (e) success responses untouched ──────────────────────────────────────

  test "(e) success responses keep the structuredContent path, no error items" do
    assert {:reply, response, _frame} =
             Runtime.handle_tool_call(
               @tools,
               "boundary_ok_tool",
               %{},
               %Frame{},
               @public
             )

    out = wire(response)
    assert out["isError"] == false
    assert out["structuredContent"] == %{value: 42}
  end

  # ── (f) non-JSON-safe nested details ─────────────────────────────────────

  test "(f) tuples, pids, invalid UTF-8 (value AND key), composite keys, improper lists stay decodable" do
    key = unique_key("unsafe-details")

    envelope = %{
      code: :unknown_skill,
      message: "m",
      details: %{
        <<255>> => "under-invalid-key",
        {:step, 3} => "at",
        tuple: {:a, 1},
        pid: self(),
        bad_bytes: <<"x-", 255, "-y">>,
        improper: [1 | 2]
      }
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    decoded = decode_item!(wire(response), 1)

    details = decoded["details"]
    assert details["tuple"] == ["a", 1]
    refute Map.has_key?(details, "pid")
    assert details["bad_bytes"] == "x-�-y"
    assert details["<<invalid-utf8:/w==>>"] == "under-invalid-key"
    # The wire path never dispatches key Inspect: composite keys arrive
    # under their constant class markers.
    assert details["<<key:tuple>>"] == "at"
    assert details["improper"] == [1, 2]
  end

  test "(f) a hostile-Inspect struct KEY takes its module marker — key Inspect never dispatches" do
    # Driven through error_response/2 directly: jido_action's OWN telemetry
    # sanitizer crashes on a throwing key Inspect before the boundary would
    # see the envelope on the runtime path (upstream, out of our control),
    # so the wire-boundary function is the provable surface here.
    reason = %{
      code: :unknown_skill,
      message: "m",
      details: %{%HostileInspect.Throwing{x: 1} => "under-hostile-key"}
    }

    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    assert decoded["details"]["<<key:struct:#{inspect(HostileInspect.Throwing)}>>"] ==
             "under-hostile-key"
  end

  # ── (g) belt-and-braces: hostile Inspect impls, all escape kinds ─────────

  test "(g) a reason whose Inspect impl RAISES still yields both items (Elixir's own diagnostic)" do
    key = unique_key("hostile-raise")

    assert {:reply, response, _frame} =
             call_tool(key, {:error, %HostileInspect.Raising{x: 1}})

    out = wire(response)
    assert out["isError"] == true
    assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]
    # Modern Elixir catches a raising impl inside inspect/1 itself.
    assert legacy =~ "Inspect.Error"
    assert %{"code" => _} = Jason.decode!(structured)
  end

  test "(g) throwing and exiting Inspect impls degrade to statics — never a protocol error" do
    for {label, struct} <- [
          {"hostile-throw", %HostileInspect.Throwing{x: 1}},
          {"hostile-exit", %HostileInspect.Exiting{x: 1}}
        ] do
      key = unique_key(label)

      assert {:reply, response, _frame} = call_tool(key, {:error, struct}),
             "#{label} must stay a tool response"

      out = wire(response)
      assert out["isError"] == true
      assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]
      assert legacy == "[uninspectable]"

      decoded = Jason.decode!(structured)
      assert is_binary(decoded["code"])
    end
  end

  test "(g) a SUCCESSFUL inspect returning invalid bytes: both items valid UTF-8, full round-trip" do
    key = unique_key("hostile-invalid-bytes")

    assert {:reply, response, _frame} =
             call_tool(key, {:error, %HostileInspect.InvalidBytes{x: 1}})

    out = wire(response)

    for %{"text" => text} <- out["content"] do
      assert String.valid?(text)
    end

    # The final-serialization pin: the whole protocol response must encode.
    assert {:ok, _json} = Jason.encode(out)
  end

  # Snapshot + restore the chaos-seam app env EXACTLY (fetch_env, not a
  # truthiness check — that would delete an original `false`, and the
  # junk-config row stores a literal false).
  defp restore_chaos_on_exit do
    original = Application.fetch_env(:jido_claw, :error_boundary_chaos)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jido_claw, :error_boundary_chaos, value)
        :error -> Application.delete_env(:jido_claw, :error_boundary_chaos)
      end
    end)
  end

  @static_fallback ~s({"code":"tool_error","message":"error serialization failed","details":{"retry":false}})

  test "(g) chaos-armed raise/throw/exit all yield the EXACT static fallback through the runtime" do
    restore_chaos_on_exit()

    for kind <- [:raise, :throw, :exit] do
      Application.put_env(:jido_claw, :error_boundary_chaos, kind)
      key = unique_key("chaos-#{kind}")

      assert {:reply, response, _frame} =
               call_tool(
                 key,
                 {:error, %{code: :unknown_skill, message: "m", details: %{retry: false}}}
               ),
             "#{kind} must stay a tool response, never a protocol error"

      out = wire(response)
      assert out["isError"] == true
      assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]

      # content[0] renders OUTSIDE the guarded region — unaffected by the
      # trip inside structured-item production.
      assert is_binary(legacy) and legacy != ""

      assert structured == @static_fallback

      assert Jason.decode!(structured) == %{
               "code" => "tool_error",
               "message" => "error serialization failed",
               "details" => %{"retry" => false}
             }
    end
  end

  test "(g) junk chaos config (a literal false) keeps the seam inert — normal envelope" do
    restore_chaos_on_exit()
    Application.put_env(:jido_claw, :error_boundary_chaos, false)

    key = unique_key("chaos-junk")

    assert {:reply, response, _frame} =
             call_tool(
               key,
               {:error, %{code: :unknown_skill, message: "m", details: %{retry: false}}}
             )

    decoded = decode_item!(wire(response), 1)
    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
  end

  test "(g) while armed, a consolidator-server call keeps the single-item legacy shape" do
    restore_chaos_on_exit()
    Application.put_env(:jido_claw, :error_boundary_chaos, :raise)

    key = unique_key("chaos-scope")

    assert {:reply, response, _frame} =
             call_tool(
               key,
               {:error, %{code: :x, message: "m", details: %{retry: false}}},
               @consolidator
             )

    out = wire(response)
    assert out["isError"] == true
    # structured_item/1 (and the seam) never runs for non-public servers.
    assert [_single_item] = out["content"]
  end

  # ── (i) retry regression (call-count) ────────────────────────────────────

  test "(i) a retry:false envelope executes EXACTLY once; the unflagged control retries" do
    flagged_key = unique_key("retry-flagged")

    assert {:reply, _response, _frame} =
             call_tool(
               flagged_key,
               {:error, %{code: :unknown_skill, message: "m", details: %{retry: false}}}
             )

    assert Scripts.count(flagged_key) == 1

    control_key = unique_key("retry-control")

    capture_log(fn ->
      assert {:reply, _response, _frame} =
               call_tool(
                 control_key,
                 {:error, %{code: :some_transient_thing, message: "m", details: %{}}}
               )
    end)

    # Default max_retries: 1 + unknown codes default retryable → 2 executions.
    assert Scripts.count(control_key) == 2
  end

  # ── (j) native typed errors ──────────────────────────────────────────────

  test "(j) schema-violating arguments decode to validation_error" do
    assert {:reply, response, _frame} =
             Runtime.handle_tool_call(
               @tools,
               "boundary_scripted_tool",
               # missing the required :key
               %{},
               %Frame{},
               @public
             )

    decoded = decode_item!(wire(response), 1)
    assert decoded["code"] == "validation_error"
    assert is_binary(decoded["message"]) and decoded["message"] != ""
  end

  test "(j) an explicit InvalidInputError preserves field/value + retry: false" do
    key = unique_key("invalid-input")

    error = %InvalidInputError{
      message: "key is malformed",
      field: :key,
      value: "zorp",
      details: %{}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "validation_error"
    assert decoded["details"]["field"] == "key"
    assert decoded["details"]["value"] == "zorp"
    assert decoded["details"]["retry"] == false
  end

  test "(j) an exec-level timeout decodes to the registered timeout code" do
    original = Application.get_env(:jido_action, :default_timeout)
    Application.put_env(:jido_action, :default_timeout, 100)

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_action, :default_timeout, original),
        else: Application.delete_env(:jido_action, :default_timeout)
    end)

    assert {:reply, response, _frame} =
             Runtime.handle_tool_call(
               @tools,
               "boundary_sleepy_tool",
               %{},
               %Frame{},
               @public
             )

    decoded = decode_item!(wire(response), 1)
    assert decoded["code"] == "timeout"
  end

  test "(j) a ConfigurationError reason translates to the registry's config_error" do
    key = unique_key("config-error")
    error = %ConfigurationError{message: "no provider", details: %{}}

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "config_error"
    assert decoded["details"]["retry"] == false
  end

  # ── (j) retry semantics: policy ELIGIBILITY, the class the gate consulted ─

  test "(j) a string-form retry:false hint ships the boolean; the gate read the same hint" do
    key = unique_key("retry-string-hint")
    error = %ExecutionFailureError{message: "boom", details: %{"retry" => false}}

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "execution_error"
    # The boolean — never "[key-collision]" beside a boundary-set twin.
    assert decoded["details"]["retry"] == false
    # The string hint fed the same class predicate the gate consulted.
    assert Scripts.count(key) == 1
  end

  test "(j) a type-hardcoded class overrides a stale producer retry:true hint" do
    key = unique_key("retry-stale-hint")

    error = %InvalidInputError{
      message: "bad",
      field: :key,
      value: "v",
      details: %{retry: true}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    # The class is type-hardcoded non-retryable: hints are honored only
    # where the type allows, and the wire matches the gate's class answer,
    # not the stale hint (the old Map.put_new would have advertised true).
    assert decoded["details"]["retry"] == false
    assert Scripts.count(key) == 1
  end

  test "(j) a junk retry hint folds through the predicate — a BOOLEAN ships, and the gate agreed" do
    key = unique_key("retry-junk-native")
    error = %ExecutionFailureError{message: "boom", details: %{retry: "junk"}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      # The predicate's hint-folding ("junk" != false → eligible) — never
      # the raw junk on a reserved wire key.
      assert decoded["details"]["retry"] == true
    end)

    # The gate retried on the same truthy fold.
    assert Scripts.count(key) == 2
  end

  test "(j) the eligibility pin: InternalError ships the CLASS answer the gate acted on" do
    key = unique_key("retry-eligibility")
    error = %InternalError{message: "boom", details: %{}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      # retryable?/1 hint-defaults this class TRUE where to_map's own
      # retryable? field hardcodes false — the divergence that forced
      # choosing the predicate. The gate retried once BECAUSE of that
      # class answer, then stopped at the attempt cap: the wire reports
      # the class, deliberately not the cap.
      assert decoded["code"] == "internal_error"
      assert decoded["details"]["retry"] == true
    end)

    assert Scripts.count(key) == 2
  end

  test "(j) tier-1 junk retry abstains — junk never rides a reserved key on any tier" do
    key = unique_key("retry-junk-envelope")
    envelope = %{code: :unknown_skill, message: "m", details: %{retry: "junk"}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      decoded = decode_item!(wire(response), 1)

      # Boolean-only typed field: the boundary abstains rather than
      # inventing advice...
      refute Map.has_key?(decoded["details"], "retry")
    end)

    # ...while the gate's own hint-fold read "junk" != false → retried.
    assert Scripts.count(key) == 2
  end

  # ── (j)/(a) reserved-key split: typed state + canonicalized twins ────────

  test "(j) adapter-owned string twins: struct field/value win, never the sentinel" do
    key = unique_key("twin-field-value")

    error = %InvalidInputError{
      message: "bad",
      field: :key,
      value: "v",
      details: %{"field" => "old", "value" => "old-v"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["details"]["field"] == "key"
    assert decoded["details"]["value"] == "v"
  end

  test "(j) the adapter's timeout beats a producer string twin; the class retry rides beside it" do
    key = unique_key("twin-timeout")
    error = %TimeoutError{message: "slow", timeout: 100, details: %{"timeout" => 5}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "timeout"
      assert decoded["details"]["timeout"] == 100
      # Type-hardcoded retryable class.
      assert decoded["details"]["retry"] == true
    end)

    assert Scripts.count(key) == 2
  end

  test "(j) tier-3 dual detail forms resolve atom-first — never the sentinel" do
    key = unique_key("twin-dual-form")

    error = %InvalidInputError{
      message: "bad",
      field: nil,
      value: nil,
      details: %{:field => "atom", "field" => "string"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["details"]["field"] == "atom"
  end

  test "(a) tier-2 uniform scope: a raw envelope's dual forms canonicalize at the build site" do
    # Through the runtime, exec wraps a raw map into ExecutionFailureError
    # (a tier-1 case); only a direct call exercises the raw-map tier-2 arm.
    reason = %{
      code: :unknown_skill,
      message: "m",
      details: %{:field => "atom", "field" => "string"}
    }

    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
    assert decoded["details"]["field"] == "atom"
  end

  test "(a) dual-form retry resolves atom-first on BOTH envelope tiers" do
    key = unique_key("twin-retry-dual")
    envelope = %{code: :unknown_skill, message: "m", details: %{:retry => false, "retry" => true}}

    # Tier 1 (the exec wrap) through the runtime...
    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    decoded = decode_item!(wire(response), 1)
    assert decoded["details"]["retry"] == false
    # ...where the dep's extract_retry_value read the same atom-first hint.
    assert Scripts.count(key) == 1

    # Tier 2 via the direct raw-map arm.
    direct = decode_item!(wire(ErrorBoundary.error_response(envelope, @public)), 1)
    assert direct["details"]["retry"] == false
  end

  test "(j) a partial pseudo-struct's merged atom field wins over the preserved string twin" do
    key = unique_key("pseudo-partial")

    # No :value key → to_map's PSEUDO clause merges field: :key beside the
    # preserved "field" string key.
    error = %{
      __struct__: InvalidInputError,
      __exception__: true,
      message: "bad",
      field: :key,
      details: %{"field" => "old"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "validation_error"
    assert decoded["details"]["field"] == "key"
    # retryable?/1's %InvalidInputError{} clause pattern-matches pseudo
    # shapes too.
    assert decoded["details"]["retry"] == false
  end

  test "(j) a string-keyed top-level pseudo field: atom precedence keeps tier values consistent" do
    key = unique_key("pseudo-string-top")

    error = %{
      :__struct__ => InvalidInputError,
      :__exception__ => true,
      :message => "bad",
      "field" => "top",
      :details => %{field: "base"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, error})
    decoded = decode_item!(wire(response), 1)

    # The pseudo merge yields %{:field => "base", "field" => "top"}; the
    # atom form is the SAME value an over-cap reduction retains, so values
    # never flip between tiers.
    assert decoded["details"]["field"] == "base"
  end

  test "(j) non-reserved twins keep the walker's sentinel (fixed-lookup canonicalization only)" do
    key = unique_key("non-reserved-twin")
    error = %ExecutionFailureError{message: "boom", details: %{1 => "a", "1" => "b"}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      # Wire key "1" is NOT reserved — canonicalization is fixed-lookup
      # bounded, and the documented collision sentinel stands.
      assert decoded["details"]["1"] == "[key-collision]"
    end)
  end

  # ── (b)-class boundary-owned key squatters ───────────────────────────────

  test "(b)+(n) a squatter under the ACTIVE fallback: the authoritative overlay wins" do
    key = unique_key("squatter-active")

    envelope = %{
      code: :zorb_squat,
      message: "m",
      details: %{"unregistered_code" => "squatter", retry: false}
    }

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "tool_error"
      # Never the sentinel, never "squatter".
      assert decoded["details"]["unregistered_code"] == ":zorb_squat"
      assert decoded["details"]["retry"] == false
    end)
  end

  test "(b) a squatter WITHOUT the fallback: the key is present exactly when the fallback fired" do
    key = unique_key("squatter-inactive")

    envelope = %{
      code: :unknown_skill,
      message: "m",
      details: %{"unregistered_code" => "squatter"}
    }

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "unknown_skill"
      refute Map.has_key?(decoded["details"], "unregistered_code")
    end)
  end

  test "(b) size-metadata squatters are stripped; a producer truncated boolean lifts" do
    key = unique_key("squatter-size-meta")

    envelope = %{
      code: :unknown_skill,
      message: "m",
      details: %{
        "original_byte_size" => 5,
        observed_at_least: 7,
        truncated: true,
        skill: "s"
      }
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    decoded = decode_item!(wire(response), 1)

    # Boundary measurements can't be counterfeited (both key forms
    # stripped at the build site).
    refute Map.has_key?(decoded["details"], "original_byte_size")
    refute Map.has_key?(decoded["details"], "observed_at_least")
    # The producer's own Tools.Error.sanitize_details/1 truncation signal
    # is legitimate — lifted through the typed field.
    assert decoded["details"]["truncated"] == true
    assert decoded["details"]["skill"] == "s"
  end

  test "(b) truncated dual form resolves atom-first; junk never squats the protocol key" do
    key = unique_key("truncated-dual")

    envelope = %{
      code: :unknown_skill,
      message: "m",
      details: %{:truncated => true, "truncated" => false, skill: "s"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    decoded = decode_item!(wire(response), 1)
    # Atom-first boolean extraction — never "[key-collision]" on the
    # protocol key.
    assert decoded["details"]["truncated"] == true
    assert decoded["details"]["skill"] == "s"

    junk_key = unique_key("truncated-junk")
    junk = %{code: :unknown_skill, message: "m", details: %{truncated: "junk"}}

    assert {:reply, junk_response, _frame} = call_tool(junk_key, {:error, junk})
    junk_decoded = decode_item!(wire(junk_response), 1)
    refute Map.has_key?(junk_decoded["details"], "truncated")
  end

  test "(k) a producer truncated:false can never mask a forced reduction (reduced AND minimal)" do
    # Reduced tier: the 4000-field filler forces over-cap.
    reduced_details =
      1..4_000
      |> Map.new(fn i -> {"field_#{i}", "v#{i}"} end)
      |> Map.merge(%{retry: false, truncated: false})

    reduced_reason = %{code: :unknown_skill, message: "m", details: reduced_details}
    reduced = decode_item!(wire(ErrorBoundary.error_response(reduced_reason, @public)), 1)

    assert reduced["details"]["truncated"] == true
    assert reduced["details"]["retry"] == false

    # Minimal tier: the wide-number forcing shape (numbers cost few
    # accounted bytes but large JSON, pushing the REDUCED tier over the
    # cap too — trunc_meta merges LAST on both reduction tiers).
    wide_numbers = Enum.map(1..900, fn i -> 100_000_000_000_000 + i end)

    minimal_details = %{
      retry: false,
      truncated: false,
      expected: wide_numbers,
      got: wide_numbers,
      available: wide_numbers,
      filler: String.duplicate("f", 64 * 1024)
    }

    minimal_reason = %{
      code: :unknown_skill,
      message: String.duplicate("m", 4_096),
      details: minimal_details
    }

    minimal = decode_item!(wire(ErrorBoundary.error_response(minimal_reason, @public)), 1)

    # Minimal tier: none of the allowlisted VALUES survive.
    refute Map.has_key?(minimal["details"], "expected")
    assert minimal["details"]["truncated"] == true
    assert minimal["details"]["retry"] == false
  end

  # ── (k) aggregate cap tiers ──────────────────────────────────────────────

  test "(k) a many-key details map reduces to ≤ 16 KiB with code + allowlist preserved" do
    details =
      1..4_000
      |> Map.new(fn i -> {"field_#{i}", "v#{i}"} end)
      |> Map.merge(%{retry: false, expected: "small-expected", got: "small-got"})

    reason = %{code: :unknown_skill, message: "m", details: details}
    out = wire(ErrorBoundary.error_response(reason, @public))

    [_legacy, %{"text" => structured}] = out["content"]
    assert byte_size(structured) <= 16 * 1024

    decoded = Jason.decode!(structured)
    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
    assert decoded["details"]["expected"] == "small-expected"
    assert decoded["details"]["got"] == "small-got"
    assert decoded["details"]["truncated"] == true
    refute Map.has_key?(decoded["details"], "field_1")
  end

  test "(k) string-keyed allowlist variants survive the reduction" do
    details =
      1..4_000
      |> Map.new(fn i -> {"field_#{i}", "v#{i}"} end)
      |> Map.merge(%{"retry" => false, "expected" => "sk-expected"})

    reason = %{code: :unknown_skill, message: "m", details: details}
    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    assert decoded["details"]["retry"] == false
    assert decoded["details"]["expected"] == "sk-expected"
  end

  test "(k) an oversized available list is element-wise bounded with the flag flipped" do
    filler = Map.new(1..4_000, fn i -> {"field_#{i}", "v#{i}"} end)
    available = Enum.map(1..9_000, fn i -> "skill_name_number_#{i}" end)
    details = Map.merge(filler, %{retry: false, available: available})

    reason = %{code: :unknown_skill, message: "m", details: details}
    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    kept = decoded["details"]["available"]
    assert is_list(kept)
    assert length(kept) < length(available)
    assert decoded["details"]["available_truncated"] == true
  end

  test "(k) a single ~32 KiB expected binary is re-bounded by the shared budget" do
    filler = Map.new(1..4_000, fn i -> {"field_#{i}", "v#{i}"} end)
    details = Map.merge(filler, %{retry: false, expected: String.duplicate("e", 32 * 1024)})

    reason = %{code: :unknown_skill, message: "m", details: details}
    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    assert byte_size(decoded["details"]["expected"]) <= 2 * 1024 + byte_size("... (truncated)")
    assert decoded["details"]["expected"] =~ "... (truncated)"
  end

  test "(k)+(n) a reduction still over the cap falls to the minimal envelope with retry + unregistered_code" do
    # Wide numeric structures cost few accounted bytes but large JSON — the
    # small per-field pass admits them, pushing the reduced tier over the
    # cap so the minimal tier fires (the every-tier pin).
    wide_numbers = Enum.map(1..900, fn i -> 100_000_000_000_000 + i end)

    details = %{
      retry: false,
      expected: wide_numbers,
      got: wide_numbers,
      available: wide_numbers,
      filler: String.duplicate("f", 64 * 1024)
    }

    reason = %{code: :zorb_minimal, message: String.duplicate("m", 4_096), details: details}

    capture_log(fn ->
      decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

      assert decoded["code"] == "tool_error"
      assert decoded["details"]["retry"] == false
      assert decoded["details"]["unregistered_code"] == ":zorb_minimal"
      assert decoded["details"]["truncated"] == true
      # Minimal tier: none of the allowlisted VALUES survive.
      refute Map.has_key?(decoded["details"], "expected")
      refute Map.has_key?(decoded["details"], "got")
    end)
  end

  # ── (l) proxy/LoopGuard composition ──────────────────────────────────────

  test "(l) content[1] survives the proxy re-surface + LoopGuard directive append" do
    key = unique_key("proxy-compose")
    envelope = %{code: :unknown_skill, message: "m", details: %{retry: false}}

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    out = wire(response)

    # The external-MCP proxy re-surfaces the raw domain isError result map
    # (string keys) as {:ok, data}; LoopGuard may then APPEND a directive.
    resurfaced = %{"isError" => out["isError"], "content" => out["content"]}

    assert {:ok, relayed} =
             LoopGuard.append_directive({:ok, resurfaced}, "[DOOM LOOP RECOVERY: test]")

    content = relayed["content"]
    assert [_legacy, _canonical, _directive] = content

    # The canonical envelope is content[1] — the SECOND raw-wire item —
    # regardless of appended items; "the final item" would now be wrong.
    assert %{"code" => "unknown_skill"} = Jason.decode!(Enum.at(content, 1)["text"])
    assert Enum.at(content, 2)["text"] =~ "DOOM LOOP RECOVERY"
  end

  # ── (m) protocol-error scope ─────────────────────────────────────────────

  test "(m) an unknown tool name is a JSON-RPC protocol error — no envelope" do
    assert {:error, %Anubis.MCP.Error{} = error, %Frame{}} =
             Runtime.handle_tool_call(
               @tools,
               "no_such_tool",
               %{},
               %Frame{},
               @public
             )

    assert error.reason == :invalid_params
  end

  # ── (n) unregistered + retry through every tier ──────────────────────────

  test "(n) an unregistered envelope with retry: false keeps the bit beside unregistered_code" do
    key = unique_key("unregistered-retry")
    envelope = %{code: :zorb_flagged, message: "m", details: %{retry: false}}

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "tool_error"
      assert decoded["details"]["retry"] == false
      assert decoded["details"]["unregistered_code"] == ":zorb_flagged"
    end)

    # The flag also suppressed the in-call retry (single execution).
    assert Scripts.count(key) == 1
  end

  test "(n) an unregistered over-cap envelope keeps unregistered_code through the reduced tier" do
    filler = Map.new(1..4_000, fn i -> {"field_#{i}", "v#{i}"} end)
    reason = %{code: :zorb_huge, message: "m", details: Map.put(filler, :retry, false)}

    capture_log(fn ->
      decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

      assert decoded["code"] == "tool_error"
      assert decoded["details"]["unregistered_code"] == ":zorb_huge"
      assert decoded["details"]["retry"] == false
      assert decoded["details"]["truncated"] == true
    end)
  end

  # ── (o) resource bounds ──────────────────────────────────────────────────

  test "(o) extreme key count / deep nesting / oversized invalid key terminate promptly" do
    extreme_keys = Map.new(1..200_000, fn i -> {"k#{i}", i} end)
    deep = Enum.reduce(1..500, "leaf", fn _i, acc -> %{"d" => acc} end)
    invalid_key = Map.new([{<<255>> <> :binary.copy(<<254>>, 4_000), "v"}])

    for details <- [extreme_keys, deep, invalid_key] do
      reason = %{code: :unknown_skill, message: "m", details: details}

      {elapsed_us, decoded} =
        :timer.tc(fn ->
          decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
        end)

      assert decoded["code"] == "unknown_skill"
      assert elapsed_us < 5_000_000, "boundary walk must short-circuit, not crawl"
    end
  end

  test "(o) the same extreme shapes flow through LoopGuard observation promptly" do
    context = %{
      tool_context: %{
        tenant_id: "boundary-test-tenant",
        session_uuid: "boundary-test-session",
        session_id: "boundary-test-session"
      }
    }

    extreme = Map.new(1..200_000, fn i -> {"k#{i}", i} end)
    result = {:error, %{code: :unknown_skill, message: "m", details: extreme}}

    {elapsed_us, observed} =
      :timer.tc(fn ->
        LoopGuard.observe_result(result, "boundary_scripted_tool", %{}, context, enabled?: true)
      end)

    assert observed == result
    assert elapsed_us < 5_000_000, "the fingerprint projection must short-circuit"
  end

  test "(o) a budget-tripping envelope with expected: self() reduces decodably, retry intact" do
    filler = Map.new(1..4_000, fn i -> {"field_#{i}", "v#{i}"} end)
    details = Map.merge(filler, %{retry: false, expected: self()})

    reason = %{code: :unknown_skill, message: "m", details: details}
    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
    # The fresh small bounded JsonSafe pass renders the pid as null — never
    # a needless static-fallback escalation.
    assert Map.has_key?(decoded["details"], "expected")
    assert decoded["details"]["expected"] == nil
  end

  test "(o) a retained expected value whose own small pass trips becomes the constant marker" do
    filler = Map.new(1..4_000, fn i -> {"field_#{i}", "v#{i}"} end)
    deep_expected = Enum.reduce(1..5_000, "leaf", fn _i, acc -> [acc] end)
    details = Map.merge(filler, %{retry: false, expected: deep_expected})

    reason = %{code: :unknown_skill, message: "m", details: details}
    decoded = decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)

    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
    assert decoded["details"]["expected"] == "[truncated]"
  end

  # ── (j)/(o) tier 4 + the shared legacy render (P1d) ──────────────────────

  test "(j) a foreign exception's structured message IS content[0]'s text (the shared render)" do
    key = unique_key("tier4-shared")

    capture_log(fn ->
      assert {:reply, response, _frame} =
               call_tool(key, {:error, %RuntimeError{message: "kaboom"}})

      out = wire(response)

      assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]
      decoded = Jason.decode!(structured)

      assert decoded["code"] == "tool_error"
      assert decoded["message"] == legacy
      assert decoded["details"] == %{}
    end)
  end

  test "(j) the single-render counter pin: the reason is inspected EXACTLY once across both items" do
    ref = :atomics.new(1, [])
    reason = %HostileInspect.Counting{ref: ref}

    out = wire(ErrorBoundary.error_response(reason, @public))

    assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]
    decoded = Jason.decode!(structured)

    assert decoded["code"] == "tool_error"
    assert decoded["message"] == legacy
    # Nothing else on this path dispatches value Inspect: the reason never
    # enters the walker on tier 4, and content[0]'s render is threaded
    # into the structured branch rather than re-rendered.
    assert :atomics.get(ref, 1) == 1
  end

  test "(o) a bignum-bearing foreign exception: ONE render, reused, then budget-tripped" do
    # Driven directly, NOT through the runtime: the runtime path would ALSO
    # render the decimal once per attempt via the dep's cond_log_error plus
    # the :full-telemetry to_map walk — the named upstream residuals. The
    # boundary-scoped drive is what the guarantee actually claims.
    reason = %BigFieldError{message: "boom-big", big: Integer.pow(10, 200_000)}

    {elapsed_us, out} =
      :timer.tc(fn -> wire(ErrorBoundary.error_response(reason, @public)) end)

    assert [%{"text" => legacy}, %{"text" => structured}] = out["content"]
    decoded = Jason.decode!(structured)

    assert decoded["code"] == "tool_error"
    # The reduced-tier message is a truncated prefix of content[0]'s text —
    # one render, reused, then budget-tripped into the reduced tier.
    assert String.ends_with?(decoded["message"], "... (truncated)")
    prefix = String.trim_trailing(decoded["message"], "... (truncated)")
    assert String.starts_with?(legacy, prefix)
    assert elapsed_us < 5_000_000, "the structured branch must not re-render the term"
  end

  # ── (j)/(k)/(o) bignum width bounds (Fix 3, structured-branch scope) ─────

  test "(k) a huge-integer hint value reduces to the constant marker, retry intact, promptly" do
    reason = %{
      code: :unknown_skill,
      message: "m",
      details: %{retry: false, expected: Integer.pow(10, 200_000)}
    }

    {elapsed_us, decoded} =
      :timer.tc(fn ->
        decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
      end)

    assert decoded["code"] == "unknown_skill"
    # The boundary's own machinery never renders the decimal uncharged
    # (content[0] renders it once — the declared residual).
    assert decoded["details"]["expected"] == "[truncated]"
    assert decoded["details"]["retry"] == false
    assert elapsed_us < 5_000_000
  end

  test "(j) a huge-integer native detail KEY takes the constant marker (dep sort-key residual)" do
    reason = %ExecutionFailureError{
      message: "boom",
      details: %{Integer.pow(10, 200_000) => "v", retry: false}
    }

    {elapsed_us, decoded} =
      :timer.tc(fn ->
        decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
      end)

    # to_map's sanitizer renders the key once at limit: :infinity solely as
    # a transient SORT key and discards it; Map.new retains the original
    # bignum key, so the walker receives it and emits the constant marker —
    # the unbounded render is the dep's, exactly once, and the boundary
    # side stays O(1).
    assert decoded["details"]["<<key:bigint>>"] == "v"
    assert decoded["details"]["retry"] == false
    assert elapsed_us < 5_000_000
  end

  test "(j) an unsupported native detail VALUE renders once in the dep, then budget-trips" do
    # A large non-byte-aligned bitstring — an unsupported sanitizer class:
    # to_map's sanitizer safe_inspects it in full (the named residual),
    # after which the walker byte-charges the resulting string and trips
    # into the reduced tier.
    reason = %ExecutionFailureError{
      message: "boom",
      details: %{blob: <<0::size(1_048_577)>>, retry: false}
    }

    {elapsed_us, decoded} =
      :timer.tc(fn ->
        decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
      end)

    assert decoded["code"] == "execution_error"
    assert decoded["details"]["retry"] == false
    assert decoded["details"]["truncated"] == true
    assert elapsed_us < 5_000_000
  end

  test "(j) a huge non-binary native message projects to the placeholder; a binary control survives" do
    reason = %ExecutionFailureError{
      message: Integer.pow(10, 200_000),
      details: %{retry: false}
    }

    {elapsed_us, decoded} =
      :timer.tc(fn ->
        decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
      end)

    # The projection fires BEFORE to_map's limit: :infinity message inspect.
    assert decoded["message"] == "[unrenderable message]"
    assert decoded["details"]["retry"] == false
    assert elapsed_us < 5_000_000

    control = %ExecutionFailureError{message: "exact text", details: %{retry: false}}
    control_decoded = decode_item!(wire(ErrorBoundary.error_response(control, @public)), 1)
    assert control_decoded["message"] == "exact text"
  end

  test "(o) native errors with huge/deep details terminate promptly (boundary-scoped, and says so)" do
    # On the runtime path the dep's :full-telemetry span walks the same
    # reason unbounded upstream regardless — these rows prove the boundary
    # adds no unbounded work of its own beyond the named tier-3 dep-parity
    # residual (to_map's sanitizer walk + retryable?/1's nested-reason hint
    # walk, both exercised by the deep chain), so they drive
    # error_response/2 directly.
    scalars = Map.new(1..30, fn i -> {"k#{i}", i} end)

    wide = %ExecutionFailureError{
      message: "wide",
      details: Map.merge(scalars, %{zzz: Enum.to_list(1..500_000), retry: false})
    }

    deep_chain = Enum.reduce(1..100_000, %{leaf: true}, fn _i, acc -> %{reason: acc} end)
    deep = %ExecutionFailureError{message: "deep", details: deep_chain}

    for reason <- [wide, deep] do
      {elapsed_us, decoded} =
        :timer.tc(fn ->
          decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
        end)

      assert decoded["code"] == "execution_error"
      assert elapsed_us < 5_000_000, "the boundary walk must short-circuit, not crawl"
    end
  end

  test "(o) a hostile calendar detail refuses the fast path and budget-trips, never renders" do
    hostile_date = %{
      __struct__: Date,
      calendar: Calendar.ISO,
      year: Integer.pow(10, 200_000),
      month: 1,
      day: 1
    }

    reason = %{code: :unknown_skill, message: "m", details: %{at: hostile_date}}

    {elapsed_us, decoded} =
      :timer.tc(fn ->
        decode_item!(wire(ErrorBoundary.error_response(reason, @public)), 1)
      end)

    # The fast-path gate refuses (bignum year), the generic walk charges
    # the year via the bignum rule, the budget trips — the decimal is
    # never rendered by the boundary's own machinery (content[0]'s single
    # legacy render is the declared residual).
    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["truncated"] == true
    assert elapsed_us < 5_000_000
  end

  # ── (p) tier-1 wrap provenance: witnessed, never shape-inferred ──────────
  # (PORT-PD1-2-EXEC — the forked Jido.Exec stamps a per-call ref onto the
  # wrap of a raw canonical envelope; the boundary detaches on exact ref
  # identity and tier 1 requires the witness.)

  test "(p) THE regression: a hand-built ExecutionFailureError with code+details is execution_error, never the nested code" do
    key = unique_key("provenance-shape-collision")

    error = %ExecutionFailureError{
      message: "boom",
      details: %{code: :unknown_skill, details: %{sneaky: true}}
    }

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      # Pre-fix this shape mis-tiered into tier 1 and the wire reported
      # "unknown_skill" as the domain code.
      assert decoded["code"] == "execution_error"
      # Authoritative retry from the class predicate (hint-defaults true) —
      # never a producer hint riding a counterfeit tier-1 envelope.
      assert decoded["details"]["retry"] == true
      # The colliding code/details ride the extras bag as DATA.
      assert decoded["details"]["code"] == "unknown_skill"
      assert decoded["details"]["details"] == %{"sneaky" => true}
    end)

    # The gate acted on the same class answer: one retry, then the cap.
    assert Scripts.count(key) == 2
  end

  test "(p) direct twin: the same struct via error_response/2 hits tier 3 (the crispest pin of the finding)" do
    error = %ExecutionFailureError{
      message: "boom",
      details: %{code: :unknown_skill, details: %{}}
    }

    decoded = decode_item!(wire(ErrorBoundary.error_response(error, @public)), 1)

    assert decoded["code"] == "execution_error"
    assert decoded["details"]["code"] == "unknown_skill"
  end

  test "(p) a canonical envelope still hits tier 1 end-to-end; content[0] restored to the unpatched bytes" do
    key = unique_key("provenance-envelope")

    envelope = %{
      code: :unknown_skill,
      message: "plain ascii boom",
      details: %{retry: false, skill: "zorp"}
    }

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
    out = wire(response)

    decoded = decode_item!(out, 1)
    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
    assert decoded["details"]["skill"] == "zorp"

    # content[0] byte-equals the UNPATCHED world's wrap render — the detach
    # restored exact bytes (sanitize-neutral plain-ASCII message).
    expected_wrap =
      JidoActionError.execution_error("plain ascii boom", Map.delete(envelope, :message))

    assert %{"text" => legacy} = hd(out["content"])
    assert legacy == inspect(expected_wrap)

    # The marker text is ABSENT from both items.
    for %{"text" => text} <- out["content"] do
      refute text =~ "__jido_claw_exec_wrapped__"
    end
  end

  test "(p) the 3-tuple wrap arm marks independently: {:error, envelope, directive} hits tier 1" do
    key = unique_key("provenance-3tuple")
    envelope = %{code: :unknown_skill, message: "m", details: %{retry: false}}

    assert {:reply, response, _frame} = call_tool(key, {:error, envelope, :some_directive})
    decoded = decode_item!(wire(response), 1)

    assert decoded["code"] == "unknown_skill"
    assert decoded["details"]["retry"] == false
  end

  test "(p) a colliding NON-exception struct wraps unstamped on BOTH arms — never the nested code" do
    struct = %CollidingStruct{message: "boom", code: :unknown_skill, details: %{}}

    for {label, scripted} <- [
          {"2tuple", {:error, struct}},
          {"3tuple", {:error, struct, :some_directive}}
        ] do
      key = unique_key("provenance-collide-#{label}")

      capture_log(fn ->
        assert {:reply, response, _frame} = call_tool(key, scripted)
        decoded = decode_item!(wire(response), 1)

        # extract_error_fields' struct clause produced the colliding
        # %{code:, details:} shape, but the pre-wrap term was no envelope —
        # unstamped, tier 3 holds.
        assert decoded["code"] == "execution_error",
               "#{label}: a colliding struct must never select tier 1"

        assert decoded["details"]["code"] == "unknown_skill"
      end)
    end
  end

  test "(p) near-envelope maps wrap unstamped: non-binary message and message-less shapes demote" do
    for {label, reason} <- [
          {"non-binary-message", %{code: :unknown_skill, message: 123, details: %{}}},
          {"message-less", %{code: :unknown_skill, details: %{}}}
        ] do
      key = unique_key("provenance-near-#{label}")

      capture_log(fn ->
        assert {:reply, response, _frame} = call_tool(key, {:error, reason})
        decoded = decode_item!(wire(response), 1)

        # The stamp condition is the raw envelope contract — exactly tier
        # 2's guard; these shapes previously hit tier 1 via shape alone.
        assert decoded["code"] == "execution_error", label
      end)
    end
  end

  test "(p) a producer squatting the marker key keeps its junk (put_new law): tier 3, bytes faithful, wire stripped" do
    key = unique_key("provenance-squat")

    envelope = %{
      code: :unknown_skill,
      message: "m",
      details: %{},
      __jido_claw_exec_wrapped__: :junk
    }

    capture_log(fn ->
      assert {:reply, response, _frame} = call_tool(key, {:error, envelope})
      out = wire(response)

      # The junk value fails the exact-ref identity check → tier 3.
      decoded = decode_item!(out, 1)
      assert decoded["code"] == "execution_error"

      # content[0] CONTAINS the squat — Map.put_new never overwrote, so the
      # delivered term is byte-identical to the unpatched world's.
      expected_wrap = JidoActionError.execution_error("m", Map.delete(envelope, :message))
      assert %{"text" => legacy} = hd(out["content"])
      assert legacy == inspect(expected_wrap)
      assert legacy =~ "__jido_claw_exec_wrapped__"

      # Wire details LACK the marker key (boundary-owned strip).
      refute Map.has_key?(decoded["details"], "__jido_claw_exec_wrapped__")
    end)
  end

  test "(p) a forged reference under the marker key never selects tier 1 and never rides the wire" do
    key = unique_key("provenance-forged-ref")

    error = %ExecutionFailureError{
      message: "boom",
      details: %{code: :unknown_skill, details: %{}, __jido_claw_exec_wrapped__: make_ref()}
    }

    capture_log(fn ->
      # Verbatim exception pass-through delivers the forged marker intact;
      # it is not the minted token, so tier 1 refuses.
      assert {:reply, response, _frame} = call_tool(key, {:error, error})
      decoded = decode_item!(wire(response), 1)

      assert decoded["code"] == "execution_error"
      refute Map.has_key?(decoded["details"], "__jido_claw_exec_wrapped__")
    end)
  end

  test "(p) non-public servers: the COMPLETE response is the single-item inspect of the UNMARKED wrap" do
    envelope = %{code: :unknown_skill, message: "m", details: %{retry: false}}
    expected_wrap = JidoActionError.execution_error("m", Map.delete(envelope, :message))

    for server <- [@consolidator, JidoClaw.Skills.Steps.ForgeExecutor.DepositServer] do
      key = unique_key("provenance-nonpublic")

      assert {:reply, response, _frame} = call_tool(key, {:error, envelope}, server)

      # Byte-for-byte the legacy single-item shape over the UNMARKED wrap —
      # fails loudly if minting ever goes unconditional.
      assert wire(response) == %{
               "content" => [%{"type" => "text", "text" => inspect(expected_wrap)}],
               "isError" => true
             }
    end
  end

  test "(p) no published tool has compensation ENABLED (the nesting residual stays unreachable)" do
    servers = [@public, @consolidator, JidoClaw.Skills.Steps.ForgeExecutor.DepositServer]

    for server <- servers, tool <- server.__publish__().tools do
      refute Compensation.enabled?(tool),
             "#{inspect(tool)} (#{inspect(server)}) enables compensation — an enabled " <>
               "on_error/4 would nest a marked error inside a NEW unmarked " <>
               "ExecutionFailureError beyond detach's reach; re-derive the documented " <>
               "residual in docs/system/mcp-server-surface.md before enabling"
    end
  end
end
