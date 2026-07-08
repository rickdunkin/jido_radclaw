defmodule JidoClaw.Tools.VerifyCertificate do
  @moduledoc """
  Structured certificate verification tool.

  Wraps chain-of-thought reasoning with certificate templates to produce
  semi-formal verification certificates. Optionally persists the certificate
  to the solution store with recomputed trust scoring.
  """

  use JidoClaw.Tools.Action,
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

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.MapKeys
  alias JidoClaw.Reasoning.{Certificates, Output, Telemetry}
  alias JidoClaw.RouteComposer.Premises
  alias JidoClaw.Solutions.Solution

  @impl Jido.Action
  def run(params, context) do
    code = params.code
    specification = append_acceptance_criteria(params.specification, context)
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

      tool_context = Map.get(context, :tool_context, %{})
      tenant_id = Map.get(tool_context, :tenant_id)

      actor =
        if is_binary(tenant_id) do
          Map.get(tool_context, :actor) || Actor.system(tenant_id)
        else
          nil
        end

      {trust_score, persistence_error} =
        maybe_persist(solution_id, certificate, tenant_id, actor)

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
        valid = Enum.map_join(Certificates.types(), ", ", &Atom.to_string/1)
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

  # Item 9: the run's acceptance criteria arrive ENGINE-threaded through
  # ToolContext (`run_reactor/3` → `resolve_scope/2` → `ToolContext.build/1`),
  # never as an LLM-relayed argument — so the certificate judges the code
  # against the launch-established criteria, cited by their stable AC ids.
  # Absent/junk criteria leave the specification byte-identical.
  defp append_acceptance_criteria(specification, context) do
    tool_context = Map.get(context, :tool_context) || %{}
    criteria = %{"acceptance_criteria" => Map.get(tool_context, :acceptance_criteria)}

    case Premises.criteria_with_ids(criteria) do
      [] ->
        specification

      pairs ->
        block = Enum.map_join(pairs, "\n", fn {id, text} -> "#{id}. #{text}" end)
        specification <> "\n\nAcceptance criteria (from run premises):\n" <> block
    end
  end

  defp normalize_cert_type(type_str) do
    Certificates.normalize_type(type_str)
  end

  defp run_reasoning(prompt, context) do
    runner = Map.get(context, :reasoning_runner, Jido.AI.Actions.Reasoning.RunStrategy)
    tool_context = Map.get(context, :tool_context, %{}) || %{}
    workspace_id = Map.get(tool_context, :workspace_id)
    workspace_uuid = Map.get(tool_context, :workspace_uuid)
    session_uuid = Map.get(tool_context, :session_uuid)
    project_dir = Map.get(tool_context, :project_dir)
    agent_id = Map.get(tool_context, :agent_id)
    forge_session_key = Map.get(tool_context, :forge_session_key)
    # `request_id` is at the top-level context, not on tool_context.
    request_id = Map.get(context, :request_id)

    opts = [
      execution_kind: :certificate_verification,
      base_strategy: "cot",
      workspace_id: workspace_id,
      workspace_uuid: workspace_uuid,
      session_uuid: session_uuid,
      project_dir: project_dir,
      agent_id: agent_id,
      request_id: request_id,
      forge_session_key: forge_session_key
    ]

    run_params = %{
      strategy: :cot,
      prompt: prompt,
      timeout: 60_000
    }

    outcome =
      Telemetry.with_outcome("cot", prompt, opts, fn ->
        execute_cert(runner, run_params)
      end)

    case outcome do
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
        output_str = Output.extract_output(result)
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
            MapKeys.coalesce_field(reason, :usage, %{})
          else
            %{}
          end

        {:error, %{reason: "Reasoning strategy failed: #{inspect(reason)}", usage: usage}}
    end
  end

  defp maybe_persist(nil, _certificate, _tenant_id, _actor), do: {nil, nil}

  defp maybe_persist(_solution_id, _certificate, nil, _actor),
    do: {nil, "tenant_id required to persist"}

  defp maybe_persist(solution_id, certificate, tenant_id, actor) when is_binary(tenant_id) do
    verification_map = Map.merge(%{"status" => "semi_formal"}, certificate)

    with {:ok, solution} <- Solution.by_id(solution_id, tenant: tenant_id, actor: actor),
         {:ok, updated} <-
           Solution.update_verification_and_trust(solution, %{verification: verification_map},
             tenant: tenant_id,
             actor: actor
           ) do
      {updated.trust_score, nil}
    else
      {:error, %Ash.Error.Query.NotFound{}} ->
        {nil, "Solution '#{solution_id}' not found"}

      {:error, reason} ->
        {nil, "Failed to persist verification: #{inspect(reason)}"}
    end
  end
end
