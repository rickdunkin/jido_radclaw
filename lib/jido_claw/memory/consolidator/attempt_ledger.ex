defmodule JidoClaw.Memory.Consolidator.AttemptLedger do
  @moduledoc """
  The consolidator's per-run attempt ledger: attempt-bound capability
  tokens, reserve-then-execute mutation accounting, the commit marker, and
  the close-then-evaluate directive table
  (docs/system/forge-session-resume.md).

  Pure data — every transition is a function of the ledger struct, so the
  policy table is testable without a RunServer. The RunServer serializes
  all mutations through its own GenServer dispatch (validation, reservation,
  commit, and close are single messages on one process), which is what makes
  reserve-then-execute atomic: a close observes every reservation.

  Laws encoded here:

    * every MCP call — readers included — validates its attempt token
      against the single OPEN attempt; a closed/unknown/absent token gets a
      typed refusal the CLI sees (a stale CLI cannot even read state);
    * mutators reserve BEFORE the mutation executes (over-counting a
      soft-rejected proposal is deliberate — the safe direction for retry
      and crash decisions);
    * `commit` closes staging to further writes and records which attempt
      carried the marker; it never publishes — only the driver does;
    * publication authority = the commit marker PLUS a clean process exit
      (`:done` or `:continue` — claude's `:continue` is `error_max_turns`
      on exit 0) of the SAME attempt;
    * the driver-side fresh retry is authorized ONCE per run, and only for
      a rejected resume (`resume_rejected`) with a retryable kind, a
      zero-effect no-commit attempt, and deadline ≥ floor;
    * a harness crash replays the interrupted logical turn ONCE, only when
      its attempt was effect-free and recovery is possible; any effect (or
      a spent latch) is terminal — Manager recovery restores process +
      state, never re-issues work.
  """

  defstruct open_token: nil,
            attempts: %{},
            commit_token: nil,
            staging_closed?: false,
            resume_retry_used?: false,
            crash_replay_used?: false

  @type attempt :: %{mutations: non_neg_integer(), commit?: boolean()}

  @type t :: %__MODULE__{
          open_token: String.t() | nil,
          attempts: %{optional(String.t()) => attempt()},
          commit_token: String.t() | nil,
          staging_closed?: boolean(),
          resume_retry_used?: boolean(),
          crash_replay_used?: boolean()
        }

  @typedoc """
  What the driver does next after a close:
    * `:publish` — commit marker + clean exit of the committing attempt;
    * `:continue` — clean `:continue` without a commit (the driver owns the
      iteration bound);
    * `:retry_fresh` — the one authorized ledger-gated fresh retry;
    * `:await_recovery` — effect-free harness crash, replay once after the
      Manager restores the session;
    * `{:halt, reason}` — terminal failure, publish nothing.
  """
  @type directive ::
          :publish | :continue | :retry_fresh | :await_recovery | {:halt, String.t()}

  @type close_ctx :: %{
          remaining_ms: integer(),
          floor_ms: non_neg_integer(),
          recoverable?: boolean()
        }

  @doc "A fresh ledger."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Open the next attempt (exactly one may be open). Returns the minted
  capability token.
  """
  @spec open(t()) :: {:ok, String.t(), t()} | {:error, :attempt_already_open}
  def open(%__MODULE__{open_token: nil} = ledger) do
    token = Ecto.UUID.generate()

    {:ok, token,
     %{
       ledger
       | open_token: token,
         attempts: Map.put(ledger.attempts, token, %{mutations: 0, commit?: false})
     }}
  end

  def open(%__MODULE__{}), do: {:error, :attempt_already_open}

  @doc """
  Validate a call's attempt token — every MCP call, readers included.
  """
  @spec validate(t(), term()) :: :ok | {:error, :attempt_closed}
  def validate(%__MODULE__{open_token: token}, token) when is_binary(token), do: :ok
  def validate(%__MODULE__{}, _token), do: {:error, :attempt_closed}

  @doc """
  Reserve a mutation for the calling attempt BEFORE it executes. Refused
  once staging is closed (the commit marker landed) or when the token is
  not the open attempt.
  """
  @spec reserve_mutation(t(), term()) ::
          {:ok, t()} | {:error, :attempt_closed | :staging_closed}
  def reserve_mutation(%__MODULE__{} = ledger, token) do
    with :ok <- validate(ledger, token) do
      if ledger.staging_closed? do
        {:error, :staging_closed}
      else
        {:ok,
         update_in(ledger.attempts[token], fn attempt ->
           %{attempt | mutations: attempt.mutations + 1}
         end)}
      end
    end
  end

  @doc """
  Record the commit marker for the calling attempt and close staging to
  further writes. Never publishes. Idempotent-hostile by design: a second
  commit is refused (`:staging_closed`) — the loop never continues past a
  commit, so a later attempt could never match anyway.
  """
  @spec record_commit(t(), term()) ::
          {:ok, t()} | {:error, :attempt_closed | :staging_closed}
  def record_commit(%__MODULE__{} = ledger, token) do
    with :ok <- validate(ledger, token) do
      if ledger.staging_closed? do
        {:error, :staging_closed}
      else
        ledger =
          ledger
          |> Map.put(:commit_token, token)
          |> Map.put(:staging_closed?, true)
          |> update_in([Access.key!(:attempts), token], &%{&1 | commit?: true})

        {:ok, ledger}
      end
    end
  end

  @doc """
  Close the attempt FIRST (later calls bearing its token are refused), then
  evaluate the outcome against the ledger — the crash-replay table and the
  publish/retry authorization live here. `outcome` is `{:result, map}` (an
  iteration result — status/metadata) or `{:crashed, detail}` (the harness
  process died, distinguished from an iteration error result).
  """
  @spec close_and_evaluate(t(), term(), {:result, map()} | {:crashed, term()}, close_ctx()) ::
          {directive(), t()}
  def close_and_evaluate(%__MODULE__{} = ledger, token, outcome, ctx) do
    {attempt, ledger} = close(ledger, token)
    evaluate(ledger, token, attempt, outcome, ctx)
  end

  defp close(%__MODULE__{open_token: token} = ledger, token) when is_binary(token) do
    {Map.get(ledger.attempts, token), %{ledger | open_token: nil}}
  end

  defp close(%__MODULE__{} = ledger, token) do
    # Already closed (the watchdog got there first) or never opened —
    # evaluate against whatever was recorded; a nil attempt is effect-free.
    {Map.get(ledger.attempts, token), ledger}
  end

  # -- the directive table -----------------------------------------------------

  defp evaluate(ledger, token, attempt, {:crashed, _detail}, ctx) do
    effects? = effects?(attempt, ledger, token)

    cond do
      effects? ->
        {{:halt, "harness_crashed_after_effects"}, ledger}

      not ctx.recoverable? ->
        {{:halt, "harness_crashed_unrecoverable"}, ledger}

      ledger.crash_replay_used? ->
        {{:halt, "harness_crash_replay_exhausted"}, ledger}

      ctx.remaining_ms < ctx.floor_ms ->
        {{:halt, "run_deadline_exceeded"}, ledger}

      true ->
        {:await_recovery, %{ledger | crash_replay_used?: true}}
    end
  end

  defp evaluate(ledger, token, attempt, {:result, result}, ctx) do
    committed? = ledger.commit_token == token and is_binary(token)

    case {committed?, result.status} do
      {true, status} when status in [:done, :continue] ->
        {:publish, ledger}

      {true, _unclean} ->
        # A commit whose attempt ends in a genuine error/timeout does NOT
        # publish — the marker without a clean exit is a terminal failure.
        {{:halt, "commit_without_clean_exit"}, ledger}

      {false, :done} ->
        {{:halt, "completed_without_commit"}, ledger}

      {false, :continue} ->
        {:continue, ledger}

      {false, :needs_input} ->
        {{:halt, "harness_needs_input"}, ledger}

      {false, :blocked} ->
        {{:halt, "harness_blocked"}, ledger}

      {false, :error} ->
        evaluate_error(ledger, attempt, result, ctx)
    end
  end

  # The driver-side ledger-gated retry (PORT-MC1-1 sign-off Q3): ONE fresh
  # attempt iff the runner tagged the failure as a rejected resume of a
  # retryable kind AND the closed attempt's ledger shows zero mutations and
  # no commit AND deadline ≥ floor AND the latch is unset. Runners never
  # auto-retry; non-retryable kinds (fallback message, invalid request)
  # halt with the honest error.
  defp evaluate_error(ledger, attempt, result, ctx) do
    details = error_details(result)

    authorized? =
      Map.get(details, :resume_rejected, false) == true and
        Map.get(details, :retry, false) == true and
        not effects_in_attempt?(attempt) and
        ctx.remaining_ms >= ctx.floor_ms and
        not ledger.resume_retry_used?

    if authorized? do
      {:retry_fresh, %{ledger | resume_retry_used?: true}}
    else
      {{:halt, error_string(result)}, ledger}
    end
  end

  defp error_details(%{metadata: %{error_details: %{} = details}}), do: details
  defp error_details(_result), do: %{}

  defp effects?(nil = _attempt, ledger, token), do: ledger.commit_token == token

  defp effects?(attempt, ledger, token),
    do: effects_in_attempt?(attempt) or ledger.commit_token == token

  defp effects_in_attempt?(nil), do: false
  defp effects_in_attempt?(%{mutations: n, commit?: commit?}), do: n > 0 or commit?

  defp error_string(%{error: reason}) when is_binary(reason), do: reason
  defp error_string(%{error: reason}), do: inspect(reason)
end
