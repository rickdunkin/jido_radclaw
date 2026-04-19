defmodule JidoClaw.Tools.VerifyCertificateTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.VerifyCertificate
  alias JidoClaw.Solutions.Store
  alias JidoClaw.Reasoning.{Certificates, Resources.Outcome}

  @ets_table :jido_claw_solutions

  # ---------------------------------------------------------------------------
  # Stub runner
  # ---------------------------------------------------------------------------

  defmodule StubRunner do
    @moduledoc false

    def run(_params, _context) do
      cert = %{
        "type" => "patch_verification",
        "verdict" => "PASS",
        "confidence" => 0.92,
        "payload" => %{
          "test_claims" => [%{"test" => "adds numbers", "path" => "add/2", "result" => "pass"}],
          "comparison_outcome" => [
            %{"requirement" => "addition", "matches" => true, "detail" => "correct"}
          ],
          "counterexample" => nil,
          "formal_conclusion" => "All tests pass."
        }
      }

      {:ok, %{output: "```certificate\n#{Jason.encode!(cert)}\n```"}}
    end
  end

  defmodule FailRunner do
    @moduledoc false

    def run(_params, _context) do
      {:error, "reasoning timeout"}
    end
  end

  defmodule NoCertificateRunner do
    @moduledoc false

    def run(_params, _context) do
      {:ok, %{output: "I analyzed the code and it looks fine."}}
    end
  end

  defmodule MapOutputRunner do
    @moduledoc false

    def run(_params, _context) do
      cert = %{
        "type" => "patch_verification",
        "verdict" => "PASS",
        "confidence" => 0.88,
        "payload" => %{
          "test_claims" => [],
          "comparison_outcome" => [],
          "counterexample" => nil,
          "formal_conclusion" => "Verified."
        }
      }

      {:ok, %{output: %{result: "```certificate\n#{Jason.encode!(cert)}\n```"}}}
    end
  end

  defmodule CodeReviewRunner do
    @moduledoc false

    def run(_params, _context) do
      cert = %{
        "type" => "code_review",
        "verdict" => "PASS",
        "confidence" => 0.85,
        "payload" => %{
          "invariants" => [%{"name" => "type safety", "trace" => "ok", "holds" => true}],
          "violations" => [],
          "edge_case_analysis" => []
        }
      }

      {:ok, %{output: "```certificate\n#{Jason.encode!(cert)}\n```"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  defp ensure_signal_bus do
    case Jido.Signal.Bus.start_link(name: JidoClaw.SignalBus) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    # VerifyCertificate.run/2 now writes a reasoning_outcomes row via telemetry,
    # so every test must own the sandbox checkout or rows leak across tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(JidoClaw.Repo)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_verify_cert_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    ensure_signal_bus()

    Supervisor.terminate_child(JidoClaw.Supervisor, Store)
    Supervisor.delete_child(JidoClaw.Supervisor, Store)

    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    start_supervised!({Store, project_dir: tmp_dir})

    on_exit(fn ->
      if :ets.whereis(@ets_table) != :undefined do
        :ets.delete_all_objects(@ets_table)
      end

      File.rm_rf!(tmp_dir)

      project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
      _ = Supervisor.start_child(JidoClaw.Supervisor, {Store, project_dir: project_dir})
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # Basic operation
  # ---------------------------------------------------------------------------

  describe "run/2 with stub runner" do
    test "returns certificate result with verdict and confidence" do
      params = %{
        code: "def add(a, b), do: a + b",
        specification: "Add two numbers"
      }

      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.verdict == "PASS"
      assert result.confidence == 0.92
      assert is_map(result.certificate)
      assert result.certificate["type"] == "patch_verification"
      assert result.trust_score == nil
      assert result.persistence_error == nil
    end

    test "defaults certificate_type to patch_verification" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.certificate["type"] == "patch_verification"
    end
  end

  # ---------------------------------------------------------------------------
  # Certificate type normalization
  # ---------------------------------------------------------------------------

  describe "certificate_type normalization" do
    test "accepts code_review type" do
      params = %{
        code: "defmodule Foo do end",
        specification: "A module",
        certificate_type: "code_review"
      }

      context = %{reasoning_runner: CodeReviewRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.certificate["type"] == "code_review"
    end

    test "rejects unknown certificate type" do
      params = %{
        code: "code",
        specification: "spec",
        certificate_type: "unknown_type"
      }

      context = %{reasoning_runner: StubRunner}

      assert {:error, msg} = VerifyCertificate.run(params, context)
      assert msg =~ "Unknown certificate type"
      assert msg =~ "unknown_type"
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence threading
  # ---------------------------------------------------------------------------

  describe "evidence threading" do
    test "evidence is passed into the template" do
      # We verify this indirectly — the template_for function interpolates evidence
      template =
        Certificates.template_for(:patch_verification, %{
          code: "code",
          specification: "spec",
          evidence: "mix compile: 0 warnings"
        })

      assert template =~ "mix compile: 0 warnings"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_output/1 handling
  # ---------------------------------------------------------------------------

  describe "extract_output handling" do
    test "handles map output with :result key" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: MapOutputRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.verdict == "PASS"
    end
  end

  # ---------------------------------------------------------------------------
  # Error propagation
  # ---------------------------------------------------------------------------

  describe "error propagation" do
    test "propagates reasoning runner failure" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: FailRunner}

      assert {:error, msg} = VerifyCertificate.run(params, context)
      assert msg =~ "Reasoning strategy failed"
    end

    test "propagates :no_certificate when output lacks certificate block" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: NoCertificateRunner}

      assert {:error, msg} = VerifyCertificate.run(params, context)
      assert msg =~ "did not contain a certificate block"
    end
  end

  # ---------------------------------------------------------------------------
  # Solution store integration
  # ---------------------------------------------------------------------------

  describe "solution store integration" do
    test "updates solution verification and trust_score when solution_id given" do
      {:ok, solution} =
        Store.store_solution(%{
          solution_content: "def add(a, b), do: a + b",
          language: "elixir"
        })

      params = %{
        code: "def add(a, b), do: a + b",
        specification: "Add two numbers",
        solution_id: solution.id
      }

      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert is_float(result.trust_score)
      assert result.trust_score > 0.0
      assert result.persistence_error == nil

      # Verify the solution was actually updated in the store
      assert {:ok, updated} = Store.find_by_id(solution.id)
      assert updated.verification["status"] == "semi_formal"
      assert updated.verification["confidence"] == 0.92
      assert updated.trust_score == result.trust_score
    end

    test "returns certificate with persistence_error when solution_id not found" do
      params = %{
        code: "code",
        specification: "spec",
        solution_id: "nonexistent-id-12345"
      }

      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.verdict == "PASS"
      assert result.confidence == 0.92
      assert result.trust_score == nil
      assert result.persistence_error =~ "not found"
    end

    test "returns certificate with persistence_error when store is not running" do
      stop_supervised!(Store)

      params = %{
        code: "code",
        specification: "spec",
        solution_id: "some-id"
      }

      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.verdict == "PASS"
      assert result.trust_score == nil
      assert result.persistence_error =~ "not running"
    end

    test "does not call store when solution_id is absent" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: StubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.trust_score == nil
      assert result.persistence_error == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Reasoning telemetry integration
  # ---------------------------------------------------------------------------

  defmodule UsageStubRunner do
    @moduledoc false

    def run(_params, _context) do
      cert = %{
        "type" => "patch_verification",
        "verdict" => "PASS",
        "confidence" => 0.77,
        "payload" => %{
          "test_claims" => [],
          "comparison_outcome" => [],
          "counterexample" => nil,
          "formal_conclusion" => "ok"
        }
      }

      {:ok,
       %{
         output: "```certificate\n#{Jason.encode!(cert)}\n```",
         usage: %{input_tokens: 150, output_tokens: 30, total_tokens: 180}
       }}
    end
  end

  defmodule NoCertWithUsageRunner do
    @moduledoc false

    def run(_params, _context) do
      {:ok,
       %{
         output: "no cert block here",
         usage: %{input_tokens: 42, output_tokens: 5}
       }}
    end
  end

  defmodule FailWithUsageRunner do
    @moduledoc false

    # Mirrors the map-shaped error payload Jido.AI.Actions.Reasoning.RunStrategy
    # returns on non-recoverable runner failure (run_strategy.ex:263-285).
    def run(_params, _context) do
      {:error,
       %{
         strategy: :cot,
         status: :failure,
         output: nil,
         usage: %{input_tokens: 77, output_tokens: 11},
         diagnostics: %{}
       }}
    end
  end

  describe "reasoning telemetry integration" do
    defp find_cert_row(verdict, confidence) do
      # The cert template prompt contains multiple task-keyword hits (verify,
      # debug-ish terms, etc.); scan all task_type buckets to locate the row.
      [:debugging, :verification, :qa, :planning, :refactoring, :exploration, :open_ended]
      |> Enum.flat_map(fn tt ->
        {:ok, rows} = Outcome.list_by_task_type(tt, :certificate_verification)
        rows
      end)
      |> Enum.find(fn r ->
        r.certificate_verdict == verdict and r.certificate_confidence == confidence
      end)
    end

    defp find_cert_row_by_tokens(tokens_in, tokens_out) do
      [:debugging, :verification, :qa, :planning, :refactoring, :exploration, :open_ended]
      |> Enum.flat_map(fn tt ->
        {:ok, rows} = Outcome.list_by_task_type(tt, :certificate_verification)
        rows
      end)
      |> Enum.find(fn r -> r.tokens_in == tokens_in and r.tokens_out == tokens_out end)
    end

    test "writes one reasoning_outcomes row per cert run with execution_kind=:certificate_verification" do
      params = %{code: "def add(a,b), do: a+b", specification: "Adds two numbers"}
      context = %{reasoning_runner: UsageStubRunner}

      assert {:ok, result} = VerifyCertificate.run(params, context)
      assert result.verdict == "PASS"

      row = find_cert_row("PASS", 0.77)
      assert row
      assert row.strategy == "cot"
      assert row.base_strategy == "cot"
      assert row.execution_kind == :certificate_verification
      assert row.tokens_in == 150
      assert row.tokens_out == 30
    end

    test "persists error-side token usage on parse failure" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: NoCertWithUsageRunner}

      assert {:error, msg} = VerifyCertificate.run(params, context)
      assert msg =~ "did not contain a certificate block"

      row = find_cert_row_by_tokens(42, 5)
      assert row
      assert row.status == :error
    end

    test "persists runner-error token usage on map-shaped runner failure" do
      params = %{code: "code", specification: "spec"}
      context = %{reasoning_runner: FailWithUsageRunner}

      assert {:error, msg} = VerifyCertificate.run(params, context)
      assert msg =~ "Reasoning strategy failed"

      row = find_cert_row_by_tokens(77, 11)
      assert row
      assert row.status == :error
      assert row.execution_kind == :certificate_verification
    end
  end
end
