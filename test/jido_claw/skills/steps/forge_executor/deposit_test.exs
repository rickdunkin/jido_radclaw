defmodule JidoClaw.Skills.Steps.ForgeExecutor.DepositTest do
  @moduledoc """
  Executor-seam PR-2: the per-step deposit box. Unit-level — boxes are started
  directly against the app-wide `DepositRegistry` under fresh UUID refs, with
  the real Coder output contract (`strategy_opts()[:output]`, a compile-time-
  normalized `%Jido.AI.Output{}`) as the validation schema.
  """

  use ExUnit.Case, async: true

  alias JidoClaw.Skills.Steps.ForgeExecutor.Deposit

  @coder_output Keyword.get(JidoClaw.Agent.Workers.Coder.strategy_opts(), :output)

  defp start_box!(output) do
    ref = Ecto.UUID.generate()
    {:ok, pid} = Deposit.start_link(ref: ref, output: output)
    {ref, pid}
  end

  defp valid_payload(summary) do
    %{
      "summary" => summary,
      "status" => "completed",
      "files_changed" => ["lib/thing.ex"],
      "notes" => "n/a",
      "artifacts" => %{}
    }
  end

  test "a valid deposit is accepted and take/1 returns the typed (atom-keyed) map" do
    {ref, _pid} = start_box!(@coder_output)

    assert {:ok, %{status: :accepted}} = Deposit.submit(ref, valid_payload("did the thing"))

    typed = Deposit.take(ref)
    assert typed.summary == "did the thing"
    assert typed.status == :completed

    # take/1 is a read-only peek, not a pop.
    assert Deposit.take(ref) == typed
  end

  test "an invalid deposit returns a bounded schema error, stores nothing, bumps invalids" do
    {ref, pid} = start_box!(@coder_output)

    assert {:error, msg} = Deposit.submit(ref, %{"summary" => "missing required fields"})
    assert msg =~ "output failed schema validation"
    # Bounded like Verdict.format_reason (~240 graphemes + prefix headroom).
    assert String.length(msg) < 320

    assert Deposit.take(ref) == nil
    assert %{invalids: 1, deposits: 0} = :sys.get_state(pid)
  end

  test "a binary JSON payload validates (Output.parse decodes binaries)" do
    {ref, _pid} = start_box!(@coder_output)

    assert {:ok, %{status: :accepted}} =
             Deposit.submit(ref, Jason.encode!(valid_payload("from json")))

    assert %{summary: "from json"} = Deposit.take(ref)
  end

  test "a second valid deposit wins (last-valid-wins)" do
    {ref, _pid} = start_box!(@coder_output)

    assert {:ok, _} = Deposit.submit(ref, valid_payload("first"))
    assert {:ok, _} = Deposit.submit(ref, valid_payload("second"))

    assert %{summary: "second"} = Deposit.take(ref)
  end

  test "an invalid deposit after a valid one leaves the valid one in place" do
    {ref, _pid} = start_box!(@coder_output)

    assert {:ok, _} = Deposit.submit(ref, valid_payload("kept"))
    assert {:error, _} = Deposit.submit(ref, %{"summary" => "drifted"})

    assert %{summary: "kept"} = Deposit.take(ref)
  end

  test "a schema-less box accepts-and-stores the raw payload (degenerate, test-pinned)" do
    {ref, _pid} = start_box!(nil)

    payload = %{"free" => "form"}
    assert {:ok, %{status: :accepted}} = Deposit.submit(ref, payload)
    assert Deposit.take(ref) == payload
  end

  test "take/1 on an empty box is nil; unknown refs degrade cleanly" do
    {ref, _pid} = start_box!(@coder_output)

    assert Deposit.take(ref) == nil
    assert Deposit.take("no-such-ref") == nil
    assert {:error, msg} = Deposit.submit("no-such-ref", %{})
    assert msg =~ "no active deposit"
    assert Deposit.stop("no-such-ref") == :ok
  end

  test "stop/1 deregisters the box (submit after stop is the no-active-deposit error)" do
    {ref, pid} = start_box!(@coder_output)
    monitor = Process.monitor(pid)

    assert Deposit.stop(ref) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert {:error, msg} = Deposit.submit(ref, valid_payload("late"))
    assert msg =~ "no active deposit"
  end
end
