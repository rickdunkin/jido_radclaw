defmodule JidoClaw.Reasoning.Certificates do
  @moduledoc """
  Pure-functional module for certificate-based semi-formal reasoning.

  Provides structured certificate templates that guide LLM agents through
  rigorous verification with explicit premises, execution traces, and formal
  conclusions. Based on the "Agentic Code Reasoning" approach where structured
  templates improve accuracy on code verification tasks.

  Certificate types:
    - `:patch_verification` — verify that a code patch is correct
    - `:code_review` — review code for invariant violations
    - `:fault_localization` — locate the root cause of a failing test
    - `:code_qa` — comprehensive code quality analysis
  """

  @type_map %{
    "patch_verification" => :patch_verification,
    "code_review" => :code_review,
    "fault_localization" => :fault_localization,
    "code_qa" => :code_qa
  }

  @required_payload_keys %{
    patch_verification: [
      "test_claims",
      "comparison_outcome",
      "counterexample",
      "formal_conclusion"
    ],
    code_review: ["invariants", "violations", "edge_case_analysis"],
    fault_localization: [
      "premises",
      "code_path_traces",
      "divergence_claims",
      "ranked_predictions"
    ],
    code_qa: [
      "function_traces",
      "data_flow_analysis",
      "semantic_properties",
      "alternative_hypotheses"
    ]
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of supported certificate type atoms.
  """
  @spec types() :: [atom()]
  def types, do: Map.values(@type_map)

  @doc """
  Normalize a string certificate type to its atom equivalent.

  Returns `{:ok, atom}` for known types, `{:error, :unknown_type}` otherwise.
  Never uses `String.to_atom/1`.
  """
  @spec normalize_type(String.t()) :: {:ok, atom()} | {:error, :unknown_type}
  def normalize_type(type) when is_binary(type) do
    case Map.fetch(@type_map, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_type}
    end
  end

  def normalize_type(type) when is_atom(type) do
    if type in Map.values(@type_map), do: {:ok, type}, else: {:error, :unknown_type}
  end

  def normalize_type(_), do: {:error, :unknown_type}

  @doc """
  Build a certificate template prompt for the given type and context.

  Context map accepts:
    - `:code` — the code or patch to verify (required)
    - `:specification` — what the code should do (required)
    - `:evidence` — gathered analysis from prior exploration (optional)

  Returns a prompt string that instructs the LLM to produce a fenced
  certificate JSON block.
  """
  @spec template_for(atom(), map()) :: String.t()
  def template_for(:patch_verification, context) do
    code = Map.get(context, :code, "")
    specification = Map.get(context, :specification, "")
    evidence = Map.get(context, :evidence, "")

    """
    You are a formal verification agent. Analyze the following code patch and produce a structured certificate.

    ## Specification
    #{specification}

    ## Code Under Review
    ```
    #{code}
    ```

    #{evidence_section(evidence)}

    ## Instructions

    Produce a certificate by following these steps exactly:

    1. **Test Claims**: For each test or requirement in the specification, trace the execution path through the code. State whether each test passes or fails, with the specific code path taken.

    2. **Comparison Outcome**: Compare the actual behavior against the specification for each requirement. Note any discrepancies.

    3. **Counterexample or Proof**: If any test fails, provide a concrete counterexample (specific input that produces wrong output). If all tests pass, state why the implementation satisfies the specification.

    4. **Formal Conclusion**: Reference your test claims and comparison outcomes to state a verdict.

    Output your certificate as a fenced JSON block:

    ```certificate
    {
      "type": "patch_verification",
      "verdict": "PASS",
      "confidence": 0.92,
      "payload": {
        "test_claims": [{"test": "description of test", "path": "code path taken", "result": "pass"}],
        "comparison_outcome": [{"requirement": "requirement description", "matches": true, "detail": "explanation"}],
        "counterexample": null,
        "formal_conclusion": "Your formal conclusion referencing the above evidence"
      }
    }
    ```

    Use "PASS" or "FAIL" for the verdict. Set confidence between 0.0 and 1.0. Set counterexample to null when all tests pass, or to a specific failing input string when a test fails.
    """
  end

  def template_for(:code_review, context) do
    code = Map.get(context, :code, "")
    specification = Map.get(context, :specification, "")
    evidence = Map.get(context, :evidence, "")

    """
    You are a formal code review agent. Analyze the following code and produce a structured review certificate.

    ## What the Code Should Do
    #{specification}

    ## Code Under Review
    ```
    #{code}
    ```

    #{evidence_section(evidence)}

    ## Instructions

    Produce a certificate by following these steps exactly:

    1. **Invariant List**: Identify all invariants the code must preserve (type contracts, state constraints, concurrency guarantees, error handling contracts).

    2. **Per-Invariant Trace**: For each invariant, trace through the code with boundary inputs (empty collections, nil values, max values, concurrent access). State whether the invariant holds.

    3. **Violation List**: Document any invariant violations with severity (critical/high/medium/low) and confidence (0.0-1.0).

    4. **Edge Case Analysis**: Identify edge cases not covered by the invariant traces. For each, state the expected vs actual behavior.

    Output your certificate as a fenced JSON block:

    ```certificate
    {
      "type": "code_review",
      "verdict": "PASS",
      "confidence": 0.85,
      "payload": {
        "invariants": [{"name": "invariant description", "trace": "boundary input trace", "holds": true}],
        "violations": [{"invariant": "invariant name", "severity": "medium", "confidence": 0.8, "detail": "explanation"}],
        "edge_case_analysis": [{"case": "edge case description", "expected": "expected behavior", "actual": "actual behavior", "risk": "low"}]
      }
    }
    ```

    Use "PASS" or "FAIL" for the verdict. Set confidence between 0.0 and 1.0. Use true or false for "holds". Use "critical", "high", "medium", or "low" for severity and risk.
    """
  end

  def template_for(:fault_localization, context) do
    code = Map.get(context, :code, "")
    specification = Map.get(context, :specification, "")
    evidence = Map.get(context, :evidence, "")

    """
    You are a fault localization agent. Analyze the failing code and produce a structured localization certificate.

    ## Expected Behavior
    #{specification}

    ## Code Under Investigation
    ```
    #{code}
    ```

    #{evidence_section(evidence)}

    ## Instructions

    Produce a certificate by following these steps exactly:

    1. **Premises**: State the semantic meaning of each relevant test. What behavior does each test verify?

    2. **Code Path Traces**: For each method in the execution path, document the file:line, parameter types, return type, and observed behavior. Trace the full call chain.

    3. **Divergence Claims**: Identify where the actual execution diverges from expected behavior. Each claim must reference a specific premise and a specific code path trace.

    4. **Ranked Predictions**: Rank the most likely fault locations. Each prediction must reference supporting divergence claims.

    Output your certificate as a fenced JSON block:

    ```certificate
    {
      "type": "fault_localization",
      "verdict": "LOCALIZED",
      "confidence": 0.78,
      "payload": {
        "premises": [{"test": "test_name", "semantics": "what this test verifies"}],
        "code_path_traces": [{"method": "function_name", "location": "lib/module.ex:42", "params": "integer, string", "returns": "tuple", "behavior": "observed behavior"}],
        "divergence_claims": [{"premise_ref": "test_name", "trace_ref": "function_name", "divergence": "description of divergence"}],
        "ranked_predictions": [{"rank": 1, "location": "lib/module.ex:42", "method": "function_name", "supporting_claims": ["test_name"], "confidence": 0.78}]
      }
    }
    ```

    Use "LOCALIZED" or "INCONCLUSIVE" for the verdict. Set confidence between 0.0 and 1.0.
    """
  end

  def template_for(:code_qa, context) do
    code = Map.get(context, :code, "")
    specification = Map.get(context, :specification, "")
    evidence = Map.get(context, :evidence, "")

    """
    You are a code quality analysis agent. Analyze the following code and produce a structured QA certificate.

    ## Context
    #{specification}

    ## Code Under Analysis
    ```
    #{code}
    ```

    #{evidence_section(evidence)}

    ## Instructions

    Produce a certificate by following these steps exactly:

    1. **Function Trace Table**: For each function, document: function name, file:line, parameter types, return type, and verified behavior.

    2. **Data Flow Analysis**: Trace the lifecycle of key variables through the code. Document where data is created, transformed, and consumed.

    3. **Semantic Properties**: Identify semantic properties the code should satisfy (idempotency, commutativity, monotonicity, etc.). For each, provide evidence of whether it holds.

    4. **Alternative Hypothesis Check**: Consider alternative interpretations of the specification. Could the code be correct under a different reading? Document your reasoning.

    Output your certificate as a fenced JSON block:

    ```certificate
    {
      "type": "code_qa",
      "verdict": "PASS",
      "confidence": 0.90,
      "payload": {
        "function_traces": [{"function": "function_name", "location": "lib/module.ex:10", "params": "string, integer", "returns": "map", "verified_behavior": "description of verified behavior"}],
        "data_flow_analysis": [{"variable": "variable_name", "created_at": "lib/module.ex:10", "transforms": ["transformation description"], "consumed_at": "lib/module.ex:25"}],
        "semantic_properties": [{"property": "idempotency", "holds": true, "evidence": "evidence description"}],
        "alternative_hypotheses": [{"hypothesis": "alternative interpretation", "plausible": false, "reasoning": "reasoning explanation"}]
      }
    }
    ```

    Use "PASS", "FAIL", or "INCONCLUSIVE" for the verdict. Set confidence between 0.0 and 1.0. Use true or false for "holds" and "plausible".
    """
  end

  @doc """
  Parse a certificate from LLM output text.

  Extracts the fenced JSON block between ` ```certificate ` and ` ``` `,
  decodes via Jason, and validates the shape.

  Returns:
    - `{:ok, map}` with all string keys on success
    - `{:error, :no_certificate}` when no fenced block found
    - `{:error, :invalid_json}` when block found but JSON is malformed
    - `{:error, :invalid_shape}` when JSON is valid but missing required keys
  """
  @spec parse_certificate(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_certificate(text) when is_binary(text) do
    with {:ok, json_str} <- extract_fenced_block(text),
         {:ok, decoded} <- decode_json(json_str),
         :ok <- validate_shape(decoded) do
      {:ok, decoded}
    end
  end

  def parse_certificate(_), do: {:error, :no_certificate}

  @doc """
  Check if a parsed certificate map is structurally valid.
  """
  @spec valid?(map()) :: boolean()
  def valid?(cert) when is_map(cert) do
    validate_shape(cert) == :ok
  end

  def valid?(_), do: false

  # ---------------------------------------------------------------------------
  # Private — template helpers
  # ---------------------------------------------------------------------------

  defp evidence_section(""), do: ""
  defp evidence_section(nil), do: ""

  defp evidence_section(evidence) do
    """
    ## Gathered Evidence
    #{evidence}
    """
  end

  # ---------------------------------------------------------------------------
  # Private — parsing
  # ---------------------------------------------------------------------------

  defp extract_fenced_block(text) do
    case Regex.run(~r/```certificate\s*\n([\s\S]*?)\n\s*```/, text) do
      [_, json_str] -> {:ok, String.trim(json_str)}
      _ -> {:error, :no_certificate}
    end
  end

  defp decode_json(json_str) do
    case Jason.decode(json_str) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, :invalid_shape}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate_shape(decoded) do
    with :ok <- validate_type(decoded),
         :ok <- validate_verdict(decoded),
         :ok <- validate_confidence(decoded),
         :ok <- validate_payload(decoded) do
      :ok
    end
  end

  defp validate_type(%{"type" => type}) when is_binary(type) do
    if Map.has_key?(@type_map, type), do: :ok, else: {:error, :invalid_shape}
  end

  defp validate_type(_), do: {:error, :invalid_shape}

  defp validate_verdict(%{"verdict" => v}) when is_binary(v) and v != "", do: :ok
  defp validate_verdict(_), do: {:error, :invalid_shape}

  defp validate_confidence(%{"confidence" => c})
       when is_number(c) and c >= 0.0 and c <= 1.0,
       do: :ok

  defp validate_confidence(_), do: {:error, :invalid_shape}

  defp validate_payload(%{"type" => type, "payload" => payload}) when is_map(payload) do
    {:ok, type_atom} = normalize_type(type)
    required_keys = Map.fetch!(@required_payload_keys, type_atom)

    if Enum.all?(required_keys, &Map.has_key?(payload, &1)) do
      :ok
    else
      {:error, :invalid_shape}
    end
  end

  defp validate_payload(_), do: {:error, :invalid_shape}
end
