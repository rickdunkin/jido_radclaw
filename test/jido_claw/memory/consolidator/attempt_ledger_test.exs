defmodule JidoClaw.Memory.Consolidator.AttemptLedgerTest do
  @moduledoc """
  The pure close-then-evaluate policy table (docs/system/forge-session-resume.md):
  token validation, reserve-then-execute accounting, the commit/staging-close
  marker, the publish gate, the driver-side ledger-gated retry, and the
  crash-replay table — exhaustively, without a RunServer.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Memory.Consolidator.AttemptLedger

  @ctx %{remaining_ms: 60_000, floor_ms: 5_000, recoverable?: true}

  defp open!(ledger \\ AttemptLedger.new()) do
    {:ok, token, ledger} = AttemptLedger.open(ledger)
    {token, ledger}
  end

  defp result(status, metadata \\ %{}, error \\ nil),
    do: {:result, %{status: status, error: error, metadata: metadata}}

  defp rejected_resume_error(retry?) do
    result(:error, %{error_details: %{resume_rejected: true, retry: retry?}}, "rejected")
  end

  describe "token validation" do
    test "the open attempt's token validates; closed, foreign, and absent tokens are refused" do
      {token, ledger} = open!()

      assert :ok = AttemptLedger.validate(ledger, token)
      assert {:error, :attempt_closed} = AttemptLedger.validate(ledger, Ecto.UUID.generate())
      assert {:error, :attempt_closed} = AttemptLedger.validate(ledger, nil)

      {_directive, closed} = AttemptLedger.close_and_evaluate(ledger, token, result(:done), @ctx)
      assert {:error, :attempt_closed} = AttemptLedger.validate(closed, token)
    end

    test "only one attempt may be open at a time" do
      {_token, ledger} = open!()
      assert {:error, :attempt_already_open} = AttemptLedger.open(ledger)
    end
  end

  describe "reserve-then-execute + commit marker" do
    test "reservations are per-attempt and refused for stale tokens" do
      {token, ledger} = open!()

      assert {:ok, reserved} = AttemptLedger.reserve_mutation(ledger, token)
      assert {:error, :attempt_closed} = AttemptLedger.reserve_mutation(reserved, "other")

      assert reserved.attempts[token].mutations == 1
    end

    test "commit closes staging: later mutations and second commits are refused" do
      {token, ledger} = open!()

      assert {:ok, committed} = AttemptLedger.record_commit(ledger, token)
      assert committed.staging_closed?
      assert committed.commit_token == token

      assert {:error, :staging_closed} = AttemptLedger.reserve_mutation(committed, token)
      assert {:error, :staging_closed} = AttemptLedger.record_commit(committed, token)
    end
  end

  describe "publish gate (commit marker + clean exit of the SAME attempt)" do
    test "commit + :done publishes" do
      {token, ledger} = open!()
      {:ok, committed} = AttemptLedger.record_commit(ledger, token)

      assert {:publish, _} =
               AttemptLedger.close_and_evaluate(committed, token, result(:done), @ctx)
    end

    test "commit + :continue publishes (claude's error_max_turns is a clean exit)" do
      {token, ledger} = open!()
      {:ok, committed} = AttemptLedger.record_commit(ledger, token)

      assert {:publish, _} =
               AttemptLedger.close_and_evaluate(committed, token, result(:continue), @ctx)
    end

    test "commit + an unclean exit NEVER publishes" do
      {token, ledger} = open!()
      {:ok, committed} = AttemptLedger.record_commit(ledger, token)

      assert {{:halt, "commit_without_clean_exit"}, _} =
               AttemptLedger.close_and_evaluate(
                 committed,
                 token,
                 result(:error, %{}, "boom"),
                 @ctx
               )
    end

    test "a commit from a PREVIOUS attempt never authorizes a later attempt's exit" do
      {token1, ledger} = open!()
      {:ok, committed} = AttemptLedger.record_commit(ledger, token1)

      {_directive, closed} =
        AttemptLedger.close_and_evaluate(committed, token1, result(:error, %{}, "boom"), @ctx)

      {:ok, token2, reopened} = AttemptLedger.open(closed)

      assert {{:halt, "completed_without_commit"}, _} =
               AttemptLedger.close_and_evaluate(reopened, token2, result(:done), @ctx)
    end

    test ":done without a commit halts; :continue without a commit continues" do
      {done_token, done_ledger} = open!()

      assert {{:halt, "completed_without_commit"}, _} =
               AttemptLedger.close_and_evaluate(done_ledger, done_token, result(:done), @ctx)

      {continue_token, continue_ledger} = open!()

      assert {:continue, _} =
               AttemptLedger.close_and_evaluate(
                 continue_ledger,
                 continue_token,
                 result(:continue),
                 @ctx
               )
    end
  end

  describe "driver-side ledger-gated retry" do
    test "authorized exactly once: rejected resume + retryable + zero effects + deadline" do
      {token, ledger} = open!()

      assert {:retry_fresh, latched} =
               AttemptLedger.close_and_evaluate(ledger, token, rejected_resume_error(true), @ctx)

      assert latched.resume_retry_used?

      # The latch: a second rejected resume halts.
      {token2, reopened} = open!(latched)

      assert {{:halt, "rejected"}, _} =
               AttemptLedger.close_and_evaluate(
                 reopened,
                 token2,
                 rejected_resume_error(true),
                 @ctx
               )
    end

    test "a mutation in the attempt blocks the retry" do
      {token, ledger} = open!()
      {:ok, reserved} = AttemptLedger.reserve_mutation(ledger, token)

      assert {{:halt, "rejected"}, _} =
               AttemptLedger.close_and_evaluate(
                 reserved,
                 token,
                 rejected_resume_error(true),
                 @ctx
               )
    end

    test "a non-retryable kind blocks the retry (fallback message / invalid request)" do
      {token, ledger} = open!()

      assert {{:halt, "rejected"}, _} =
               AttemptLedger.close_and_evaluate(ledger, token, rejected_resume_error(false), @ctx)
    end

    test "an exhausted deadline blocks the retry" do
      {token, ledger} = open!()
      ctx = %{@ctx | remaining_ms: 1_000}

      assert {{:halt, "rejected"}, _} =
               AttemptLedger.close_and_evaluate(ledger, token, rejected_resume_error(true), ctx)
    end

    test "an ordinary error (no resume_rejected tag) never retries" do
      {token, ledger} = open!()

      assert {{:halt, "boom"}, _} =
               AttemptLedger.close_and_evaluate(ledger, token, result(:error, %{}, "boom"), @ctx)
    end
  end

  describe "crash-replay table" do
    test "an effect-free crash awaits recovery exactly once" do
      {token, ledger} = open!()

      assert {:await_recovery, latched} =
               AttemptLedger.close_and_evaluate(ledger, token, {:crashed, :died}, @ctx)

      assert latched.crash_replay_used?

      # The latch: a second effect-free crash is terminal.
      {token2, reopened} = open!(latched)

      assert {{:halt, "harness_crash_replay_exhausted"}, _} =
               AttemptLedger.close_and_evaluate(reopened, token2, {:crashed, :died}, @ctx)
    end

    test "any mutation makes a crash terminal — no replay, nothing published" do
      {token, ledger} = open!()
      {:ok, reserved} = AttemptLedger.reserve_mutation(ledger, token)

      assert {{:halt, "harness_crashed_after_effects"}, _} =
               AttemptLedger.close_and_evaluate(reserved, token, {:crashed, :died}, @ctx)
    end

    test "a commit marker makes a crash terminal" do
      {token, ledger} = open!()
      {:ok, committed} = AttemptLedger.record_commit(ledger, token)

      assert {{:halt, "harness_crashed_after_effects"}, _} =
               AttemptLedger.close_and_evaluate(committed, token, {:crashed, :died}, @ctx)
    end

    test "an unrecoverable session (claim: false / persistence off) never awaits" do
      {token, ledger} = open!()
      ctx = %{@ctx | recoverable?: false}

      assert {{:halt, "harness_crashed_unrecoverable"}, _} =
               AttemptLedger.close_and_evaluate(ledger, token, {:crashed, :died}, ctx)
    end

    test "an exhausted deadline makes a crash terminal without burning the replay latch" do
      {token, ledger} = open!()
      ctx = %{@ctx | remaining_ms: 0}

      assert {{:halt, "run_deadline_exceeded"}, closed} =
               AttemptLedger.close_and_evaluate(ledger, token, {:crashed, :died}, ctx)

      refute closed.crash_replay_used?
    end
  end
end
