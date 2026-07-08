defmodule JidoClaw.Tools.VerifyCertificateTest do
  @moduledoc """
  Item 9 — the acceptance-criteria thread into `verify_certificate`: the
  run's criteria arrive ENGINE-side through `tool_context` (never an
  LLM-relayed argument) and are appended deterministically — AC ids
  included — to the certificate prompt's specification; absent criteria
  leave the prompt byte-identical.

  async: false — `Telemetry.with_outcome` writes reasoning_outcomes rows.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Tools.VerifyCertificate

  setup do
    :ok = Sandbox.checkout(JidoClaw.Repo)
    Application.put_env(:jido_claw, :verify_cert_test_pid, self())
    on_exit(fn -> Application.delete_env(:jido_claw, :verify_cert_test_pid) end)
    :ok
  end

  defmodule PromptCapturingRunner do
    @moduledoc false

    @certificate """
    Traced the change.

    ```certificate
    {
      "type": "patch_verification",
      "verdict": "PASS",
      "confidence": 0.9,
      "payload": {
        "test_claims": [],
        "comparison_outcome": [],
        "counterexample": null,
        "formal_conclusion": "ok"
      }
    }
    ```
    """

    @spec run(map(), map()) :: {:ok, map()}
    def run(%{prompt: prompt}, _context) do
      send(
        Application.fetch_env!(:jido_claw, :verify_cert_test_pid),
        {:cert_prompt, prompt}
      )

      {:ok, %{output: @certificate, usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  defp params do
    %{code: "def add(a, b), do: a + b", specification: "adds two numbers"}
  end

  test "tool_context criteria append to the specification with stable AC ids" do
    context = %{
      reasoning_runner: PromptCapturingRunner,
      tool_context: %{
        tenant_id: nil,
        acceptance_criteria: ["`mix test` passes", "GET /health returns 200"]
      }
    }

    assert {:ok, %{verdict: "PASS"}} = VerifyCertificate.run(params(), context)

    assert_receive {:cert_prompt, prompt}
    assert prompt =~ "adds two numbers"
    assert prompt =~ "Acceptance criteria (from run premises):"
    assert prompt =~ "AC1. `mix test` passes"
    assert prompt =~ "AC2. GET /health returns 200"
  end

  test "absent criteria leave the prompt byte-identical (no criteria block)" do
    context = %{reasoning_runner: PromptCapturingRunner, tool_context: %{tenant_id: nil}}

    assert {:ok, _result} = VerifyCertificate.run(params(), context)

    assert_receive {:cert_prompt, prompt}
    refute prompt =~ "Acceptance criteria"

    # Junk criteria (a durable-state hazard) degrade the same way.
    junk = %{reasoning_runner: PromptCapturingRunner, tool_context: %{acceptance_criteria: "x"}}
    assert {:ok, _result} = VerifyCertificate.run(params(), junk)

    assert_receive {:cert_prompt, junk_prompt}
    assert junk_prompt == prompt
  end
end
