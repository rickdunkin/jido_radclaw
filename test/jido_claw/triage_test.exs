defmodule JidoClaw.TriageTest do
  @moduledoc """
  Unit coverage for AR-8 triage (Phase 3a): the `Verdict` normalizer, the default
  `LLM` impl's response-unwrap + no-self-coerce contract, and the façade's
  single-fail-safe-boundary + telemetry behavior. No real LLM, no composer.

  Non-async: mutates `:triage_impl` / `:triage_generate` app env and attaches a
  telemetry handler.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Triage
  alias JidoClaw.Triage.LLM
  alias JidoClaw.Triage.Schema
  alias JidoClaw.Triage.Verdict

  # --- Custom impls exercising every façade fail-safe branch ---

  defmodule ErrImpl do
    @behaviour JidoClaw.Triage
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: {:error, :boom}
  end

  defmodule NonVerdictImpl do
    @behaviour JidoClaw.Triage
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: {:ok, :not_a_verdict}
  end

  defmodule RaiseImpl do
    @behaviour JidoClaw.Triage
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: raise("kaboom")
  end

  defmodule ThrowImpl do
    @behaviour JidoClaw.Triage
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: throw(:thrown)
  end

  defmodule CodeImpl do
    @behaviour JidoClaw.Triage
    alias JidoClaw.Triage.Verdict
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: {:ok, %Verdict{path: :code}}
  end

  defmodule TalkImpl do
    @behaviour JidoClaw.Triage
    alias JidoClaw.Triage.Verdict
    @impl JidoClaw.Triage
    def classify(_message, _opts), do: {:ok, Verdict.talk()}
  end

  setup do
    on_exit(fn ->
      # config/test.exs sets the impl to the stub — restore it, and clear the
      # generate seam so a later test isn't poisoned.
      Application.put_env(:jido_claw, :triage_impl, JidoClaw.Test.TriageStub)
      Application.delete_env(:jido_claw, :triage_generate)
    end)

    :ok
  end

  defp resp(object) do
    %ReqLLM.Response{id: "test", model: "test", context: nil, object: object}
  end

  defp stub_generate(fun), do: Application.put_env(:jido_claw, :triage_generate, fun)

  # ===========================================================================
  # Verdict.from_map/1
  # ===========================================================================

  describe "Verdict.from_map/1" do
    test "normalizes a string-keyed object (the generate_object shape)" do
      assert {:ok, verdict} =
               Verdict.from_map(%{
                 "path" => "code",
                 "signals" => ["auth-surface", "bug"],
                 "est_size" => "M",
                 "intent" => "add login",
                 "intent_confirmed" => true,
                 "reasons" => %{"path" => "explicit ask"}
               })

      assert verdict.path == :code
      assert verdict.signals == [:auth_surface, :bug]
      assert verdict.est_size == :m
      assert verdict.intent == "add login"
      assert verdict.intent_confirmed?
    end

    test "normalizes an atom-keyed object" do
      assert {:ok, %Verdict{path: :talk}} = Verdict.from_map(%{path: "talk"})
    end

    test "AR-8b-2 F2: the must-execute signal normalizes to :must_execute" do
      assert {:ok, verdict} =
               Verdict.from_map(%{"path" => "sketch", "signals" => ["must-execute"]})

      assert verdict.path == :sketch
      assert verdict.signals == [:must_execute]
    end

    test "AR-9: multi_plan defaults false and coerces only a literal true (mirrors intent_confirmed)" do
      assert {:ok, %Verdict{multi_plan?: false}} = Verdict.from_map(%{"path" => "code"})

      assert {:ok, %Verdict{multi_plan?: true}} =
               Verdict.from_map(%{"path" => "code", "multi_plan" => true})

      # Atom-safe / falsy coercion: any non-literal-true value stays false.
      for bad <- ["true", 1, nil, false, "yes"] do
        assert {:ok, %Verdict{multi_plan?: false}} =
                 Verdict.from_map(%{"path" => "code", "multi_plan" => bad})
      end
    end

    test "AR-9: the triage schema accepts the optional multi_plan boolean" do
      schema = Schema.zoi()

      # Optional: a verdict omitting it still validates; present it must be a bool.
      assert {:ok, _} = Zoi.parse(schema, %{"path" => "code"})
      assert {:ok, parsed} = Zoi.parse(schema, %{"path" => "code", "multi_plan" => true})
      assert parsed["multi_plan"] == true
      assert {:error, _} = Zoi.parse(schema, %{"path" => "code", "multi_plan" => "yes"})
    end

    test "a malformed or absent path is {:error, :invalid_verdict} (R6-P2)" do
      assert {:error, :invalid_verdict} = Verdict.from_map(%{"path" => "bogus"})
      assert {:error, :invalid_verdict} = Verdict.from_map(%{"signals" => []})
      assert {:error, :invalid_verdict} = Verdict.from_map("not a map")
    end

    test "reasons stays string-keyed (R5-P3)" do
      assert {:ok, %Verdict{reasons: reasons}} =
               Verdict.from_map(%{"path" => "talk", "reasons" => %{"why" => "a question"}})

      assert reasons == %{"why" => "a question"}
      assert Enum.all?(Map.keys(reasons), &is_binary/1)
    end

    test "composer?/1 is true for code/system/sketch, false for talk" do
      assert Verdict.composer?(%Verdict{path: :code})
      assert Verdict.composer?(%Verdict{path: :system})
      assert Verdict.composer?(%Verdict{path: :sketch})
      refute Verdict.composer?(%Verdict{path: :talk})
    end
  end

  # ===========================================================================
  # Verdict.to_map/1 — the pending_clarify wire form (inverse of from_map/1)
  # ===========================================================================

  describe "Verdict.to_map/1" do
    test "round-trips every field, including hyphenated wire signals" do
      verdict = %Verdict{
        path: :code,
        signals: [:significant_build, :auth_surface, :must_execute, :bug],
        est_size: :xl,
        intent: "build the thing",
        intent_confirmed?: true,
        multi_plan?: true,
        acceptance_criteria: ["`mix test` passes", "GET /health returns 200"],
        reasons: %{"path" => "explicit ask"}
      }

      map = Verdict.to_map(verdict)

      # WIRE strings, never `to_string/1` of the atom — "significant_build"
      # would be silently dropped by from_map's whitelist on reload.
      assert "significant-build" in map["signals"]
      assert "auth-surface" in map["signals"]
      assert "must-execute" in map["signals"]
      assert map["est_size"] == "XL"

      assert {:ok, ^verdict} = Verdict.from_map(map)
    end

    test "round-trips the fail-safe talk verdict (nil est_size/intent)" do
      verdict = Verdict.talk()
      assert {:ok, ^verdict} = Verdict.from_map(Verdict.to_map(verdict))
    end

    test "from_map normalizes junk acceptance_criteria (item 9, extraction-only field)" do
      assert {:ok, verdict} =
               Verdict.from_map(%{"path" => "code", "acceptance_criteria" => ["ok", 42, "  "]})

      assert verdict.acceptance_criteria == ["ok"]

      assert {:ok, %Verdict{acceptance_criteria: []}} =
               Verdict.from_map(%{"path" => "code", "acceptance_criteria" => "junk"})
    end

    test "is JSON-safe: string keys throughout, Jason-encodable" do
      map = Verdict.to_map(%Verdict{path: :system, signals: [:secrets]})
      assert Enum.all?(Map.keys(map), &is_binary/1)
      assert {:ok, _} = Jason.encode(map)
    end
  end

  # ===========================================================================
  # Triage.LLM — unwraps the response object, never self-coerces
  # ===========================================================================

  describe "Triage.LLM" do
    test "unwraps the ReqLLM.Response object and normalizes (R2-P1)" do
      stub_generate(fn _input, _schema, _opts ->
        {:ok, resp(%{"path" => "code", "signals" => ["needs-tests"]})}
      end)

      assert {:ok, %Verdict{path: :code, signals: [:needs_tests]}} = LLM.classify("do x", [])
    end

    test "a genuine talk object is {:ok, talk}, not an error" do
      stub_generate(fn _i, _s, _o -> {:ok, resp(%{"path" => "talk"})} end)
      assert {:ok, %Verdict{path: :talk}} = LLM.classify("what is x?", [])
    end

    test "a generate error returns {:error, _} — no self-coerce to talk (R5-P2)" do
      stub_generate(fn _i, _s, _o -> {:error, :timeout} end)
      assert {:error, :timeout} = LLM.classify("do x", [])
    end

    test "a malformed object path returns {:error, :invalid_verdict} (R6-P2)" do
      stub_generate(fn _i, _s, _o -> {:ok, resp(%{"path" => "nonsense"})} end)
      assert {:error, :invalid_verdict} = LLM.classify("do x", [])
    end
  end

  # ===========================================================================
  # Triage.classify façade — single fail-safe boundary + telemetry
  # ===========================================================================

  describe "Triage.classify (façade)" do
    test "coerces an impl {:error,_} to {:ok, talk}" do
      Application.put_env(:jido_claw, :triage_impl, ErrImpl)
      assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")
    end

    test "coerces a non-Verdict return to {:ok, talk}" do
      Application.put_env(:jido_claw, :triage_impl, NonVerdictImpl)
      assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")
    end

    test "coerces a raising impl to {:ok, talk}" do
      Application.put_env(:jido_claw, :triage_impl, RaiseImpl)
      assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")
    end

    test "coerces a throwing impl to {:ok, talk} (R6-P3)" do
      Application.put_env(:jido_claw, :triage_impl, ThrowImpl)
      assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")
    end

    test "a genuine ok verdict passes through" do
      Application.put_env(:jido_claw, :triage_impl, CodeImpl)
      assert {:ok, %Verdict{path: :code}} = Triage.classify("x")
    end
  end

  describe "Triage telemetry (R3-P3/R4-P2)" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:jido_claw, :triage, :classified],
        fn _event, measurements, metadata, _config ->
          send(parent, {:triage_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      :ok
    end

    test "emits one event with path/model/fallback? — false on a genuine verdict (incl real talk)" do
      Application.put_env(:jido_claw, :triage_impl, TalkImpl)
      assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")

      assert_receive {:triage_telemetry, %{duration_ms: ms},
                      %{path: :talk, fallback?: false, model: _model}}

      assert is_integer(ms)
      refute_received {:triage_telemetry, _, _}
    end

    test "fallback? is true when the impl errors/raises/throws/returns non-Verdict" do
      for impl <- [ErrImpl, NonVerdictImpl, RaiseImpl, ThrowImpl] do
        Application.put_env(:jido_claw, :triage_impl, impl)
        assert {:ok, %Verdict{path: :talk}} = Triage.classify("x")
        assert_receive {:triage_telemetry, _meas, %{path: :talk, fallback?: true}}
      end
    end
  end
end
