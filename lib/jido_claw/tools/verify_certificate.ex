defmodule JidoClaw.Tools.VerifyCertificate do
  @moduledoc """
  Structured certificate verification tool.

  Wraps chain-of-thought reasoning with certificate templates to produce
  semi-formal verification certificates. Optionally persists the certificate
  to the solution store with recomputed trust scoring.
  """

  use Jido.Action,
    name: "verify_certificate",
    description:
      "Verify code using semi-formal reasoning certificates. Produces structured verdicts with confidence scores. Optionally updates a stored solution's verification and trust score.",
    category: "reasoning",
    tags: ["reasoning", "verification", "certificate"],
    output_schema: [
      verdict: [type: :string, required: true],
      confidence: [type: :float, required: true],
      certificate: [type: :map, required: true],
      trust_score: [type: {:or, [:float, nil]}],
      persistence_error: [type: {:or, [:string, nil]}]
    ],
    schema: [
      code: [
        type: :string,
        required: true,
        doc: "The code or patch to verify"
      ],
      specification: [
        type: :string,
        required: true,
        doc: "What the code should do"
      ],
      evidence: [
        type: :string,
        required: false,
        doc:
          "Gathered analysis from prior exploration (ReadFile/SearchCode/GitDiff output). Interpolated into the certificate template."
      ],
      certificate_type: [
        type: :string,
        required: false,
        default: "patch_verification",
        doc: "Certificate type: patch_verification, code_review, fault_localization, code_qa"
      ],
      solution_id: [
        type: :string,
        required: false,
        doc:
          "Optional solution ID. When provided, updates the solution's verification and trust score."
      ]
    ]

  alias JidoClaw.Reasoning.{Certificates, Telemetry}
  alias JidoClaw.Solutions.Store

  @impl true
  def run(params, context) do
    code = params.code
    specification = params.specification
    evidence = Map.get(params, :evidence, "")
    cert_type_str = Map.get(params, :certificate_type, "patch_verification")
    solution_id = Map.get(params, :solution_id)

    with {:ok, cert_type} <- normalize_cert_type(cert_type_str),
         prompt <-
           Certificates.template_for(cert_type, %{
             code: code,
             specification: specification,
             evidence: evidence
           }),
         {:ok, %{certificate: certificate}} <- run_reasoning(prompt, context) do
      verdict = Map.get(certificate, "verdict", "UNKNOWN")
      confidence = Map.get(certificate, "confidence", 0.0)

      {trust_score, persistence_error} = maybe_persist(solution_id, certificate)

      {:ok,
       %{
         verdict: verdict,
         confidence: confidence,
         certificate: certificate,
         trust_score: trust_score,
         persistence_error: persistence_error
       }}
    else
      {:error, :unknown_type} ->
        valid = Certificates.types() |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
        {:error, "Unknown certificate type '#{cert_type_str}'. Valid types: #{valid}"}

      {:error, :no_certificate} ->
        {:error,
         "Reasoning output did not contain a certificate block. The LLM did not produce a ```certificate``` fenced JSON block."}

      {:error, :invalid_json} ->
        {:error, "Certificate block contained invalid JSON."}

      {:error, :invalid_shape} ->
        {:error, "Certificate JSON is missing required fields or has invalid values."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Certificate verification failed: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp normalize_cert_type(type_str) do
    Certificates.normalize_type(type_str)
  end

  defp run_reasoning(prompt, context) do
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)
    tool_context = Map.get(context, :tool_context, %{}) || %{}
    workspace_id = Map.get(tool_context, :workspace_id)
    project_dir = Map.get(tool_context, :project_dir)
    agent_id = Map.get(tool_context, :agent_id)
    forge_session_key = Map.get(tool_context, :forge_session_key)

    opts = [
      execution_kind: :certificate_verification,
      base_strategy: "cot",
      workspace_id: workspace_id,
      project_dir: project_dir,
      agent_id: agent_id,
      forge_session_key: forge_session_key
    ]

    run_params = %{
      strategy: :cot,
      prompt: prompt,
      timeout: 60_000
    }

    Telemetry.with_outcome("cot", prompt, opts, fn ->
      execute_cert(runner, run_params)
    end)
    |> case do
      {:ok, %{certificate: _} = payload} ->
        {:ok, payload}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns {:ok, %{output, certificate, certificate_verdict, certificate_confidence, usage}}
  # or {:error, %{reason, usage}} so Telemetry.with_outcome can capture tokens on
  # both success and parse-failure paths.
  defp execute_cert(runner, run_params) do
    case runner.run(run_params, %{}) do
      {:ok, result} ->
        output_str = extract_output(result)
        usage = Map.get(result, :usage, %{})

        case Certificates.parse_certificate(output_str) do
          {:ok, certificate} ->
            {:ok,
             %{
               output: output_str,
               certificate: certificate,
               certificate_verdict: Map.get(certificate, "verdict"),
               certificate_confidence: Map.get(certificate, "confidence"),
               usage: usage
             }}

          {:error, reason} ->
            {:error, %{reason: reason, usage: usage}}
        end

      {:error, reason} ->
        usage =
          if is_map(reason) do
            Map.get(reason, :usage) || Map.get(reason, "usage") || %{}
          else
            %{}
          end

        {:error, %{reason: "Reasoning strategy failed: #{inspect(reason)}", usage: usage}}
    end
  end

  defp extract_output(%{output: output}) when is_binary(output) and output != "", do: output

  defp extract_output(%{output: output}) when is_map(output) do
    cond do
      Map.has_key?(output, :result) -> output.result
      Map.has_key?(output, :answer) -> output.answer
      Map.has_key?(output, :conclusion) -> output.conclusion
      true -> inspect(output)
    end
  end

  defp extract_output(%{output: output}), do: inspect(output)
  defp extract_output(result), do: inspect(result)

  defp maybe_persist(nil, _certificate), do: {nil, nil}

  defp maybe_persist(solution_id, certificate) do
    verification_map = Map.merge(%{"status" => "semi_formal"}, certificate)

    case Store.update_verification_and_trust(solution_id, verification_map) do
      {:ok, updated} ->
        {updated.trust_score, nil}

      :not_found ->
        {nil, "Solution '#{solution_id}' not found"}

      {:error, :not_running} ->
        {nil, "Solution store is not running"}
    end
  end
end
