defmodule JidoClaw.FrontDoor do
  @moduledoc """
  The single shared front door (AR-2 §8/§14, Phase 3c): the one decision point
  every user turn passes through after the user message is recorded.

  `decide/2` runs AR-8 triage once (a fail-safe `JidoClaw.Triage.classify/2`
  call — never a spawned worker) and picks a route:

    * `{:inline, verdict}` — `talk`/`sketch` (incl. a triage failure degraded to
      `talk`): the turn stays on today's inline agent path, byte-for-byte unchanged.
    * `{:composer, {:ok, resp}}` — a `code`/`system` verdict whose composer run
      started; `resp.message` is the assistant ack.
    * `{:composer, {:error, resp}}` — a `code`/`system` verdict whose run **failed
      to start**: a bounded error ack. **This is NOT a fall-through to the inline
      agent** (which has write/run/git tools) — a confident change verdict whose run
      won't start must not be silently handed to the mutation-capable chat agent (P1).

  This is the only **user-turn** caller of `RouteComposer.create_parent_run/1` /
  `ensure_started/2` (boot recovery, `workflow_recovery.ex`, also calls
  `ensure_started`). Stickiness is per-turn re-classification + recent history
  (faithful to Alp River): the prior path is observability/cold-start only, never
  read to decide — so a parked `talk` flips to `code` on "do it" because the fresh
  verdict sees the prior proposal + "do it" in the same prompt.

  ## `ctx`

  A plain map the turn seams build, carrying the turn's scope:
  `:tenant_id`, `:session_id`, `:session_uuid`, `:workspace_id`, `:workspace_uuid`,
  `:project_dir`, `:user_id`, `:actor`, `:agent_id`, `:agent_template`. Required for
  a composer launch: `:tenant_id` + an actor (falls back to `Actor.system/1`).
  """

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Conversations.Session, as: ConversationsSession
  alias JidoClaw.Error
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.Session.Worker, as: SessionWorker
  alias JidoClaw.Triage
  alias JidoClaw.Triage.Verdict

  @history_window 6
  @preview_max 120
  @default_sensitive_deadline_ms 1_800_000

  # Verdict signal atom → composer topic string (the catalog's wire vocabulary).
  @signal_topics %{
    ambiguous: "ambiguous",
    bug: "bug",
    novel_domain: "novel-domain",
    multi_file: "multi-file",
    auth_surface: "auth-surface",
    secrets: "secrets",
    perms_change: "perms-change",
    destructive_op: "destructive-op",
    irreversible: "irreversible",
    needs_tests: "needs-tests",
    significant_build: "significant-build",
    scope_shift: "scope-shift"
  }

  @type ack :: %{path: Verdict.path(), parent_run_id: String.t(), message: String.t()}
  @type error_ack :: %{path: Verdict.path(), message: String.t()}

  @doc """
  Triage the turn and route it. See the module doc for the three return tags.
  """
  @spec decide(String.t(), map()) ::
          {:inline, Verdict.t()}
          | {:composer, {:ok, ack()}}
          | {:composer, {:error, error_ack()}}
  def decide(message, ctx) when is_binary(message) and is_map(ctx) do
    history = recent_history(ctx, message)
    # classify/2 is the fail-safe boundary, so this hard-matches `{:ok, %Verdict{}}`.
    {:ok, %Verdict{} = verdict} = Triage.classify(message, history: history)
    persist_path(ctx, verdict.path)

    if Verdict.composer?(verdict) do
      {:composer, start_composer(message, verdict, ctx)}
    else
      {:inline, verdict}
    end
  end

  # ---------------------------------------------------------------------------
  # Composer launch (the Option-A seed)
  # ---------------------------------------------------------------------------

  defp start_composer(message, %Verdict{} = verdict, ctx) do
    # `intent` is load-bearing AND must be non-empty: `planner` requires the
    # `intent` artifact and the router's availability is key-presence based, so a
    # blank/nil intent would falsely satisfy the requirement and run `planner`
    # blind. Use the verdict's crisp intent when present, else the raw message.
    intent = present(verdict.intent) || message
    path = verdict.path
    sensitive? = :secrets in verdict.signals

    # `:secrets` ∈ signals → mark_sensitive/2 merges sanitize + a bounded deadline
    # (a direct call, not a one-step pipe — Credo.Readability.SinglePipe).
    opts =
      mark_sensitive(
        [
          tenant: Map.fetch!(ctx, :tenant_id),
          actor: actor(ctx),
          name: "composer",
          catalog: Catalog.all(),
          # "plan-needed" is always seeded (triage's catalog publish that `planner`
          # subscribes — without it the route is empty and falsely converges).
          live:
            Enum.uniq(
              ["request-received", to_string(path), "plan-needed"] ++ mapped_signals(verdict)
            ),
          # FULL intent stored in the artifact; the ack shows only a capped preview.
          artifacts: %{"request" => %{"seed" => message}, "intent" => %{"triage" => intent}},
          # Option (A): seed `triage` as already-run so the composer never asks
          # WaveBuilder to build the non-executable `{:seed, _}` stage.
          ran: ["triage"],
          context: composer_context(ctx),
          # Front-door launch cleans its own orphan (boot recovery does not — 3b).
          terminalize_on_failure?: true,
          premises: %{"path" => to_string(path), "est_size" => to_string(verdict.est_size)}
        ],
        sensitive?
      )

    with {:ok, parent} <- composer().create_parent_run(opts),
         {:ok, _pid} <- composer().ensure_started(opts, parent) do
      {:ok,
       %{
         path: path,
         parent_run_id: parent.id,
         message: ack_message(path, intent, parent.id, sensitive?)
       }}
    else
      {:error, reason} ->
        # P1 SAFETY: a confident code/system verdict whose run won't start does NOT
        # fall through to the mutation-capable inline agent. The ack is a SHORT,
        # STABLE string (this path bypasses the tool redaction/shaping pipeline, so
        # never `inspect(reason)` into it); the detail is logged via a SUMMARIZED
        # (payload-dropping) reason — the global LogRedactor is belt-and-suspenders.
        Logger.warning("[FrontDoor] composer launch failed: #{Error.summarize_reason(reason)}")

        {:error,
         %{
           path: path,
           message:
             "I classified this as a #{path} change but couldn't start the run " <>
               "(it's been logged). It was not run through the chat agent — please retry."
         }}
    end
  end

  # Map the verdict's early signals to composer topics, intersected with the
  # `triage` stage's declared `publishes` so the seeded emission is coherent with
  # its catalog contract.
  defp mapped_signals(%Verdict{signals: signals}) do
    publishes = MapSet.new(Catalog.get("triage").publishes)

    signals
    |> Enum.map(&Map.get(@signal_topics, &1))
    |> Enum.filter(fn topic -> not is_nil(topic) and MapSet.member?(publishes, topic) end)
  end

  # The atom-keyed scope subset the composer threads into every wave (and persists
  # JSON-safe for recovery). Nils dropped so the persisted subset stays clean.
  # `workspace_id` is included — `AgentRunner` otherwise falls back to `"wf_<tag>"`.
  defp composer_context(ctx) do
    %{
      project_dir: Map.get(ctx, :project_dir),
      tenant_id: Map.get(ctx, :tenant_id),
      session_id: Map.get(ctx, :session_id),
      session_uuid: Map.get(ctx, :session_uuid),
      workspace_id: Map.get(ctx, :workspace_id),
      workspace_uuid: Map.get(ctx, :workspace_uuid),
      user_id: Map.get(ctx, :user_id),
      agent_id: Map.get(ctx, :agent_id),
      agent_template: Map.get(ctx, :agent_template)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp actor(ctx) do
    Map.get(ctx, :actor) || Actor.system(Map.fetch!(ctx, :tenant_id))
  end

  # The composer launcher, behind a seam (the `:ask_runtime` idiom) so a test can
  # force a `create_parent_run` / `ensure_started` failure and assert the front
  # door's bounded error ack + P1 no-fall-through, without a real composer.
  defp composer, do: Application.get_env(:jido_claw, :front_door_composer, RouteComposer)

  # ---------------------------------------------------------------------------
  # Recent history + stickiness persistence
  # ---------------------------------------------------------------------------

  # The current user message is already persisted (the seam adds it before
  # `decide/2`), so bound to the last few turns first, then drop the trailing dup;
  # `Prompt.user` re-appends the current turn last.
  defp recent_history(ctx, message) do
    ctx
    |> safe_get_messages()
    |> Enum.take(-(@history_window + 1))
    |> drop_trailing_current(message)
  end

  defp safe_get_messages(ctx) do
    with tenant when is_binary(tenant) <- Map.get(ctx, :tenant_id),
         session_id when is_binary(session_id) <- Map.get(ctx, :session_id) do
      SessionWorker.get_messages(tenant, session_id)
    else
      _ -> []
    end
  rescue
    # reach:disable-next-line bare_rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp drop_trailing_current(history, message) do
    case Enum.reverse(history) do
      [%{role: "user", content: ^message} | rest] -> Enum.reverse(rest)
      _other -> history
    end
  end

  # Best-effort observability / cold-start: store the latest verdict path under
  # `metadata["last_triage_path"]` as a STRING. Never fails the turn.
  defp persist_path(ctx, path) do
    with sid when is_binary(sid) <- Map.get(ctx, :session_uuid),
         tenant when is_binary(tenant) <- Map.get(ctx, :tenant_id),
         {:ok, session} <- ConversationsSession.by_id(sid, tenant: tenant, actor: actor(ctx)) do
      ConversationsSession.set_triage_path(session, to_string(path),
        tenant: tenant,
        actor: actor(ctx)
      )
    end

    :ok
  rescue
    # reach:disable-next-line bare_rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Small helpers
  # ---------------------------------------------------------------------------

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

  defp preview(text) do
    case String.slice(text, 0, @preview_max) do
      ^text -> text
      sliced -> sliced <> "…"
    end
  end

  # `:secrets` ∈ signals → mark sensitive + a bounded deadline. The scrubber then
  # redacts derived plaintext in every durable sink and the deadline caps secret-state
  # lifetime. `create_parent_run` rejects a marked run with no positive `:deadline_ms`
  # (validate_sensitive_deadline/2), so both are set together; a non-secrets run is
  # returned unchanged (unmarked, unbounded — today's behavior).
  defp mark_sensitive(opts, true),
    do:
      Keyword.merge(opts, sanitize_sensitive_context: true, deadline_ms: sensitive_deadline_ms())

  defp mark_sensitive(opts, false), do: opts

  defp sensitive_deadline_ms do
    Application.get_env(:jido_claw, :triage_sensitive_deadline_ms, @default_sensitive_deadline_ms)
  end

  # A sensitive run's ack must NOT echo the intent: marking the run sensitive scrubs
  # durable sinks, but the ack string itself bypasses that pipeline and goes straight
  # to the surface, so a secret-bearing intent could leak through preview/1.
  defp ack_message(path, _intent, run_id, true),
    do: "Starting a sensitive #{path} run (run #{run_id})."

  defp ack_message(path, intent, run_id, false),
    do: "Starting a #{path} run for: #{preview(intent)} (run #{run_id})."
end
