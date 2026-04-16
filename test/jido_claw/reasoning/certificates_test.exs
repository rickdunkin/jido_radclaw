defmodule JidoClaw.Reasoning.CertificatesTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Reasoning.Certificates

  # ---------------------------------------------------------------------------
  # types/0
  # ---------------------------------------------------------------------------

  describe "types/0" do
    test "returns all four certificate types" do
      types = Certificates.types()

      assert :patch_verification in types
      assert :code_review in types
      assert :fault_localization in types
      assert :code_qa in types
      assert length(types) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_type/1
  # ---------------------------------------------------------------------------

  describe "normalize_type/1" do
    test "normalizes known string types" do
      assert {:ok, :patch_verification} = Certificates.normalize_type("patch_verification")
      assert {:ok, :code_review} = Certificates.normalize_type("code_review")
      assert {:ok, :fault_localization} = Certificates.normalize_type("fault_localization")
      assert {:ok, :code_qa} = Certificates.normalize_type("code_qa")
    end

    test "accepts known atom types" do
      assert {:ok, :patch_verification} = Certificates.normalize_type(:patch_verification)
      assert {:ok, :code_review} = Certificates.normalize_type(:code_review)
    end

    test "rejects unknown string type" do
      assert {:error, :unknown_type} = Certificates.normalize_type("unknown")
    end

    test "rejects unknown atom type" do
      assert {:error, :unknown_type} = Certificates.normalize_type(:unknown)
    end

    test "rejects non-string, non-atom input" do
      assert {:error, :unknown_type} = Certificates.normalize_type(42)
      assert {:error, :unknown_type} = Certificates.normalize_type(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # template_for/2
  # ---------------------------------------------------------------------------

  describe "template_for/2" do
    test "patch_verification returns string with type-specific sections" do
      template =
        Certificates.template_for(:patch_verification, %{
          code: "def add(a, b), do: a + b",
          specification: "Add two numbers"
        })

      assert is_binary(template)
      assert template =~ "Test Claims"
      assert template =~ "Comparison Outcome"
      assert template =~ "Counterexample or Proof"
      assert template =~ "Formal Conclusion"
      assert template =~ "patch_verification"
      assert template =~ "def add(a, b), do: a + b"
      assert template =~ "Add two numbers"
    end

    test "code_review returns string with invariant sections" do
      template =
        Certificates.template_for(:code_review, %{
          code: "defmodule Foo do end",
          specification: "A module"
        })

      assert is_binary(template)
      assert template =~ "Invariant List"
      assert template =~ "Violation List"
      assert template =~ "Edge Case Analysis"
      assert template =~ "code_review"
    end

    test "fault_localization returns string with localization sections" do
      template =
        Certificates.template_for(:fault_localization, %{
          code: "defmodule Broken do end",
          specification: "Should work"
        })

      assert is_binary(template)
      assert template =~ "Premises"
      assert template =~ "Code Path Traces"
      assert template =~ "Divergence Claims"
      assert template =~ "Ranked Predictions"
      assert template =~ "fault_localization"
    end

    test "code_qa returns string with QA sections" do
      template =
        Certificates.template_for(:code_qa, %{
          code: "defmodule Quality do end",
          specification: "Quality check"
        })

      assert is_binary(template)
      assert template =~ "Function Trace Table"
      assert template =~ "Data Flow Analysis"
      assert template =~ "Semantic Properties"
      assert template =~ "Alternative Hypothesis"
      assert template =~ "code_qa"
    end

    test "evidence is interpolated when provided" do
      template =
        Certificates.template_for(:patch_verification, %{
          code: "code",
          specification: "spec",
          evidence: "mix compile passed with 0 warnings"
        })

      assert template =~ "Gathered Evidence"
      assert template =~ "mix compile passed with 0 warnings"
    end

    test "evidence section is omitted when empty" do
      template =
        Certificates.template_for(:patch_verification, %{
          code: "code",
          specification: "spec",
          evidence: ""
        })

      refute template =~ "Gathered Evidence"
    end

    test "evidence section is omitted when nil" do
      template =
        Certificates.template_for(:patch_verification, %{
          code: "code",
          specification: "spec"
        })

      refute template =~ "Gathered Evidence"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_certificate/1
  # ---------------------------------------------------------------------------

  describe "parse_certificate/1" do
    test "extracts valid fenced JSON with all string keys" do
      text = """
      Some preamble text.

      ```certificate
      {
        "type": "patch_verification",
        "verdict": "PASS",
        "confidence": 0.92,
        "payload": {
          "test_claims": [{"test": "adds numbers", "path": "add/2", "result": "pass"}],
          "comparison_outcome": [{"requirement": "addition", "matches": true, "detail": "correct"}],
          "counterexample": null,
          "formal_conclusion": "All tests pass. The implementation is correct."
        }
      }
      ```

      Some trailing text.
      """

      assert {:ok, cert} = Certificates.parse_certificate(text)
      assert cert["type"] == "patch_verification"
      assert cert["verdict"] == "PASS"
      assert cert["confidence"] == 0.92
      assert is_map(cert["payload"])
      assert is_list(cert["payload"]["test_claims"])
    end

    test "returns :no_certificate when no fenced block" do
      assert {:error, :no_certificate} = Certificates.parse_certificate("no certificate here")
    end

    test "returns :no_certificate for non-string input" do
      assert {:error, :no_certificate} = Certificates.parse_certificate(nil)
      assert {:error, :no_certificate} = Certificates.parse_certificate(42)
    end

    test "returns :invalid_json when block contains bad JSON" do
      text = """
      ```certificate
      {not valid json}
      ```
      """

      assert {:error, :invalid_json} = Certificates.parse_certificate(text)
    end

    test "returns :invalid_shape when type is unknown" do
      text = """
      ```certificate
      {
        "type": "unknown_type",
        "verdict": "PASS",
        "confidence": 0.9,
        "payload": {}
      }
      ```
      """

      assert {:error, :invalid_shape} = Certificates.parse_certificate(text)
    end

    test "returns :invalid_shape when verdict is missing" do
      text = """
      ```certificate
      {
        "type": "patch_verification",
        "confidence": 0.9,
        "payload": {
          "test_claims": [],
          "comparison_outcome": [],
          "counterexample": null,
          "formal_conclusion": "done"
        }
      }
      ```
      """

      assert {:error, :invalid_shape} = Certificates.parse_certificate(text)
    end

    test "returns :invalid_shape when confidence is out of range" do
      text = """
      ```certificate
      {
        "type": "patch_verification",
        "verdict": "PASS",
        "confidence": 1.5,
        "payload": {
          "test_claims": [],
          "comparison_outcome": [],
          "counterexample": null,
          "formal_conclusion": "done"
        }
      }
      ```
      """

      assert {:error, :invalid_shape} = Certificates.parse_certificate(text)
    end

    test "returns :invalid_shape when confidence is negative" do
      text = """
      ```certificate
      {
        "type": "patch_verification",
        "verdict": "PASS",
        "confidence": -0.1,
        "payload": {
          "test_claims": [],
          "comparison_outcome": [],
          "counterexample": null,
          "formal_conclusion": "done"
        }
      }
      ```
      """

      assert {:error, :invalid_shape} = Certificates.parse_certificate(text)
    end

    test "returns :invalid_shape when required payload keys are missing" do
      text = """
      ```certificate
      {
        "type": "patch_verification",
        "verdict": "PASS",
        "confidence": 0.9,
        "payload": {
          "test_claims": []
        }
      }
      ```
      """

      assert {:error, :invalid_shape} = Certificates.parse_certificate(text)
    end

    test "validates code_review payload keys" do
      text = """
      ```certificate
      {
        "type": "code_review",
        "verdict": "PASS",
        "confidence": 0.85,
        "payload": {
          "invariants": [{"name": "type safety", "trace": "checked", "holds": true}],
          "violations": [],
          "edge_case_analysis": [{"case": "nil input", "expected": "error", "actual": "error", "risk": "low"}]
        }
      }
      ```
      """

      assert {:ok, cert} = Certificates.parse_certificate(text)
      assert cert["type"] == "code_review"
    end

    test "validates fault_localization payload keys" do
      text = """
      ```certificate
      {
        "type": "fault_localization",
        "verdict": "LOCALIZED",
        "confidence": 0.78,
        "payload": {
          "premises": [{"test": "test_add", "semantics": "verifies addition"}],
          "code_path_traces": [{"method": "add/2", "location": "lib/math.ex:5", "params": "integer, integer", "returns": "integer", "behavior": "correct"}],
          "divergence_claims": [{"premise_ref": "test_add", "trace_ref": "add/2", "divergence": "none"}],
          "ranked_predictions": [{"rank": 1, "location": "lib/math.ex:5", "method": "add/2", "supporting_claims": ["test_add"], "confidence": 0.78}]
        }
      }
      ```
      """

      assert {:ok, cert} = Certificates.parse_certificate(text)
      assert cert["type"] == "fault_localization"
    end

    test "validates code_qa payload keys" do
      text = """
      ```certificate
      {
        "type": "code_qa",
        "verdict": "PASS",
        "confidence": 0.95,
        "payload": {
          "function_traces": [{"function": "add/2", "location": "lib/math.ex:5", "params": "integer, integer", "returns": "integer", "verified_behavior": "adds two numbers"}],
          "data_flow_analysis": [{"variable": "result", "created_at": "line 5", "transforms": ["addition"], "consumed_at": "line 6"}],
          "semantic_properties": [{"property": "commutativity", "holds": true, "evidence": "add(a,b) == add(b,a)"}],
          "alternative_hypotheses": [{"hypothesis": "subtraction", "plausible": false, "reasoning": "clearly addition"}]
        }
      }
      ```
      """

      assert {:ok, cert} = Certificates.parse_certificate(text)
      assert cert["type"] == "code_qa"
    end

    test "accepts confidence of exactly 0.0" do
      text = make_certificate(%{"confidence" => 0.0})
      assert {:ok, _} = Certificates.parse_certificate(text)
    end

    test "accepts confidence of exactly 1.0" do
      text = make_certificate(%{"confidence" => 1.0})
      assert {:ok, _} = Certificates.parse_certificate(text)
    end
  end

  # ---------------------------------------------------------------------------
  # valid?/1
  # ---------------------------------------------------------------------------

  describe "valid?/1" do
    test "returns true for valid certificate map" do
      cert = %{
        "type" => "patch_verification",
        "verdict" => "PASS",
        "confidence" => 0.9,
        "payload" => %{
          "test_claims" => [],
          "comparison_outcome" => [],
          "counterexample" => nil,
          "formal_conclusion" => "done"
        }
      }

      assert Certificates.valid?(cert)
    end

    test "returns false for invalid certificate" do
      refute Certificates.valid?(%{"type" => "unknown"})
    end

    test "returns false for non-map" do
      refute Certificates.valid?("not a map")
      refute Certificates.valid?(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_certificate(overrides) do
    base = %{
      "type" => "patch_verification",
      "verdict" => "PASS",
      "confidence" => 0.9,
      "payload" => %{
        "test_claims" => [],
        "comparison_outcome" => [],
        "counterexample" => nil,
        "formal_conclusion" => "done"
      }
    }

    cert = Map.merge(base, overrides)

    """
    ```certificate
    #{Jason.encode!(cert)}
    ```
    """
  end
end
