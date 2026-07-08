defmodule JidoClaw.Orchestration.VisibilityTest do
  @moduledoc """
  Pins the T2-2 visibility projection: the operator scope is the permanent
  LLM/MCP shape (legacy `run_to_map` key set + `deadline`, key-filtered
  summary, redacted-then-truncated error, NO step output); the auditor scope
  (dashboard reveal) adds full payloads that are still scrubbed; and the
  redact-before-truncate ordering means truncation can never bisect a secret
  into a survivable fragment. Pure struct-in/map-out — no DB.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Orchestration.WorkflowStep

  @now ~U[2026-06-10 12:00:00.000000Z]
  @secret "sk-" <> String.duplicate("a", 24)

  defp run_fixture(overrides \\ []) do
    struct!(
      %WorkflowRun{
        id: "run-1",
        tenant_id: "t",
        name: "fixture",
        workflow_type: "reactor",
        status: :failed,
        config: %{},
        started_at: ~U[2026-06-10 11:00:00.000000Z],
        completed_at: ~U[2026-06-10 11:05:00.000000Z],
        result: %{"summary" => "done", "token" => @secret, "detail" => "key #{@secret}"},
        error: "boom: #{@secret}"
      },
      overrides
    )
  end

  defp step_fixture(overrides \\ []) do
    struct!(
      %WorkflowStep{
        id: "step-1",
        tenant_id: "t",
        name: "alpha",
        step_type: "agent",
        sequence: 1,
        status: :failed,
        started_at: ~U[2026-06-10 11:00:00.000000Z],
        completed_at: ~U[2026-06-10 11:01:00.000000Z],
        output: %{"result" => "wrote #{@secret}", "authorization" => "Bearer xyz"},
        error: "step blew up: #{@secret}"
      },
      overrides
    )
  end

  describe "run_view/3 disposition (camus C1-4)" do
    test "lifts result.disposition + findings_deferred_count, tolerant of atom/string keys" do
      string_keyed =
        run_fixture(
          status: :completed,
          result: %{"disposition" => "done_with_findings", "findings_deferred_count" => 3}
        )

      view = Visibility.run_view(string_keyed, :operator, @now)
      assert view.disposition == "done_with_findings"
      assert view.findings_deferred_count == 3

      atom_keyed =
        run_fixture(
          status: :completed,
          result: %{disposition: "done_with_findings", findings_deferred_count: 1}
        )

      atom_view = Visibility.run_view(atom_keyed, :operator, @now)
      assert atom_view.disposition == "done_with_findings"
      assert atom_view.findings_deferred_count == 1
    end

    test "rejects malformed disposition values (non-binary, negative counts) to nil" do
      malformed =
        run_fixture(result: %{"disposition" => 42, "findings_deferred_count" => -1})

      view = Visibility.run_view(malformed, :operator, @now)
      assert view.disposition == nil
      assert view.findings_deferred_count == nil
    end
  end

  describe "run_view/3" do
    test "operator preserves the legacy run_to_map key set + deadline (MCP contract)" do
      view = Visibility.run_view(run_fixture(), :operator, @now)

      # `disposition` + `findings_deferred_count` (camus C1-4) and the WS6
      # ownership fields (`claimed_by`/`claim_expires_at`) additively extend
      # the legacy key set — riding the base projection so every downstream
      # surface inherits them.
      assert Enum.sort(Map.keys(view)) ==
               Enum.sort([
                 :run_id,
                 :name,
                 :workflow_type,
                 :status,
                 :disposition,
                 :findings_deferred_count,
                 :started_at,
                 :completed_at,
                 :duration_ms,
                 :claimed_by,
                 :claim_expires_at,
                 :error,
                 :result_summary,
                 :deadline
               ])

      assert view.run_id == "run-1"
      assert view.duration_ms == 300_000
      # No disposition on an ordinary result — both C1-4 keys read nil.
      assert view.disposition == nil
      assert view.findings_deferred_count == nil
    end

    test "ownership fields pass through raw (frozen on terminal runs)" do
      expiry = ~U[2026-06-10 11:04:00.000000Z]

      view =
        [claimed_by: "node@host", claim_expires_at: expiry]
        |> run_fixture()
        |> Visibility.run_view(:operator, @now)

      # Raw column reads, even on this :failed (terminal) fixture — the frozen
      # last-claim value, never live lease state; consumers pair with :status.
      assert view.claimed_by == "node@host"
      assert view.claim_expires_at == expiry
    end

    test "operator: no raw result, summary key-filtered AND scrubbed" do
      view = Visibility.run_view(run_fixture(), :operator, @now)

      refute Map.has_key?(view, :result)
      # Only the summary keys survive, post-redaction.
      assert view.result_summary == %{"summary" => "done"}
      refute inspect(view) =~ @secret
    end

    test "operator: error is redacted (no secret survives)" do
      view = Visibility.run_view(run_fixture(), :operator, @now)
      assert view.error =~ "[REDACTED:API_KEY]"
      refute view.error =~ @secret
    end

    test "auditor: full result present, sensitive keys + secret strings scrubbed" do
      view = Visibility.run_view(run_fixture(), :auditor, @now)

      # The "token" key is wholesale-replaced; the secret-shaped string inside
      # an innocent key is pattern-scrubbed; the rest survives intact.
      assert view.result["token"] == "[REDACTED]"
      assert view.result["detail"] == "key [REDACTED:API_KEY]"
      assert view.result["summary"] == "done"
      refute inspect(view) =~ @secret
    end

    test "auditor: error untruncated but still scrubbed" do
      long_error = String.duplicate("x", 500) <> " " <> @secret
      view = Visibility.run_view(run_fixture(error: long_error), :auditor, @now)

      assert String.length(view.error) > 200
      assert view.error =~ "[REDACTED:API_KEY]"
      refute view.error =~ @secret
    end

    test "deadline evidence is computed from config + lifecycle stamps" do
      run =
        run_fixture(
          config: %{"deadline" => %{"within" => 60}},
          status: :running,
          completed_at: nil
        )

      view = Visibility.run_view(run, :operator, @now)
      # Started 11:00, 60s policy, now 12:00 -> very overdue.
      assert view.deadline.status == :overdue
      assert view.deadline.overdue_by_ms == 3_540_000
    end

    test "nils pass through (fresh pending run)" do
      run =
        run_fixture(
          status: :pending,
          started_at: nil,
          completed_at: nil,
          result: nil,
          error: nil
        )

      view = Visibility.run_view(run, :operator, @now)
      assert view.error == nil
      assert view.result_summary == nil
      assert view.duration_ms == nil
      assert view.deadline == nil
    end
  end

  describe "step_view/3" do
    test "operator carries NO output key at all" do
      view = Visibility.step_view(step_fixture(), :operator, @now)

      refute Map.has_key?(view, :output)

      assert Enum.sort(Map.keys(view)) ==
               Enum.sort([
                 :name,
                 :step_type,
                 :sequence,
                 :status,
                 :started_at,
                 :completed_at,
                 :deadline,
                 :error
               ])

      refute inspect(view) =~ @secret
    end

    test "auditor adds the full output, scrubbed" do
      view = Visibility.step_view(step_fixture(), :auditor, @now)

      assert view.output["authorization"] == "[REDACTED]"
      assert view.output["result"] == "wrote [REDACTED:API_KEY]"
      refute inspect(view) =~ @secret
    end

    test "step deadline evidence freezes at completed_at" do
      step = step_fixture(deadline: %{"within" => 30}, error: nil, status: :completed)
      view = Visibility.step_view(step, :operator, @now)

      # Started 11:00:00, completed 11:01:00, 30s policy -> overdue by 30s,
      # frozen regardless of the much-later now.
      assert view.deadline.status == :overdue
      assert view.deadline.overdue_by_ms == 30_000
    end
  end

  describe "redact_error/2 (redact-before-truncate)" do
    test "a secret straddling the 200-char boundary never leaks a prefix" do
      # 190 padding chars + a 27-char secret: chars 191..217 — truncate-first
      # would keep a 10-char "sk-aaaaaaa" prefix that no pattern matches.
      error = String.duplicate("x", 190) <> @secret

      operator = Visibility.redact_error(error, :operator)
      assert String.length(operator) <= 200
      refute operator =~ "sk-"

      auditor = Visibility.redact_error(error, :auditor)
      assert auditor == String.duplicate("x", 190) <> "[REDACTED:API_KEY]"
    end

    test "operator truncates to 200 after scrubbing; auditor never truncates" do
      long = String.duplicate("y", 400)
      assert Visibility.redact_error(long, :operator) == String.duplicate("y", 200)
      assert Visibility.redact_error(long, :auditor) == long
    end

    test "nil passes through for both scopes" do
      assert Visibility.redact_error(nil, :operator) == nil
      assert Visibility.redact_error(nil, :auditor) == nil
    end
  end

  describe "public? guard (T2-2 flip)" do
    test "run/step payload attributes are private to Ash API extensions" do
      for {resource, attr} <- [
            {WorkflowRun, :result},
            {WorkflowRun, :error},
            {WorkflowStep, :output},
            {WorkflowStep, :error}
          ] do
        assert %{public?: false} = Info.attribute(resource, attr),
               "#{inspect(resource)}.#{attr} must be public?(false)"
      end
    end
  end
end
