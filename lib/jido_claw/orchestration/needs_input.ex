defmodule JidoClaw.Orchestration.NeedsInput do
  @moduledoc """
  Producer for the `:needs_input` gate case (item 7 PR-4, camus C1-1 sketch
  (e)) — the answer-loop mapping for an executor step whose runner returned
  `:needs_input`.

  `raise_case/2` (best-effort) maps a question-AGNOSTIC stage identity
  fingerprint to a durable pending `AgentCase` (kind `:needs_input`): the
  step still errors and its run rides the existing failure lanes (no
  composer park — the full park is gated on an interactive-runner producer);
  the case is the durable question record and the answer channel.
  `claim_answer/1` (fail-open, the LoopGuard facade posture — a DB fault
  must never block a working stage) is called by the stage's NEXT attempt
  before dispatch: an operator-approved answer (`decision_comment`) decided
  within `@answer_ttl_ms` is consumed single-use (the ToolApprovals model)
  and injected into the vendor prompt; pending/rejected/stale/none/fault all
  read `:none` — a rejected case is never consumed, so a later ask opens a
  FRESH case, and a stale approved case is left inert (visible in history,
  never consumed).

  ## Identity (question-agnostic, floor-guarded)

  The fingerprint hashes `{tenant, identity_key, template, stage}` — never
  the question text (the pre-dispatch claim runs before any question exists,
  and LLM question wording varies across retries). `identity_key` is the
  session key (`session_uuid || session_id`, the ToolApprovals precedent)
  when present, else the workflow run id — the run-scoped degradation: dedup
  within the run still works, and a cross-run claim simply never matches,
  which is correct when no conversation identity exists. With NEITHER, the
  producer REFUSES to open (Trace-warned) rather than share pending/approved
  answers across unrelated same-tenant cron/MCP attempts. The TTL bounds the
  question-agnostic replay window: an approved answer outliving its
  terminalized run is the intended "answer survives the failed attempt"
  semantics, but never past `@answer_ttl_ms`.

  ## Identity vs FK split (pin-types-at-Ash-boundaries)

  The fingerprint's session key is identity-only; the persisted
  `AgentCase.session_id` (a nullable Session UUID FK) is resolved from
  `session_uuid` ONLY — the external session label string never lands in the
  FK column. Likewise the run: the scope carries the extracted run id (the
  Reactor context holds a `%WorkflowRun{}`), stored for provenance only —
  no run status flip, no checkpoint.

  ## First-question-wins (deliberate)

  A reused pending case keeps its ORIGINAL question: retries may rephrase
  the same ask, and per-retry detail updates would need a case-update action
  + event-type growth for no operator value.

  ## Concurrency

  The ToolApprovals fences exactly: the pending-fingerprint partial-unique
  index collapses concurrent opens (the loser re-reads the winner), and the
  FOR-UPDATE lock inside each transaction serializes claim races so an
  approved answer is consumed exactly once.
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Core.CanonicalHash
  alias JidoClaw.Gates.NeedsInputGate
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.CaseProducer
  alias JidoClaw.Orchestration.Gate.Presentation
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Telemetry

  @pending_index "agent_cases_pending_fingerprint_index"

  # An approved answer is claimable for this long after the operator decides;
  # past it the case is left inert. The bound on the question-agnostic
  # cross-run replay window.
  @answer_ttl_ms :timer.hours(24)

  @doc """
  The SHA-256 hex fingerprint of the question-agnostic stage identity
  `{tenant, identity_key, template, stage}` — or `nil` when the scope has
  neither a session key nor a run id (the identity floor; see the moduledoc).
  Public so tests can assert determinism + question-agnosticism.
  """
  @spec fingerprint(map()) :: String.t() | nil
  def fingerprint(scope) do
    case identity_key(scope) do
      nil ->
        nil

      identity ->
        CanonicalHash.sha256_term(
          {:needs_input_v1, scope[:tenant_id], identity, scope[:template_name], stage_key(scope)}
        )
    end
  end

  @doc """
  Best-effort: map the scope's stage identity to a pending `:needs_input`
  case carrying (a redacted copy of) `question`. Returns `{:ok, case}` — a
  fresh open or the reused pending case (retry dedup; first question wins) —
  or `:error` on missing tenant/identity scope or any DB fault. The caller's
  step error returns regardless.
  """
  @spec raise_case(map(), term()) :: {:ok, AgentCase.t()} | :error
  def raise_case(scope, question) do
    tenant_id = scope[:tenant_id]
    actor = scope[:actor] || system_actor(tenant_id)
    fingerprint = fingerprint(scope)

    cond do
      not (is_binary(tenant_id) and tenant_id != "") or is_nil(actor) ->
        warn(:raise, :no_tenant_scope, scope)
        :error

      is_nil(fingerprint) ->
        # The identity floor: session-less AND run-less. Refusing beats
        # sharing pending/approved answers across unrelated same-tenant
        # cron/MCP attempts.
        warn(:raise, :no_identity, scope)
        :error

      true ->
        do_raise(scope, question, fingerprint, tenant_id, actor)
    end
  end

  @doc """
  Fail-open: consume (single-use) an operator-approved answer for the
  scope's stage identity, decided within the answer TTL. `{:ok, answer}` on
  a successful claim; `:none` for pending/rejected/stale/absent cases,
  missing scope, or any DB fault — a claim failure must never block a
  working stage.
  """
  @spec claim_answer(map()) :: {:ok, String.t()} | :none
  def claim_answer(scope) do
    tenant_id = scope[:tenant_id]
    actor = scope[:actor] || system_actor(tenant_id)
    fingerprint = fingerprint(scope)

    if is_binary(tenant_id) and tenant_id != "" and not is_nil(actor) and
         not is_nil(fingerprint) do
      do_claim(fingerprint, tenant_id, actor)
    else
      :none
    end
  end

  # -- Raise --

  defp do_raise(scope, question, fingerprint, tenant_id, actor) do
    case transact_raise(scope, question, fingerprint, tenant_id, actor) do
      {:ok, {:pending_new, agent_case}} ->
        RunPubSub.broadcast_gate_requested(scope[:workflow_run_id], tenant_id, agent_case.id)
        Telemetry.emit_needs_input(:raise, :opened)
        {:ok, agent_case}

      {:ok, {:pending, agent_case}} ->
        Telemetry.emit_needs_input(:raise, :reused)
        {:ok, agent_case}

      {:error, error} ->
        # Open-race loser: a concurrent identical raise won the partial
        # unique index — re-read the winner's pending case.
        if AshErrors.unique_violation?(error, [@pending_index]) do
          reread_pending(fingerprint, tenant_id, actor)
        else
          warn(:raise, {:raise_failed, error}, scope)
          Telemetry.emit_needs_input(:raise, :error)
          :error
        end
    end
  end

  defp transact_raise(scope, question, fingerprint, tenant_id, actor) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, cases} <- CaseProducer.lock_by_fingerprint(fingerprint, tenant_id, actor) do
        case Enum.find(cases, &(&1.status == :pending)) do
          # First-question-wins: the reused pending case keeps its original
          # question (see the moduledoc).
          %AgentCase{} = pending -> {:pending, pending}
          nil -> open(scope, question, fingerprint, tenant_id, actor)
        end
      end
    end)
  end

  defp open(scope, question, fingerprint, tenant_id, actor) do
    attrs = %{
      step_name: stage_key(scope),
      fingerprint: fingerprint,
      workflow_run_id: scope[:workflow_run_id],
      session_id: CaseProducer.resolve_session_id(scope[:session_uuid], tenant_id, actor),
      details: details(scope, question)
    }

    with {:ok, agent_case} <- AgentCase.open_needs_input(attrs, tenant: tenant_id, actor: actor),
         {:ok, _event} <-
           WorkflowLog.case_event(
             agent_case,
             :opened,
             %{kind: :needs_input, template: scope[:template_name]},
             tenant_id,
             actor
           ) do
      {:pending_new, agent_case}
    end
  end

  defp reread_pending(fingerprint, tenant_id, actor) do
    case AgentCase.by_fingerprint(fingerprint, tenant: tenant_id, actor: actor) do
      {:ok, cases} ->
        case Enum.find(cases, &(&1.status == :pending)) do
          %AgentCase{} = agent_case ->
            Telemetry.emit_needs_input(:raise, :reused)
            {:ok, agent_case}

          nil ->
            warn(:raise, :pending_case_vanished, %{fingerprint: fingerprint})
            :error
        end

      {:error, reason} ->
        warn(:raise, {:reread_failed, reason}, %{fingerprint: fingerprint})
        :error
    end
  end

  # Details must be redactor-safe (surfaced in the CLI/web inbox), so the
  # question is redacted STRUCTURALLY here — the step error redacts its own
  # copy at the executor. `injectable` requires BOTH the vendor executor kind
  # AND session-keyed identity: session arms never claim, and a
  # run-scoped-identity case can't be claimed by any later run, so promising
  # injection there would be false.
  defp details(scope, question) do
    NeedsInputGate
    |> Presentation.details()
    |> Map.merge(%{
      "question" => redact_question(question),
      "resume_hint" =>
        "Approve with your answer (the comment) — the stage's next attempt " <>
          "claims it once, within 24h; reject to record that no answer will be given.",
      "template" => scope[:template_name],
      "injectable" => injectable?(scope)
    })
    |> put_present("step_name", present(scope[:step_name]))
    |> put_present("session_id", present(scope[:session_id]))
  end

  @doc """
  Normalize + redact a runner-supplied question for operator-facing sinks
  (the case details AND the step error text): non-binaries are inspected
  first so the redaction root always sees a string.
  """
  @spec redact_question(term()) :: String.t()
  def redact_question(question) when is_binary(question), do: Patterns.redact(question)
  def redact_question(question), do: Patterns.redact(inspect(question))

  defp injectable?(scope) do
    scope[:vendor?] == true and not is_nil(session_key(scope))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # -- Claim --

  defp do_claim(fingerprint, tenant_id, actor) do
    case transact_claim(fingerprint, tenant_id, actor) do
      {:ok, {:claimed, answer}} ->
        Telemetry.emit_needs_input(:claim, :consumed)
        {:ok, answer}

      {:ok, :none} ->
        :none

      {:error, error} ->
        warn(:claim, {:claim_failed, error}, %{fingerprint: fingerprint})
        Telemetry.emit_needs_input(:claim, :error)
        :none
    end
  end

  defp transact_claim(fingerprint, tenant_id, actor) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, cases} <- CaseProducer.lock_by_fingerprint(fingerprint, tenant_id, actor) do
        cases
        |> Enum.find(&claimable?/1)
        |> consume_claimable(tenant_id, actor)
      end
    end)
  end

  defp consume_claimable(nil, _tenant_id, _actor), do: :none

  defp consume_claimable(agent_case, tenant_id, actor) do
    with {:ok, claimed} <- AgentCase.consume(agent_case, %{}, tenant: tenant_id, actor: actor),
         {:ok, _event} <-
           WorkflowLog.case_event(
             claimed,
             :consumed,
             %{outcome: "answer_injected"},
             tenant_id,
             actor
           ) do
      {:claimed, claimed.decision_comment}
    end
  end

  # Claimable = approved, unconsumed, carrying a non-blank answer, decided
  # within the TTL. A blank-comment approved case (only reachable past the
  # `Cases` answer guard by a non-needs-input path) stays inert rather than
  # consuming into an empty injection; a stale one stays inert too.
  defp claimable?(%AgentCase{
         status: :approved,
         consumed_at: nil,
         decided_at: %DateTime{} = decided_at,
         decision_comment: comment
       })
       when is_binary(comment) do
    String.trim(comment) != "" and
      DateTime.diff(DateTime.utc_now(), decided_at, :millisecond) <= @answer_ttl_ms
  end

  defp claimable?(_case), do: false

  # -- Shared --

  # Identity: session key first (conversation identity), else the run id
  # (run-scoped degradation), else nil — the refuse-to-open floor.
  defp identity_key(scope), do: session_key(scope) || present(scope[:workflow_run_id])

  defp session_key(scope), do: present(scope[:session_uuid]) || present(scope[:session_id])

  # `step_name` is nil on the generic/skill path — fall back to the template
  # name for BOTH the stored attr and the fingerprint term (stable everywhere).
  defp stage_key(scope), do: present(scope[:step_name]) || scope[:template_name]

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp system_actor(tenant_id) when is_binary(tenant_id), do: Actor.system(tenant_id)
  defp system_actor(_tenant_id), do: nil

  defp warn(event, reason, context) do
    Logger.warning(
      "[NeedsInput] #{event} degraded (#{inspect(reason)}) for " <>
        "template=#{inspect(context[:template_name])} step=#{inspect(context[:step_name])}"
    )

    JidoClaw.Trace.emit(
      :guardrail,
      %{
        guardrail: "needs_input",
        event: event,
        name: to_string(context[:template_name] || "unknown"),
        trigger: trigger_tag(reason)
      },
      %{system_time: System.system_time()}
    )
  end

  # Total over this module's own warn reasons: bare atoms + {tag, detail}
  # tuples — the closed internal set (Dialyzer rejects a broader catch-all).
  defp trigger_tag(reason) when is_atom(reason), do: reason
  defp trigger_tag({tag, _detail}) when is_atom(tag), do: tag
end
