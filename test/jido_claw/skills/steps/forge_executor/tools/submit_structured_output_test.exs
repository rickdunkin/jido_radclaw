defmodule JidoClaw.Skills.Steps.ForgeExecutor.Tools.SubmitStructuredOutputTest do
  @moduledoc """
  Executor-seam PR-2: the deposit MCP tool's ref resolution + isError contract
  (a `{:error, binary}` reply is what jido_mcp maps to an `isError` tool
  result the vendor CLI reads and retries on).
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Skills.Steps.ForgeExecutor.Deposit
  alias JidoClaw.Skills.Steps.ForgeExecutor.Tools.SubmitStructuredOutput

  @coder_output Keyword.get(JidoClaw.Agent.Workers.Coder.strategy_opts(), :output)

  defp start_box! do
    ref = Ecto.UUID.generate()
    {:ok, _pid} = Deposit.start_link(ref: ref, output: @coder_output)
    ref
  end

  defp valid_payload do
    %{
      "summary" => "tool-deposited",
      "status" => "completed",
      "files_changed" => [],
      "notes" => "n/a",
      "artifacts" => %{}
    }
  end

  test "resolves the box through atom-keyed assigns (the ScopedForward stamp)" do
    ref = start_box!()

    assert {:ok, %{status: :accepted}} =
             SubmitStructuredOutput.run(
               %{output: valid_payload()},
               %{assigns: %{executor_deposit_ref: ref}}
             )

    assert %{summary: "tool-deposited"} = Deposit.take(ref)
  end

  test "resolves the box through string-keyed assigns (jido_mcp context marshalling)" do
    ref = start_box!()

    assert {:ok, %{status: :accepted}} =
             SubmitStructuredOutput.run(
               %{output: valid_payload()},
               %{assigns: %{"executor_deposit_ref" => ref}}
             )

    assert %{summary: "tool-deposited"} = Deposit.take(ref)
  end

  test "no ref on the connection is a clean {:error, _} (isError contract)" do
    assert {:error, msg} = SubmitStructuredOutput.run(%{output: valid_payload()}, %{assigns: %{}})
    assert msg =~ "no active deposit ref"

    assert {:error, _} = SubmitStructuredOutput.run(%{output: valid_payload()}, %{})
  end

  test "an unknown ref is a clean {:error, _}" do
    assert {:error, msg} =
             SubmitStructuredOutput.run(
               %{output: valid_payload()},
               %{assigns: %{executor_deposit_ref: Ecto.UUID.generate()}}
             )

    assert msg =~ "no active deposit"
  end

  test "an invalid payload is a clean {:error, _} carrying the bounded schema reason" do
    ref = start_box!()

    assert {:error, msg} =
             SubmitStructuredOutput.run(
               %{output: %{"summary" => "drifted"}},
               %{assigns: %{executor_deposit_ref: ref}}
             )

    assert msg =~ "output failed schema validation"
    assert Deposit.take(ref) == nil
  end
end
