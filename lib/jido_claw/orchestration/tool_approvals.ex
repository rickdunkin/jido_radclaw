defmodule JidoClaw.Orchestration.ToolApprovals do
  @moduledoc """
  Producer for the conversation-axis tool-approval gate (`kind: :tool_call`).

  `request/3` is the single entry point the wrapper policy
  (`JidoClaw.Security.ToolApproval`) calls when a require-listed (or
  pattern-triggered, or per-template-gated) tool call must clear a human
  approval before it runs. It maps a
  `{tenant, session, agent_template, tool, args}` fingerprint to a durable
  `AgentCase` and returns one of:

    * `{:allowed, case}` — a prior approval exists and was **consumed** by this
      call (single-use); the tool may execute.
    * `{:pending, case}` — a fresh ticket was opened (or an existing pending
      ticket was reused); the tool must not run until an operator approves.
    * `{:denied, case}` — a prior rejection exists and was **consumed**
      (deny-once); the tool must not run, and the next identical call re-pends.
    * `{:error, reason}` — no tenant scope to record a ticket, or a DB fault.
      The policy maps this to a fail-closed `:approval_unavailable`.

  ## Concurrency

  Two correctness properties, two DB primitives:

    * **Open race** (two concurrent first-calls, no ticket yet): the partial
      unique index `agent_cases_pending_fingerprint_index` lets exactly one
      `open_tool_call` insert win; the loser catches the unique violation and
      re-reads the winner's pending ticket.
    * **Consume race** (two concurrent retries against one approval): the
      transaction locks the fingerprint's case rows `FOR UPDATE` (the same
      row-lock idiom `Cases.lock_run/3` uses) before classifying, so one retry
      consumes the approval and the other — blocked on the lock — re-reads the
      now-consumed row and re-pends. An approval grants **one attempt**.

  ## Fingerprint

  `fingerprint/3` hashes a **canonical semantic term** (the DefinitionFingerprint
  discipline), not raw params: map keys and enum-like atom scalars are
  stringified and maps become key-sorted pair lists, so the same logical call
  fingerprints identically whether it arrives atom-keyed (internal) or
  string-keyed (MCP/JSON). `nil`/booleans are preserved (identical across both
  paths) to avoid over-collapsing `true` and `"true"`.

  The term carries the calling agent's `:agent_template` (term version `:v2`),
  so an approval is **template-scoped**: a `git_commit` approved for `"main"`
  is not reusable by a `"coder"` worker — consent is per-template. Two
  instances of the *same* template still collapse to one case (the fingerprint
  omits the per-instance `agent_id`). A non-binary template normalizes to the
  same hash as `nil`.

  ## Redaction

  `details` is pre-redacted at the producer (the `AgentCase.details` column has
  no write-time redaction): the structured params are run through
  `Transcript.redact/1` **first**, then summarized/capped — summarizing first
  would drop key context and let a key-named secret (`%{api_key: ...}`) survive
  into the operator inbox. `AgentCaseEvent.data` is auto-redacted by its
  `Allocate` change.
  """

  require Ash.Query, as: Query

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Conversations.ToolTranscript
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Core.CanonicalHash
  alias JidoClaw.Gates.ToolCallGate
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.AgentCaseEvent
  alias JidoClaw.Orchestration.Gate.Presentation
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Security.Redaction.Transcript

  @pending_index "agent_cases_pending_fingerprint_index"

  @type outcome :: {:allowed | :pending | :denied, AgentCase.t()}

  @doc """
  Resolve the approval state for `tool_name`/`params` under `scope`.

  `scope` is the tool's `tool_context` map (tenant/session/actor). Returns an
  `outcome/0` tuple or `{:error, reason}` when there is no tenant scope to
  record a ticket or a DB write fails.
  """
  @spec request(map(), atom() | String.t(), map()) :: outcome() | {:error, term()}
  def request(scope, tool_name, params) when is_map(scope) do
    tenant_id = scope[:tenant_id]
    actor = scope[:actor] || system_actor(tenant_id)

    if is_binary(tenant_id) and actor do
      tool = to_string(tool_name)
      run(scope, tool, params, fingerprint(scope, tool, params), tenant_id, actor)
    else
      {:error, :no_tenant_scope}
    end
  end

  @doc """
  The SHA-256 hex fingerprint of the canonical `{tenant, session, tool, args}`
  term. Public so the policy/tests can assert determinism + canonicalization.
  """
  @spec fingerprint(map(), atom() | String.t(), map()) :: String.t()
  def fingerprint(scope, tool_name, params) do
    session_key = scope[:session_uuid] || scope[:session_id]

    term =
      {:v2, scope[:tenant_id], session_key, agent_template(scope), to_string(tool_name),
       canonical_params(params)}

    CanonicalHash.sha256_term(term)
  end

  # -- Internal --

  # The calling agent's template scopes the fingerprint (and the operator
  # detail): consent is per-template, so two `coder` instances issuing the
  # identical call collapse to one case, but a `coder` call never reuses a
  # `main` approval. Only a binary survives — guard against an atom/non-JSON
  # value from a future/test caller normalizing to the same hash as `nil`.
  defp agent_template(scope) do
    case scope[:agent_template] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp system_actor(tenant_id) when is_binary(tenant_id), do: Actor.system(tenant_id)
  defp system_actor(_tenant_id), do: nil

  defp run(scope, tool, params, fingerprint, tenant_id, actor) do
    case transact(scope, tool, params, fingerprint, tenant_id, actor) do
      {:ok, {:pending_new, agent_case}} ->
        broadcast_opened(agent_case, tenant_id)
        {:pending, agent_case}

      {:ok, outcome} ->
        outcome

      {:error, error} ->
        # Open-race loser: a concurrent first-call won the partial unique index.
        if AshErrors.unique_violation?(error, [@pending_index]) do
          reread_pending(fingerprint, tenant_id, actor)
        else
          {:error, error}
        end
    end
  end

  # One transaction: lock the fingerprint's case rows FOR UPDATE, classify the
  # locked snapshot, and consume/open accordingly. The lock is what makes the
  # consume race-safe (see moduledoc).
  defp transact(scope, tool, params, fingerprint, tenant_id, actor) do
    Ash.transact([AgentCase, AgentCaseEvent], fn ->
      with {:ok, cases} <- lock_by_fingerprint(fingerprint, tenant_id, actor) do
        act(classify(cases), scope, tool, params, fingerprint, tenant_id, actor)
      end
    end)
  end

  defp lock_by_fingerprint(fingerprint, tenant_id, actor) do
    AgentCase
    |> Query.filter(fingerprint == ^fingerprint)
    |> Query.sort(inserted_at: :desc)
    |> Query.lock("FOR UPDATE")
    |> Ash.read(tenant: tenant_id, actor: actor)
  end

  # Priority: a live approval beats a pending ticket beats a live rejection.
  # All three finds are cheap (the per-fingerprint list is tiny).
  defp classify(cases) do
    approved = Enum.find(cases, &approved_unconsumed?/1)
    pending = Enum.find(cases, &(&1.status == :pending))
    rejected = Enum.find(cases, &rejected_unconsumed?/1)

    cond do
      approved -> {:approved, approved}
      pending -> {:pending, pending}
      rejected -> {:rejected, rejected}
      true -> :none
    end
  end

  defp approved_unconsumed?(%AgentCase{status: :approved, consumed_at: nil}), do: true
  defp approved_unconsumed?(_case), do: false

  defp rejected_unconsumed?(%AgentCase{status: :rejected, consumed_at: nil}), do: true
  defp rejected_unconsumed?(_case), do: false

  defp act({:approved, agent_case}, _scope, _tool, _params, _fp, tenant_id, actor) do
    claim(agent_case, :consume, :allowed, tenant_id, actor)
  end

  defp act({:pending, agent_case}, _scope, _tool, _params, _fp, _tenant_id, _actor) do
    {:pending, agent_case}
  end

  defp act({:rejected, agent_case}, _scope, _tool, _params, _fp, tenant_id, actor) do
    claim(agent_case, :consume_rejection, :denied, tenant_id, actor)
  end

  defp act(:none, scope, tool, params, fingerprint, tenant_id, actor) do
    open(scope, tool, params, fingerprint, tenant_id, actor)
  end

  # Consume the decided case + append the :consumed timeline row, atomically
  # with the surrounding transaction. Returns the bare outcome on success or
  # `{:error, _}` to roll the transaction back.
  defp claim(agent_case, action, outcome_tag, tenant_id, actor) do
    with {:ok, claimed} <-
           apply(AgentCase, action, [agent_case, %{}, [tenant: tenant_id, actor: actor]]),
         {:ok, _event} <-
           WorkflowLog.case_event(
             claimed,
             :consumed,
             %{outcome: Atom.to_string(outcome_tag)},
             tenant_id,
             actor
           ) do
      {outcome_tag, claimed}
    end
  end

  defp open(scope, tool, params, fingerprint, tenant_id, actor) do
    attrs = %{
      step_name: tool,
      tool_name: tool,
      fingerprint: fingerprint,
      session_id: resolve_session_id(scope[:session_uuid], tenant_id, actor),
      details: details(scope, tool, params)
    }

    with {:ok, agent_case} <- AgentCase.open_tool_call(attrs, tenant: tenant_id, actor: actor),
         {:ok, _event} <-
           WorkflowLog.case_event(
             agent_case,
             :opened,
             %{tool: tool, kind: :tool_call},
             tenant_id,
             actor
           ) do
      {:pending_new, agent_case}
    end
  end

  # Open-race loser re-read: the unique index rejected our insert, so a pending
  # ticket for this fingerprint already committed — return it.
  defp reread_pending(fingerprint, tenant_id, actor) do
    case AgentCase.by_fingerprint(fingerprint, tenant: tenant_id, actor: actor) do
      {:ok, cases} ->
        case Enum.find(cases, &(&1.status == :pending)) do
          %AgentCase{} = agent_case -> {:pending, agent_case}
          nil -> {:error, :pending_case_vanished}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Redact the STRUCTURED params first, then summarize/cap — order is
  # load-bearing (see moduledoc): summarizing first would leak a key-named
  # secret into the operator-visible inbox.
  defp details(scope, tool, params) do
    redacted = Transcript.redact(params)

    ToolCallGate
    |> Presentation.details()
    |> Map.merge(%{
      "tool" => tool,
      "arguments" => ToolTranscript.summarize_args(tool, redacted)
    })
    |> put_present("session_id", scope[:session_id])
    |> put_present("agent_template", agent_template(scope))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # The column stores the Conversations.Session UUID FK (never the runtime
  # external id). Resolve it to a real row so a stray/half-written session id
  # degrades to nil rather than failing the gate closed on an FK violation.
  defp resolve_session_id(uuid, tenant_id, actor) when is_binary(uuid) and uuid != "" do
    case Session.by_id(uuid, tenant: tenant_id, actor: actor) do
      {:ok, %Session{id: id}} -> id
      _ -> nil
    end
  end

  defp resolve_session_id(_uuid, _tenant_id, _actor), do: nil

  defp broadcast_opened(agent_case, tenant_id) do
    RunPubSub.broadcast_gate_requested(nil, tenant_id, agent_case.id)
  end

  # -- Fingerprint canonicalization (DefinitionFingerprint discipline) --

  # S-L3 INVARIANT: canonicalization must only reorder/stringify keys — it must
  # NEVER collapse two DIFFERENT tool-call payloads to the same canonical form, or
  # a single human approval would authorize a distinct command (approvals are
  # single-use, keyed on this fingerprint). Any future normalization added here
  # (case-folding, whitespace trimming, arg dropping) must preserve command
  # distinctness: when unsure, keep the value verbatim.
  defp canonical_params(params), do: canonical(params)

  defp canonical(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  # nil/booleans are identical across MCP/internal paths — preserve them so
  # `true` and the string "true" do not collide. Other atoms (`:fast`)
  # stringify to collide with their JSON string form ("fast").
  defp canonical(value) when is_nil(value) or is_boolean(value), do: value
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end
