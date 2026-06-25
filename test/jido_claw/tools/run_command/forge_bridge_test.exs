defmodule JidoClaw.Tools.RunCommand.ForgeBridgeTest do
  @moduledoc """
  The pure, load-bearing core of the RunCommand↔Forge bridge (AR-8b-2 F2):

    * `normalize_exec_result/2` — adapts every `Forge.exec/3` return shape,
      disambiguating the Docker backend's manufactured `{message, code}` pairs
      (exact/anchored, never code-alone) from a user command's own 124/153/127;
    * `derive_inner_timeout/2` — the inner Forge timeout derived from the outer
      `Jido.Exec` deadline; and
    * non-retryability of EVERY bridge error map at BOTH retry layers — the
      ReAct `Tools.Error.normalize_result/1` → `Jido.AI.Error.retryable?/1`
      pipeline and `Jido.Exec`'s own `Jido.Action.Error.retryable?/1`.

  Wiring + the timeout race through the live action wrapper live in
  `run_command_test.exs`; this file is pure (no Forge session, no app env).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Forge
  alias JidoClaw.Tools.Error
  alias JidoClaw.Tools.RunCommand.ForgeBridge

  # The inner timeout the bridge "passed" — the manufactured timeout message is
  # exact-matched against this exact value.
  @inner 5_000

  describe "normalize_exec_result/2 — manufactured failures (taint)" do
    test "sbx-missing 127 → non-retryable :sandbox_unavailable, NO taint" do
      assert {:error, err} =
               ForgeBridge.normalize_exec_result({:ok, {"sbx: command not found", 127}}, @inner)

      assert err.code == :sandbox_unavailable
      refute_retryable(err)
    end

    test "manufactured 124 with the exact inner-timeout message → taint + :sandbox_command_timeout" do
      assert {:taint, err} =
               ForgeBridge.normalize_exec_result(
                 {:ok, {"timeout after #{@inner}ms", 124}},
                 @inner
               )

      assert err.code == :sandbox_command_timeout
      refute_retryable(err)
    end

    test "manufactured 153 matching the anchored byte-count message → taint + :sandbox_output_limit" do
      assert {:taint, err} =
               ForgeBridge.normalize_exec_result(
                 {:ok, {"output limit exceeded after 1234 bytes", 153}},
                 @inner
               )

      assert err.code == :sandbox_output_limit
      refute_retryable(err)
    end
  end

  describe "normalize_exec_result/2 — trap pins: user commands that LOOK manufactured" do
    test "124 with a different timeout value is an ordinary result (no taint)" do
      # Wrong ms value — not the inner timeout the bridge passed.
      assert {:ok, %{output: "timeout after 999ms", exit_code: 124}} =
               ForgeBridge.normalize_exec_result({:ok, {"timeout after 999ms", 124}}, @inner)
    end

    test "153 with an UNanchored output-limit-looking message is ordinary (no taint)" do
      assert {:ok, %{output: "output limit exceeded after lots", exit_code: 153}} =
               ForgeBridge.normalize_exec_result(
                 {:ok, {"output limit exceeded after lots", 153}},
                 @inner
               )
    end

    test "a user command that genuinely exits 124 with its own output is ordinary" do
      assert {:ok, %{output: "job done", exit_code: 124}} =
               ForgeBridge.normalize_exec_result({:ok, {"job done", 124}}, @inner)
    end

    test "a user command that genuinely exits 127 with its own output is ordinary" do
      assert {:ok, %{output: "nope", exit_code: 127}} =
               ForgeBridge.normalize_exec_result({:ok, {"nope", 127}}, @inner)
    end

    test "a plain successful result passes through verbatim as a map" do
      assert {:ok, %{output: "hello\n", exit_code: 0}} =
               ForgeBridge.normalize_exec_result({:ok, {"hello\n", 0}}, @inner)
    end
  end

  describe "normalize_exec_result/2 — every error shape → non-retryable :sandbox_unavailable" do
    test "the distinct Forge/Harness error tuples all collapse to :sandbox_unavailable, no taint" do
      for term <- [
            :not_found,
            {:invalid_state, :starting},
            {:provision_failed, :boom},
            {:unknown_sandbox, :foo},
            {:some_other_error, 1}
          ] do
        assert {:error, err} = ForgeBridge.normalize_exec_result({:error, term}, @inner)
        assert err.code == :sandbox_unavailable
        refute_retryable(err)
      end
    end

    test "a non-integer code inside :ok is defensively unavailable" do
      assert {:error, %{code: :sandbox_unavailable}} =
               ForgeBridge.normalize_exec_result({:ok, {"x", :weird}}, @inner)
    end

    test "a non-tuple :ok payload is defensively unavailable" do
      assert {:error, %{code: :sandbox_unavailable}} =
               ForgeBridge.normalize_exec_result({:ok, "weird"}, @inner)
    end

    test "any other shape is defensively unavailable" do
      assert {:error, %{code: :sandbox_unavailable}} =
               ForgeBridge.normalize_exec_result(:garbage, @inner)
    end
  end

  describe "non-retryability through the real pipeline (details hygiene)" do
    test "every bridge error map is non-retryable after Tools.Error.normalize_result/1" do
      errs =
        [
          elem(ForgeBridge.normalize_exec_result({:error, :not_found}, @inner), 1),
          elem(
            ForgeBridge.normalize_exec_result({:ok, {"timeout after #{@inner}ms", 124}}, @inner),
            1
          ),
          elem(
            ForgeBridge.normalize_exec_result(
              {:ok, {"output limit exceeded after 9 bytes", 153}},
              @inner
            ),
            1
          ),
          elem(
            ForgeBridge.derive_inner_timeout(30_000, %{__jido_deadline_ms__: refuse_deadline()}),
            1
          )
        ]

      for err <- errs do
        refute_retryable(err)
        # The explicit non-retry hint is present and false — load-bearing for the
        # Jido.Exec layer (see ForgeBridge moduledoc "Non-retryability").
        assert err.details.retry == false
        # Details otherwise carry only neutral keys — no `:reason`/`:message` or a
        # truthy retry-* key an extractor could flip back to retryable.
        assert err.details
               |> Map.keys()
               |> Enum.all?(&(&1 in [:operation, :exit_status, :sandbox_status, :retry]))
      end
    end

    test "trap: a :timeout-coded error IS retryable (the assertion is meaningful)" do
      # A descriptive phrase message (not a bare atom-word) so the nested-reason
      # path doesn't override the :timeout default — the code alone makes it
      # retryable, which is exactly what the bridge AVOIDS by using :sandbox_*.
      retryable = %{code: :timeout, message: "the request timed out upstream", details: %{}}
      assert Jido.AI.Error.retryable?(Error.normalize_result({:error, retryable}))
    end

    test "trap: a stray :reason hint in details would re-enable retry (proves the hygiene requirement)" do
      poisoned = %{code: :sandbox_command_timeout, message: "x", details: %{reason: :timeout}}
      assert Jido.AI.Error.retryable?(Error.normalize_result({:error, poisoned}))
    end

    test "a top-level retryable? field is dropped by normalize (not relied upon)" do
      {:error, normalized} =
        Error.normalize_result(
          {:error, %{code: :sandbox_unavailable, message: "x", details: %{}, retryable?: false}}
        )

      refute Map.has_key?(normalized, :retryable?)
      refute Jido.AI.Error.retryable?({:error, normalized})
    end
  end

  describe "derive_inner_timeout/2" do
    test "with a comfortable deadline: inner = min(requested, budget), clamped under the budget" do
      ceiling = 30_000 - margin()
      deadline = System.monotonic_time(:millisecond) + 30_000

      assert {:ok, inner} =
               ForgeBridge.derive_inner_timeout(30_000, %{__jido_deadline_ms__: deadline})

      assert inner <= ceiling
      # The call is sub-millisecond, so the elapsed gap is tiny.
      assert inner >= ceiling - 1_000
    end

    test "a small EXPLICIT timeout under the budget is honored, never raised" do
      deadline = System.monotonic_time(:millisecond) + 30_000

      assert {:ok, 2_000} =
               ForgeBridge.derive_inner_timeout(2_000, %{__jido_deadline_ms__: deadline})
    end

    test "a budget below the minimum-viable threshold refuses to launch" do
      deadline = System.monotonic_time(:millisecond) + 3_000

      assert {:refuse, %{code: :sandbox_deadline_exceeded} = err} =
               ForgeBridge.derive_inner_timeout(30_000, %{__jido_deadline_ms__: deadline})

      refute_retryable(err)
    end

    test "no outer deadline falls back to the requested timeout unchanged" do
      assert {:ok, 7_500} = ForgeBridge.derive_inner_timeout(7_500, %{})
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp refute_retryable(err) do
    # Layer 1 — the ReAct runner's check (code-default + details dig).
    refute Jido.AI.Error.retryable?(Error.normalize_result({:error, err}))
    # Layer 2 — Jido.Exec's action-level retry, which defaults this error class
    # to retryable unless details carries retry: false (see ForgeBridge moduledoc).
    refute Jido.Action.Error.retryable?(err)
  end

  defp margin, do: Forge.exec_timeout_cushion_ms() + 500

  defp refuse_deadline, do: System.monotonic_time(:millisecond) + 3_000
end
