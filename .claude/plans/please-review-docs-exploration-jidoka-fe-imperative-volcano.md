# T2-1 — Conversation-Ownership Handoff (v1) — Revised

## Context

Today, routing decisions in jido_radclaw happen only at *spawn time*: the REPL boots a single `JidoClaw.Agent` ("main") and every chat turn dispatches to that pid. The swarm tools (`SpawnAgent`/`GetAgentResult`) implement request/response — the parent stays in charge.

The doc `docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` calls out T2-1 as a genuinely new capability: a worker can decide "this isn't my job, route to a different template for the rest of the conversation," and the next user turn transparently lands on the new owner until cleared. The Trace surface (T1-1) already wires `[:jido_claw, :handoff, :event]` (`lib/jido_claw/trace/collector.ex:103`).

This plan was reviewed and several P1/P2/P3 issues identified. Revisions address: (1) session identity ambiguity, (2) `/reset` metadata clearing, (3) cold-start hydration in the wrong Worker callback, (4) **lack of context transfer to the new worker** (Jido ReAct builds turns from in-memory `AIContext`, not Postgres), (5) Ash tenant/actor on policy calls, (6) REPL display/poll threading, (7) AgentTracker scope, (8) template validation source-of-truth, (9) stale-metadata recovery, (10) telemetry via `Trace.emit/3`, plus plan hygiene.

## Design Decisions (from user)

| Axis | v1 | Rationale |
|---|---|---|
| Scope | Main + opt-in workers | Tool module added to `JidoClaw.Agent.tools` only; workers don't expose Handoff in v1 — opt-in is "add `JidoClaw.Tools.Handoff` to that worker's tool list" later. No macro plumbing. |
| Forward-context policy | Defer to T2-3 | v1 forwards public `tool_context` only; `:public/:none/{:only}/{:except}` knob is T2-3. |
| Reset | `/reset` REPL command | New `/reset` slash command. No Worker-termination cleanup. |
| Persistence | Registry + `Session.metadata` mirror | Hot path in-memory; durable mirror in `Session.metadata["current_agent_template"]`. Hydrated when the Worker receives its `session_uuid`. |
| Tool return | `{:ok, result_map}` | Not Jidoka's `{:error, {:handoff, _}}`. Registry mutation is the only state change that matters for routing; tool description tells the LLM "last action of this turn." Reconsider in v2 if LLM proves chatty. |

## Session identity — two ids, two purposes

jido_radclaw has two session identifiers (see `lib/jido_claw/tool_context.ex:14`):

* `runtime_session_id` (`:session_id` in `ToolContext`) — string key used by `Session.Worker` `{:via, Registry, {JidoClaw.SessionRegistry, {tenant_id, session_id}}}`, the REPL's `state.session_id`, and `Session.Worker.add_message/5`.
* `session_uuid` (`:session_uuid` in `ToolContext`) — Ash UUID, primary key of `Conversations.Session`, used for all `Session.*`, `Message.*`, and `RequestCorrelation.*` Ash calls.

**The handoff struct and registry must carry both.** The Registry is keyed by `{tenant_id, runtime_session_id}` (matching the dispatch path's available state). All Ash calls use `session_uuid`. Every emission, log line, and Trace event includes both as `:session_id` and `:conversation_id` respectively (the Trace surface canonically uses `:conversation_id` for the durable identity, per `Trace.emit/3` examples).

## Architecture

```
User typed line
      │
      ▼
REPL handle_message  /  JidoClaw.run_chat_turn
      │
      ▼
Router.resolve_session_owner(tenant_id, runtime_session_id, session_uuid, default_pid, actor,
                              project_dir: …, session_record: …,
                              default_agent_id: …)
      │  • Registry.owner(tenant_id, runtime_session_id)
      │      nil → metadata fallback (Session.by_id(session_uuid, tenant: …, actor: …))
      │             present → rehydrate registry, return worker pid + template
      │             absent  → {default_pid, "main"}
      │      stale-template (Templates.get/1 fails) → log, clear registry+metadata, fall back to main
      │  • After start_agent succeeds: idempotently inject system prompt
      │    (Startup.inject_system_prompt(pid, project_dir, session_record))
      │    and mark `prompt_injected?: true` on the Registry owner so repeated turns skip it.
      │  • Returns {routed_pid, routed_template, routed_agent_id,
      │              first_post_handoff?, owner_struct_or_nil}
      ▼
maybe_build_preamble(routed_template, first_post_handoff?, owner, history_before_this_turn)
      │  • If first_post_handoff?: build a delimited preamble from handoff.message/summary
      │    + recent Session.Worker history (read BEFORE the current user message is appended)
      │  • Else: preamble = ""
      ▼
Session.Worker.add_message(:user, raw_user_message, request_id)   ← durable history captures
                                                                     the user's RAW input
      ▼
prepared = prepare_user_message(raw_user_message, state.strategy)   ← existing REPL helper
                                                                     applies strategy-specific
                                                                     hints (e.g. /strategy)
      ▼
Agent.ask(routed_pid, preamble <> prepared,                        ← LLM receives preamble +
          tool_context: ToolContext.build(...                        strategy-prepared message
                          :agent_id => routed_agent_id,             ← from Router (no recompute)
                          :agent_template => routed_template, ...))
      │
      │  LLM may call Tools.Handoff(to_template, message, summary?, reason?)
      ▼
Tools.Handoff.run/2:
   • Reject to_template == "main"
   • Validate Templates.get(to_template) (honors :agent_templates_override hook)
   • Pull tenant_id, runtime_session_id, session_uuid, actor, request_id, agent_id from ctx
   • Build %JidoClaw.Agent.Handoff{}
   • Registry.put_owner(tenant_id, runtime_session_id, handoff_struct, opts)
   • Conversations.Session.set_current_agent_template(session, to_template, tenant: …, actor: …)
   • Session.Worker.add_message(tenant_id, runtime_session_id, :system, "Handed off …", request_id)
   • JidoClaw.Trace.emit(:handoff, %{event: :applied, status: :completed, …}, %{duration_ms: …})
   • {:ok, %{status: "handed_off", to_template: …, message: …}}
      │
      ▼
LLM returns brief acknowledgement → turn ends
      │
Next user turn picks new owner via Router
First-post-handoff prepends preamble (only once); subsequent turns are plain
```

## Slicing — ship order

### Slice 1 — Data + Registry + supervision

**NEW** `lib/jido_claw/agent/handoff.ex`
* `defstruct [:id, :tenant_id, :runtime_session_id, :session_uuid, :from_template, :to_template, :to_module, :message, :summary, :reason, :request_id, :occurred_at, metadata: %{}]`
* `@enforce_keys [:id, :tenant_id, :runtime_session_id, :session_uuid, :to_template, :to_module, :message, :occurred_at]`
* `new/1` constructor; defaults `:id` from `Ecto.UUID.generate/0`, `:occurred_at` from `DateTime.utc_now/0`.

**NEW** `lib/jido_claw/agent/handoff/registry.ex`
* Named GenServer; state: `%{{tenant_id, runtime_session_id} => owner_map}`.
* `owner_map = %{template: String.t(), module: module(), handoff: %JidoClaw.Agent.Handoff{}, updated_at_ms: integer(), preamble_consumed?: boolean(), prompt_injected?: boolean()}`. The registry constructs this map internally from a `%Handoff{}` plus opts — callers never assemble it themselves.
* Public API (single, consistent shape — every mutation takes a `%Handoff{}`; opts toggle the boolean flags for hydration/post-turn marking):
  * `start_link/1`
  * `owner(tenant_id :: String.t(), runtime_session_id :: String.t()) :: map() | nil`
  * `put_owner(tenant_id, runtime_session_id, %JidoClaw.Agent.Handoff{}, opts :: keyword() \\ []) :: :ok` — opts accept `preamble_consumed?: bool` (default `false`) and `prompt_injected?: bool` (default `false`). The registry builds `owner_map` internally. Both `put_owner/3` and `put_owner/4` are public — `put_owner/3` is the Tool's call site (no opts needed; install fresh handoff with both flags false). Both arities go in the Dialyzer checklist.
  * `mark_preamble_consumed(tenant_id, runtime_session_id) :: :ok`
  * `mark_prompt_injected(tenant_id, runtime_session_id) :: :ok`
  * `clear(tenant_id, runtime_session_id) :: :ok`
* Hydration paths (Slice 4 fallback, Slice 8 Worker boot) synthesize a `%Handoff{}` from the metadata template + `Templates.get/1` (with placeholder `message: "<rehydrated>"`, `occurred_at: DateTime.utc_now()`) and call `put_owner` with `preamble_consumed?: true`.

**EDIT** `lib/jido_claw/application.ex` — add `JidoClaw.Agent.Handoff.Registry` to the core children alongside the other Registries (`application.ex:128–129`).

### Slice 2 — Durable mirror on `Conversations.Session`

**EDIT** `lib/jido_claw/conversations/resources/session.ex`
* Mirror `set_prompt_snapshot` (lines 120–135). Use `Ash.Changeset.get_attribute(changeset, :metadata)` for the read (matching the existing pattern, not `get_data/2`):
  ```elixir
  update :set_current_agent_template do
    accept []
    require_atomic? false
    argument :template, :string, allow_nil?: true   # nil clears
    change fn changeset, _ctx ->
      t = Ash.Changeset.get_argument(changeset, :template)
      md = Ash.Changeset.get_attribute(changeset, :metadata) || %{}
      new_md =
        case t do
          nil -> Map.delete(md, "current_agent_template")
          v -> Map.put(md, "current_agent_template", v)
        end
      Ash.Changeset.force_change_attribute(changeset, :metadata, new_md)
    end
  end
  ```
* Add `define :set_current_agent_template, action: :set_current_agent_template, args: [:template]` in `code_interface`.

### Slice 3 — The Tool

**NEW** `lib/jido_claw/tools/handoff.ex` — `use JidoClaw.Tools.Action`
* Use the project's tool wrapper (`lib/jido_claw/tools/action.ex`), **not** raw `Jido.Action`. The wrapper plumbs MCPScope enrichment, error normalization, output redaction, and output truncation around every `run/2` (see `action.ex:36–44`). Direct `Jido.Action` would skip those.
* Zoi schema (matches T1-3 direction):
  * `to_template :: String.t()` — required, trimmed, non-empty
  * `message :: String.t()` — required, trimmed, non-empty
  * `summary :: String.t() | nil` — optional
  * `reason :: String.t() | nil` — optional
  * Validation against the template registry is **runtime**, inside `run/2`, via `Templates.get/1` so test-mode `:agent_templates_override` is honored. The schema doesn't hard-list names (which would fight `templates.ex:62-69`'s override hook).
* `name: "handoff"`, `description: "Hand off conversation ownership to a specialized worker template. This is the LAST action of your turn — after calling, respond with a brief acknowledgement only. The next user turn will be handled by the named template."`
* **Context extraction — defensive both-shape**: Jido ReAct may pass `tool_context` either nested under `context[:tool_context]` (the helper shape used by `JidoClaw.Tools.Reason.base_telemetry_opts/2` at `reason.ex:182–193`) **or** merged flat into the tool execution context (`deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:694`). Read from both, preferring nested:
  ```elixir
  tc = Map.get(context, :tool_context) || context || %{}
  request_id = Map.get(context, :request_id) || Map.get(tc, :request_id)
  tenant_id = Map.get(tc, :tenant_id) || Map.get(context, :tenant_id)
  runtime_session_id = Map.get(tc, :session_id) || Map.get(context, :session_id)
  session_uuid = Map.get(tc, :session_uuid) || Map.get(context, :session_uuid)
  agent_id = Map.get(tc, :agent_id) || Map.get(context, :agent_id)
  agent_template = Map.get(tc, :agent_template) || Map.get(context, :agent_template)
  ```
  `:agent_template` is a new canonical `ToolContext` key (see Slice 4) carrying the *current routed template name* (e.g. `"main"`, `"reviewer"`). Distinct from `:agent_id`, which is an opaque identity string (`"main"` for the bare main agent, `"handoff:<uuid>:<reviewer>"` for routed workers).
* `run/2` pipeline (with explicit tenant/actor on every Ash call):
  1. Trim and validate inputs **inline inside `run/2`**, not via reliance on the Zoi schema. Rationale: tests that call `Handoff.run/2` directly hit the wrapper + inner `run/2`, but NOT `Jido.Exec.run/4`'s schema-validation pass. Doing the trim/non-empty checks inside `run/2` means the validation runs regardless of caller. Use a binary-only guarded helper — **never coerce via `to_string/1`**, which would turn `nil` into `"nil"` and a non-binary `to_template` into a plausible-looking "unknown template" error instead of a required-field error:
     ```elixir
     defp required_trimmed_string(value) when is_binary(value) do
       case String.trim(value) do
         "" -> {:error, :required}
         trimmed -> {:ok, trimmed}
       end
     end

     defp required_trimmed_string(_), do: {:error, :required}
     ```
     Helper returns the bare `:required` atom; the **caller** maps it to a field-specific message — e.g. `"to_template is required"`, `"message is required"` — so the helper stays reusable and the wrapped tool error stays readable. The `JidoClaw.Tools.Action` wrapper then normalizes that string into `%{code, message, details}` at the public boundary. The Zoi schema remains defense-in-depth when invoked through `Jido.Exec.run/4`, but the inline check is the load-bearing one for unit tests and direct callers (e.g., the integration test that establishes ownership directly).
  2. Reject `to_template == "main"` → `{:error, "Cannot hand off to 'main'; use /reset instead."}`.
  3. `case Templates.get(to_template) do {:ok, tmpl} -> ...; {:error, msg} -> {:error, msg} end`.
  4. Extract fields per the context-shape block above. If `session_uuid`, `tenant_id`, **or `runtime_session_id`** is missing → `{:error, "handoff requires an active session"}` (the registry key needs `runtime_session_id`, `Session.Worker.add_message/5` needs it too, and Ash calls need `tenant_id` + `session_uuid`; all three are required for the tool to do its job). **Synthesize `actor` only after `tenant_id` is validated**:
     ```elixir
     actor = Map.get(tc, :actor) || Map.get(context, :actor) ||
             JidoClaw.Authorization.Actor.system(tenant_id)
     ```
  5. Build `%JidoClaw.Agent.Handoff{}` with `from_template: agent_template || "main"` (NOT `agent_id || "main"` — the agent_id may be the opaque `"handoff:…"` form). Workers opting in later (post-v1) get correct `from_template` because `agent_template` is set by the dispatcher.
  6. **Registry mutation first** — `Registry.put_owner(tenant_id, runtime_session_id, handoff)`. If this fails, return `{:error, ...}` (the only mutation whose failure is fatal).
  7. Best-effort metadata mirror — `Session.by_id(session_uuid, tenant: tenant_id, actor: actor)` → `Session.set_current_agent_template(session, to_template, tenant: tenant_id, actor: actor)`. Log + continue on error; the registry remains the source of truth for the current turn.
  8. Best-effort system message — `Session.Worker.add_message(tenant_id, runtime_session_id, :system, "Handed off from <from> to <to_template>: <message>", request_id)`. Log + continue on error.
  9. `JidoClaw.Trace.emit(:handoff, metadata, %{duration_ms: ms})` where `metadata` includes `event: :applied, status: :completed, handoff: to_template, name: "handoff", from_template:, to_template:, conversation_id: session_uuid, tenant_id:, request_id:, agent_id:`. The Trace wrapper stamps `:category`/`:source` and threads correlation IDs (`lib/jido_claw/trace.ex:110-122`).
  10. Return `{:ok, %{status: "handed_off", to_template: to_template, message: message, conversation_id: session_uuid}}`.
* Failure path: emit `JidoClaw.Trace.emit(:handoff, %{event: :error, status: :failed, error: msg, ...}, %{duration_ms: ms})`.

**EDIT** `lib/jido_claw/agent/agent.ex` — append `JidoClaw.Tools.Handoff` to `tools:` (becomes the 31st tool). Workers do not get it.

### Slice 4 — Router + dispatch-time routing

**NEW** `lib/jido_claw/agent/handoff/router.ex` — `resolve_session_owner/6`
```elixir
@type resolve_opts :: [
        project_dir: String.t() | nil,
        session_record: JidoClaw.Conversations.Session.t() | nil,
        default_agent_id: String.t()
      ]

@spec resolve_session_owner(
        tenant_id :: String.t(),
        runtime_session_id :: String.t(),
        session_uuid :: String.t() | nil,
        default_pid :: pid(),
        actor :: map() | nil,
        resolve_opts()
      ) :: {routed_pid :: pid(), routed_template :: String.t(),
            routed_agent_id :: String.t(), first_post_handoff? :: boolean(),
            owner :: map() | nil}
```
Router returns the resolved `routed_agent_id` so the dispatcher doesn't have to recompute it (and risk drifting from Router's `effective_uuid` fallback). For the default path: `routed_agent_id` is `opts[:default_agent_id]` (caller's existing identity — REPL passes `state.agent_id`, `run_chat_turn/8` passes the API agent_id, both typically `"main"` or the session id depending on path). For a routed handoff: `"handoff:#{effective_uuid}:#{owner.template}"`. `default_agent_id` is required in opts; absence raises at the Router level (the caller is responsible for supplying it).
Algorithm (Router internally normalizes `actor = actor || JidoClaw.Authorization.Actor.system(tenant_id)` once `tenant_id` is confirmed present; uses `effective_uuid = session_uuid || owner && owner.handoff.session_uuid` everywhere it needs a UUID — building the worker id, fetching the Session for stale-template metadata clearing, etc.):
1. `Registry.owner(tenant_id, runtime_session_id)` — if non-nil, validate `Templates.get(owner.template)`:
   * Valid → ensure worker pid running. Worker agent id is built from `effective_uuid`. If `effective_uuid` is nil → log + fall through to default (cannot construct a stable id).
     ```elixir
     worker_agent_id = "handoff:#{effective_uuid}:#{owner.template}"

     case ensure_worker_pid(owner.module, worker_agent_id) do
       {:ok, pid} -> ...   # proceed with injection + return
       {:error, _reason} -> ... # log + fall through to default (see fallback note below)
     end
     ```
     where `ensure_worker_pid/2` is a small private helper:
     ```elixir
     defp ensure_worker_pid(module, agent_id) do
       case Jido.whereis(JidoClaw.Jido, agent_id) do
         pid when is_pid(pid) ->
           {:ok, pid}

         nil ->
           case JidoClaw.Jido.start_agent(module, id: agent_id) do
             {:ok, pid} -> {:ok, pid}
             {:error, {:already_started, pid}} -> {:ok, pid}
             {:error, {:already_registered, pid}} -> {:ok, pid}
             {:error, _} = err -> err
           end
       end
     end
     ```
   * After start_agent returns a pid AND `owner.prompt_injected?` is `false`: call `JidoClaw.Startup.inject_system_prompt(pid, project_dir, session_record)`. `session_record` may be `nil` — `Startup.inject_system_prompt/3` accepts that and falls back to a live prompt (see `startup.ex:90`); the only hard requirement is `project_dir`. On `{:ok, _}` (or `:ok`), call `Registry.mark_prompt_injected(tenant_id, runtime_session_id)`. On `{:error, _}`, log + leave the flag `false` so the next turn retries. If `project_dir` is missing in `opts`, skip injection and log a warning (worker falls back to default Jido behavior).
   * Return `{pid, owner.template, worker_agent_id, not owner.preamble_consumed?, owner}`.
   * Invalid (template removed/renamed) → log warning, `Registry.clear`, `Session.set_current_agent_template(session, nil, tenant: …, actor: …)`, fall through to default.
2. No registry entry → if `session_uuid` present, `Session.by_id(session_uuid, tenant: tenant_id, actor: actor)`:
   * `metadata["current_agent_template"]` present and `Templates.get/1` succeeds → synthesize a placeholder `%JidoClaw.Agent.Handoff{}` (per Slice 8's pattern), call `Registry.put_owner(..., handoff, preamble_consumed?: true, prompt_injected?: false)`, then recurse into step 1 once.
   * Present but stale → clear metadata + log, fall back.
3. Otherwise → `{default_pid, "main", default_agent_id, false, nil}` where `default_agent_id = Keyword.fetch!(opts, :default_agent_id)` is read **once at the top** of `resolve_session_owner/6` and raises `KeyError` if absent — the caller is responsible for supplying it. Don't sprinkle `opts[:default_agent_id]` across branches.

**Fallback-on-worker-start-failure semantics**: When `ensure_worker_pid/2` returns `{:error, _}`, Router logs the failure and returns the default 5-tuple **without** mutating the registry (ownership stays installed) and **without** marking `preamble_consumed?`. The next user turn will re-attempt routing — same owner, same template, same effective UUID — and either succeed (worker becomes startable) or fall back again. The Router test must cover this: install ownership pointed at a stub template registered via `:agent_templates_override`. The stub must be a **valid agent module** (so `Templates.get/1` returns `{:ok, ...}`) whose `start_link/1` returns `{:error, :boom}` (so `JidoClaw.Jido.start_agent/2` fails). Then call Router, assert `{default_pid, "main", default_agent_id, false, nil}`, assert `Registry.owner(...)` is unchanged, assert `preamble_consumed?` is still `false`. If that stub turns out to be awkward to construct (e.g., `Jido.AI.Agent` macros resist a `start_link` override), fall back to adding a small private indirection in Router — e.g., `@start_agent_fun Application.compile_env(:jido_claw, :handoff_start_agent_fun, {JidoClaw.Jido, :start_agent})` — and override it in test config. Prefer the stub module path first; introduce the indirection only if the stub proves brittle.

**EDIT** `lib/jido_claw/cli/repl.ex` `handle_message/2` (lines 316–389)

The user-message append (line 334) must happen AFTER the preamble is built, so the preamble's "recent history" excludes the current turn's user message. New ordering:
```elixir
defp handle_message(message, state) do
  request_id = Ecto.UUID.generate()

  if state.session_uuid do
    JidoClaw.register_correlation(request_id, state.session_uuid, state.tenant_id, state.workspace_uuid, nil)
  end

  Stats.track_message(:user)
  Display.reset_mode()
  Display.exit_input_mode()
  Display.start_thinking()

  prepared_raw = prepare_user_message(message, state.strategy)

  actor = Actor.system(state.tenant_id)
  session_record = fetch_session_record(state)   # helper; nil if uuid missing — OK,
                                                 # Startup.inject_system_prompt/3 accepts nil
  {routed_pid, routed_template, routed_agent_id, first_post_handoff?, owner} =
    Router.resolve_session_owner(
      state.tenant_id, state.session_id, state.session_uuid, state.agent_pid, actor,
      project_dir: state.cwd, session_record: session_record,
      default_agent_id: state.agent_id
    )

  # 1. Build preamble from history-BEFORE-this-turn (Session.Worker has not yet
  #    been told about the current user message).
  preamble =
    if first_post_handoff?,
      do: Router.build_preamble(state.tenant_id, state.session_id, owner),
      else: ""

  # 2. Append the *raw* user message to Postgres history (unchanged from today's
  #    semantics: durable history captures what the user typed, not the preambled
  #    variant the LLM sees).
  Worker.add_message(state.tenant_id, state.session_id, :user, message, request_id)

  # 3. Build tool_context with the ROUTED agent_id and routed agent_template, so
  #    traces and telemetry attribute work to the routed worker (not "main") and
  #    so Tools.Handoff (and any future tools that opt in to workers) can derive
  #    `from_template` cleanly without parsing the opaque agent_id string.
  #    NOTE: routed_agent_id comes FROM the Router (Slice 4 spec) so the dispatcher
  #    doesn't drift from Router's `effective_uuid` fallback.
  tool_context =
    JidoClaw.ToolContext.build(%{
      project_dir: state.cwd,
      tenant_id: state.tenant_id,
      session_id: state.session_id,
      session_uuid: state.session_uuid,
      workspace_id: state.session_id,
      workspace_uuid: state.workspace_uuid,
      agent_id: routed_agent_id,
      agent_template: routed_template
    })

  # 4. Send preamble + raw to the LLM via the routed pid.
  prepared_with_preamble = preamble <> prepared_raw

  case Agent.ask(routed_pid, prepared_with_preamble, timeout: 120_000,
                 request_id: request_id, tool_context: tool_context) do
    {:ok, handle} ->
      result = poll_with_tool_display(handle, routed_pid, MapSet.new())   # NOT state.agent_pid
      Display.stop_thinking()
      _ = Recorder.flush(request_id)

      # 5. Mark preamble consumed ONLY when this was a successful first-post-handoff
      #    turn AND the registry still points to the routed template. If the dispatch
      #    failed/timed out/was cancelled, leave the flag false so the next user turn
      #    gets a fresh preamble (the worker never saw it for real).
      case result do
        {:ok, _} when first_post_handoff? ->
          case Registry.owner(state.tenant_id, state.session_id) do
            %{template: ^routed_template} -> Registry.mark_preamble_consumed(state.tenant_id, state.session_id)
            _ -> :ok
          end

        _ ->
          :ok
      end

      # display/format/persist branches as today, using routed_template for display
      # accounting per Slice 6
      ...
  end
end
```
(No dispatcher-side `routed_agent_id_for/3` helper — Router returns `routed_agent_id` directly so the dispatcher and Router can't drift on the `effective_uuid` fallback. If a helper is needed for ergonomics, keep it **private inside Router**.)

**EDIT** `lib/jido_claw.ex` `run_chat_turn/8` (lines 165–219)
* Same reordering: pull `session` (already available — parameter on line 172), `project_dir` (parameter on line 170), `actor` (existing local from line 182). Build preamble BEFORE `SessionWorker.add_message(tenant_id, session_id, :user, message, request_id)` (line 180). Pass the routed pid to `JidoClaw.Agent.ask_sync` (line 202). Pass routed `agent_id` (from Router) AND `agent_template` to `ToolContext.build`.
* **`default_agent_id` for this call site**: the current code (`lib/jido_claw.ex:197`) sets `agent_id: session_id` in the ToolContext build, so the default fall-through must preserve that — pass `default_agent_id: session_id` (the runtime session id local variable in `run_chat_turn/8`). This keeps existing trace/telemetry attribution identical to today's behavior for non-routed turns.
* **Mirror the success-only preamble consumption** here too. After `handle_response/4` returns: if `first_post_handoff?` AND the result was `{:ok, _}` AND `Registry.owner(...).template == routed_template`, call `Registry.mark_preamble_consumed/2`. Otherwise leave the flag false so the next turn re-prepends.

**EDIT** `lib/jido_claw/tool_context.ex`
* Add `:agent_template` to `@canonical_keys` (line 32–42) so `build/1` carries it through. Update the moduledoc "Canonical keys" list to describe it: "`:agent_template` — current routed template name (e.g., `\"main\"`, `\"reviewer\"`); distinct from `:agent_id`, which is the opaque runtime identity."
* **`child/2` semantics**: child agents (spawned via `SpawnAgent`/`SendToAgent`) get `:agent_template` reset to `nil`. They aren't routed by the handoff registry — they're a separate request/response pattern — so inheriting the parent's template would mis-attribute traces and telemetry. Update the `child/2` body (line 72) to add `|> Map.put(:agent_template, nil)` alongside the existing `agent_id` rewrite. **Update `child/2`'s `@doc`** to document the reset: "Resets `:agent_template` to `nil` because spawned children are not routed via the handoff registry; callers that need a specific template attribution should set it explicitly after the call."
* Backward-compatible: existing callers that don't pass `:agent_template` get `nil` (the same shape as any other unspecified canonical key).

**EDIT** `test/jido_claw/tool_context_shape_test.exs`
* Add `:agent_template` to `@canonical_keys` (line 6–16) — the existing test asserts a **stable golden contract** on the key set; adding a canonical field requires updating the contract.
* Add an assertion in the `child/2` describe block: `assert child.agent_template == nil` (verifying the v1 reset decision above), driven by a parent with `:agent_template => "reviewer"`.

**EDIT** `test/jido_claw/tool_context_test.exs` (if it makes specific assertions about field count or unrecognized keys; verify during implementation — at minimum, audit it for any assertion on `Map.keys(ctx)` shape).

### Slice 5 — Context transfer to the new worker (the load-bearing fix)

Jido ReAct builds each turn's prompt from the agent process's in-memory `AIContext` (`deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:669`), not from `Session.Worker` or Postgres. A freshly-started Reviewer worker has an empty context. Persisting a `:system` message to Postgres makes it durable but not LLM-visible.

**v1 approach — message-prefix preamble on first post-handoff turn**:

**NEW** `lib/jido_claw/agent/handoff/router.ex` (continued) — `build_preamble/3`
```elixir
@spec build_preamble(
        tenant_id :: String.t(),
        runtime_session_id :: String.t(),
        owner :: map()
      ) :: String.t()
```
* Returns a delimited preamble string (empty string if owner missing). The caller concatenates this with the user's raw message — keeping construction and concatenation separate so the dispatcher can also append the raw message to the durable history independently.
* Called **before** `Session.Worker.add_message(:user, ...)` in the dispatcher, so `Session.Worker.get_messages(tenant_id, runtime_session_id)` returns history-before-this-turn (the current user message has not yet been written). Bounded — last N=10, drop `:tool_call`/`:tool_result` rows, keep `:user`/`:assistant`/`:system`.
* Format:
  ```
  [HANDOFF CONTEXT — you have just been assigned this conversation.
  Handoff reason: <owner.handoff.reason || "not provided">
  Handoff summary: <owner.handoff.summary || "not provided">
  Previous turn from handing-off agent (<owner.handoff.from_template>): <owner.handoff.message>

  Recent conversation history (most recent last):
  <user|assistant>: <content>
  …
  END HANDOFF CONTEXT]

  ```
* Total preamble bounded to ~4_000 chars (mirrors `max_summary_chars` from the Compactor config). Truncate the conversation-history window first if over budget; keep the handoff message/summary intact.
* Idempotency: pure function over the registry owner + Session.Worker history. The dispatcher marks `preamble_consumed?` after dispatch succeeds (Slice 4 wiring).

**Future v1.5 alternative (out of scope here)**: register a per-worker `Jido.AI.Reasoning.ReAct.RequestTransformer` (same hook the Compactor uses, see `JidoClaw.Reasoning.Compactor.RequestTransformer`) that injects the preamble at projection time without modifying the user-visible message. Cleaner but a larger surface; defer.

**Test for this slice** is in Slice 10 — load a fresh worker pid, drive a single turn after a handoff, assert the message reaching the LLM (via a mocked provider) contains the preamble; drive a second turn, assert no preamble.

### Slice 6 — REPL display + AgentTracker scope

Slice 4 already swaps `state.agent_pid` for `routed_pid` in `poll_with_tool_display`. This slice covers the remaining display surfaces and explicitly defers tracker integration.

**EDIT** `lib/jido_claw/cli/repl.ex`
* Display accounting around line 434 (`"main"` hardcoded for the active agent label) → use `routed_template`. Re-read the exact symbol during implementation (likely a `Display.set_active_agent("main")`-style call).
* Any other place under `lib/jido_claw/cli/` and `lib/jido_claw/display/` that hardcodes `"main"` for the "active agent" badge — grep `\"main\"` under those trees, update to read the current owner via `Registry.owner/2`.

**Decision on AgentTracker / Session.Worker.set_agent** — the routed worker pid is **not** bound to the Session.Worker or tracked by `AgentTracker` in v1. The Session.Worker's `agent_pid` stays bound to the main agent (set during REPL boot via `bind_agent_to_worker` at `repl.ex:211`). Rationale:
* The handoff worker is short-lived (started lazily, may die between turns and get restarted idempotently).
* `AgentTracker.register("main", pid, nil, nil)` is for top-level session-owning agents; the handoff worker isn't that.
* `/status` and crash tracking remain pointed at main — acceptable v1 trade-off.

v2 may promote the handoff worker to a tracked first-class binding. Flag in the module docs that v1 has this asymmetry on purpose.

### Slice 7 — `/reset` command + public API

**EDIT** `lib/jido_claw.ex` — add public APIs:
```elixir
@spec handoff_owner(tenant_id :: String.t(), runtime_session_id :: String.t()) :: map() | nil
def handoff_owner(tenant_id, runtime_session_id),
  do: JidoClaw.Agent.Handoff.Registry.owner(tenant_id, runtime_session_id)

# Registry-only reset. Use when session_uuid is unknown/lost.
@spec reset_handoff(String.t(), String.t()) :: :ok
def reset_handoff(tenant_id, runtime_session_id),
  do: JidoClaw.Agent.Handoff.Registry.clear(tenant_id, runtime_session_id)

# Full reset: registry + durable metadata. Preferred when session_uuid is known.
@spec reset_handoff(String.t(), String.t(), String.t() | nil, map() | nil) :: :ok
def reset_handoff(tenant_id, runtime_session_id, session_uuid, actor)
    when is_binary(tenant_id) and is_binary(runtime_session_id) do
  :ok = JidoClaw.Agent.Handoff.Registry.clear(tenant_id, runtime_session_id)

  if is_binary(session_uuid) do
    actor = actor || JidoClaw.Authorization.Actor.system(tenant_id)
    case JidoClaw.Conversations.Session.by_id(session_uuid, tenant: tenant_id, actor: actor) do
      {:ok, session} ->
        _ = JidoClaw.Conversations.Session.set_current_agent_template(
              session, nil, tenant: tenant_id, actor: actor
            )
        :ok
      _ -> :ok
    end
  else
    :ok
  end
end
```

**EDIT** `lib/jido_claw/cli/commands.ex`
* New `def handle("/reset", state)` clause:
  ```elixir
  actor = JidoClaw.Authorization.Actor.system(state.tenant_id)
  JidoClaw.reset_handoff(state.tenant_id, state.session_id, state.session_uuid, actor)
  IO.puts("  \e[2mHandoff ownership cleared. Next turn goes to main.\e[0m")
  {:ok, state}
  ```
* `/clear` (line 44) is untouched — it remains the screen-clear command.

**EDIT** `lib/jido_claw/cli/branding.ex` — add `/reset` to `help_text/0` near `/clear`.

### Slice 8 — Cold-start hydration (from `set_session_uuid`, not `:load`)

**EDIT** `lib/jido_claw/platform/session/worker.ex`
* The user is correct: `Session.Supervisor.start_session/3` starts the worker *without* `session_uuid` (`supervisor.ex:11–14`), so `handle_continue(:load, %{session_uuid: nil} = state)` (line 149) short-circuits. Hydration happens later when `handle_call({:set_session_uuid, uuid}, …)` fires (line 235).
* Modify the `handle_call({:set_session_uuid, uuid}, _from, %{session_uuid: nil} = state)` clause (line 235):
  ```elixir
  def handle_call({:set_session_uuid, uuid}, _from, %{session_uuid: nil} = state) do
    messages = load_messages(uuid, state.tenant_id, state.actor)
    seed_handoff_from_metadata(state.tenant_id, state.id, uuid, state.actor)   # NEW
    {:reply, :ok, %{state | session_uuid: uuid, messages: messages}, @idle_timeout}
  end
  ```
* `seed_handoff_from_metadata/4` lives next to it in the same module (private helper):
  * Reads `Session.by_id(uuid, tenant: tenant_id, actor: actor)`.
  * If `metadata["current_agent_template"]` is non-nil and `Templates.get/1` succeeds, synthesize a placeholder `%JidoClaw.Agent.Handoff{}` (template + module from `Templates.get/1`, `message: "<rehydrated>"`, `from_template: "<rehydrated>"`, `session_uuid: uuid`, `runtime_session_id:`, `tenant_id:`, `occurred_at: DateTime.utc_now()`) and call `Registry.put_owner(tenant_id, runtime_session_id, handoff, preamble_consumed?: true)`. Original handoff data is gone across restart; we honor the metadata for routing but skip the preamble — first post-restart user turn just lands on the worker raw.
  * If `Templates.get/1` fails (stale template), clear metadata, log a warning, do nothing else.
* Defense-in-depth — `Router.resolve_session_owner/6` ALSO falls back to metadata when the Registry is empty (Slice 4). This handles the race where a `run_chat_turn` arrives before the Worker has been told its `session_uuid`.

### Slice 9 — System prompt update

**EDIT** `priv/defaults/system_prompt.md`
* Change `## Tool Catalog (30 tools)` → `## Tool Catalog (31 tools)` (the regex check at `lib/mix/tasks/jidoclaw.system_prompt.check.ex:46` would otherwise fail).
* Add a new `### Handoff (1 tool)` section, positioned after `### Swarm Orchestration (5 tools)`:
  ```
  **handoff** — Transfer conversation ownership to a specialized worker template.
  - Parameters: `to_template` (one of coder/reviewer/researcher/refactorer/verifier/test_runner/docs_writer), `message` (rationale visible to the next worker), `summary` (optional one-line summary), `reason` (optional explanation).
  - Use when: the remaining work is squarely a specialist's job (e.g., the user wants a code review, not new code).
  - This MUST be the LAST tool call in your turn. After calling, respond with a brief one-line acknowledgement only.
  - The next user turn will be routed to the chosen worker, which receives a bounded handoff preamble (your message/summary + recent history). Run `/reset` to return ownership to main.
  ```
* Add a row to the "Tool Selection Quick Reference" table: `| Hand off conversation to specialist | handoff (then stop talking) |`.

**Note**: per `AGENTS.md`, `priv/defaults/system_prompt.md` is created from defaults during setup but **not** auto-synced. The local `.jido/system_prompt.md` may already exist; the user must manually copy the updated default. Flag in the post-implementation summary, do not auto-overwrite.

### Slice 10 — Tests

`mix precommit` runs the full suite. All Ash calls in tests must pass `tenant:` and `actor:` as the production code does — see `lib/jido_claw/conversations/resolver.ex:100` for the canonical pattern.

**NEW** `test/jido_claw/agent/handoff/registry_test.exs`
* Round-trip: `put_owner → owner → mark_preamble_consumed → owner.preamble_consumed? == true → clear → owner == nil`.
* Isolation: `{"acme", "s1"}` vs `{"acme", "s2"}` vs `{"other", "s1"}` — three independent slots.
* `mark_preamble_consumed` on absent entry is no-op.
* `clear` of absent entry returns `:ok`.

**NEW** `test/jido_claw/tools/handoff_test.exs`

Important: `JidoClaw.Tools.Action`'s `__before_compile__` wraps `run/2` with `JidoClaw.Tools.Error.normalize_result/1` (see `tools/error.ex:77–85`), which turns any `{:error, reason}` from inner `run/2` into `{:error, %{code:, message:, details:}}` at the public boundary. Tests must assert against the wrapped shape:
```elixir
assert {:error, %{message: msg, code: code}} = Handoff.run(params, context)
assert msg =~ "Cannot hand off"
```

* Happy path (Coder → Reviewer): tool returns `{:ok, %{status: "handed_off", to_template: "reviewer", conversation_id: <uuid>}}`. Registry has the owner. `Session.metadata["current_agent_template"] == "reviewer"`. A `:system` message exists in `Message.for_session(session_uuid)`.
* Reject `to_template: "main"` → `{:error, %{message: msg}} = ..., assert msg =~ "Cannot hand off"`. Registry untouched.
* Unknown template → `{:error, %{message: msg}} = ..., assert msg =~ "Unknown template"`. Honors `:agent_templates_override` (set in test config; assert override is consulted).
* Missing `session_uuid` in context → `{:error, %{message: msg}} = ..., assert msg =~ "handoff requires an active session"`. Registry untouched.
* Missing `tenant_id` → same wrapped-error shape.
* Missing `runtime_session_id` (`tc[:session_id]`) → same wrapped-error shape. Registry untouched.
* Empty `message` → inline `required_trimmed_string/1` validation surfaces through the wrapper as `{:error, %{message: msg}} where msg =~ "required"`. Test also covers `message: nil` (binary guard rejects non-binaries) and whitespace-only `message: "   "` (trim → empty → rejected). If a separate test of Zoi-level rejection is desired, write it through `Jido.Exec.run/4` — but the public `Handoff.run/2` path is fully covered by the inline check.
* **Both context shapes**: drive the tool against (a) a context with `tool_context: %{tenant_id: ..., session_id: ..., ..., agent_template: "main"}` (nested — Reason helper shape) AND (b) a context with the same fields flat at the top level (Jido ReAct merge shape). Both must succeed and `from_template` must come from `agent_template` in both cases (not from `agent_id`).
* Telemetry round-trip: attach a `:telemetry` handler in `setup`, assert `[:jido_claw, :handoff, :event]` lands with `metadata.event == :applied, metadata.status == :completed, metadata.handoff == "reviewer", metadata.conversation_id == session_uuid`.
* Trace surface: after the tool runs, call `JidoClaw.TraceTestHelpers.sync_collector/0` (existing helper at `test/support/jido_claw/trace_test_helpers.ex` — `Trace.Collector` ingests asynchronously, so tests must sync the mailbox before reading), then `JidoClaw.Trace.for_request(target, request_id)` and assert the trace events include `category: :handoff, event: :applied`.
* (Dropped: "stub `Session.set_current_agent_template` to fail." The direct module call isn't stub-able without adding an injection seam in production code. Best-effort behavior is covered in the integration test via a real Ash error path — e.g., calling the tool with an `actor` that doesn't satisfy the policy, which makes the metadata write fail while the registry mutation succeeds.)

**NEW** `test/jido_claw/agent/handoff/router_test.exs`
* No owner → `{default_pid, "main", default_agent_id, false, nil}` (`default_agent_id` is the value passed in `opts`).
* Owner present → router starts worker pid (or reuses existing), returns `{worker_pid, "reviewer", "handoff:<uuid>:reviewer", true, owner}` for first call; `mark_preamble_consumed`; subsequent call returns `first_post_handoff? == false`.
* System-prompt injection happens once per `(session_uuid, template)` — assert via the existing telemetry event `[:jido_claw, :agent, :prompt_injected]` (emitted by `Startup.inject_system_prompt/3` on success, see `lib/jido_claw/startup.ex:83,99`). Attach a counting handler in `setup`; after the first router call for a new owner, assert `count == 1` and `Registry.owner(...).prompt_injected? == true`; after a second router call for the same owner, assert `count == 1` (no re-emit) and the flag is still `true`. Less brittle than reaching into `Jido.AgentServer.state/1`. No mocking framework needed — `:meck` is not a project dependency.
* Stale template (Registry has `template: "legacy"`, `Templates.get("legacy")` fails) → router clears registry + metadata, returns default.
* Cold-start: Registry empty, `Session.metadata["current_agent_template"] == "reviewer"` → router re-seeds registry with `preamble_consumed?: true`, returns the full 5-tuple `{worker_pid, "reviewer", "handoff:<uuid>:reviewer", false, owner}` (note `first_post_handoff? == false` because preamble is marked consumed during cold-start synthesis; `routed_agent_id` is the worker form).
* `build_preamble/3`: bounded length (≤4_000 chars after truncation); contains handoff message + summary + history window. Concatenation with the raw user message is exercised by the dispatcher tests, not here.

**NEW** `test/jido_claw/conversations/handoff_routing_integration_test.exs` — canonical end-to-end

The load-bearing behavior here is **routing**, not the main agent's LLM picking the right tool. `:agent_templates_override` configures `Templates.get/1`, not the upstream LLM. So:

* Boot a session with `JidoClaw.Session.Supervisor.ensure_session/3`, set `session_uuid` via `Session.Worker.set_session_uuid/3`.
* Establish ownership directly: call `Tools.Handoff.run(%{to_template: "reviewer", message: "Please review the recent diff", summary: "User asked about X"}, build_context(...))` to install the registry/metadata/system-message/trace event. (Direct invocation. Don't try to drive the main agent's LLM here — that's a separate test concern.) Call `JidoClaw.TraceTestHelpers.sync_collector/0` and assert registry + metadata + system message + trace event.
* Drive turn 2: assert the routed pid is the Reviewer worker pid (not main). Capture the prompt sent to the LLM (via mock); assert it starts with the handoff preamble, and that the routed `tool_context.agent_id` is `"handoff:<uuid>:reviewer"` (not `"main"`).
* Drive turn 3: routed pid still Reviewer, but preamble is NOT present (consumed).
* **Failed-dispatch case**: install a fresh handoff owner, then drive a turn that fails (e.g., mock the LLM to return `{:error, :timeout}` or simulate worker crash). Assert `Registry.owner(...).preamble_consumed? == false`. Then drive a successful next turn; assert preamble IS present (the failed turn didn't burn the flag).
* Best-effort metadata path: drive a handoff turn with an `actor` that violates `JidoClaw.Resource`'s tenant policy on the Session update. Assert: tool still returns `{:ok, ...}`, registry has the new owner (registry mutation didn't depend on the actor), metadata write logged as a warning. Covers the dropped "stub to fail" case via a real Ash error.
* Call `JidoClaw.reset_handoff/4(tenant_id, runtime_session_id, session_uuid, actor)`. Assert registry empty + metadata cleared.
* Drive turn 4: routed pid is main again.

**NEW** `test/jido_claw/public_api_handoff_test.exs`
* `function_exported?(JidoClaw, :handoff_owner, 2)` and `:reset_handoff, 2` and `:reset_handoff, 4`.
* `JidoClaw.handoff_owner` returns nil for unknown session.
* `JidoClaw.reset_handoff/2` is registry-only and idempotent.
* `JidoClaw.reset_handoff/4` also clears metadata.

**NEW** `test/jido_claw/platform/session/worker_handoff_hydration_test.exs`
* Pre-seed `Session.metadata["current_agent_template"] = "reviewer"` via direct Ash update.
* Boot a Worker (`Session.Supervisor.start_session`), then call `Worker.set_session_uuid/3`.
* Assert `Registry.owner(tenant_id, runtime_session_id).template == "reviewer"` and `.preamble_consumed? == true`.
* Pre-seed metadata with a stale template name; boot + `set_session_uuid`; assert metadata cleared and warning logged.

### Slice 11 — `mix precommit` gate

Defined in `mix.exs:234–242`:
```
compile --warnings-as-errors
jidoclaw.system_prompt.check     ← tool catalog count + per-tool entries
deps.unlock --unused
format
credo --strict
dialyzer --format short
test
```

Specific concerns this implementation must clear:
* **system_prompt.check** — Slice 9 changes count 30→31 *and* adds the `**handoff**` entry. The check is regex-driven (`~r/^\*\*([a-z0-9_]+)\*\*/m`); the tool's `name/0` from `use JidoClaw.Tools.Action, name: "handoff"` must be lowercase + underscore-safe.
* **credo --strict** — Watch for `Credo.Check.Design.AliasUsage` (alias `JidoClaw.Agent.Handoff.Registry` at top of `Tools.Handoff` and `Router`), `Credo.Check.Readability.ModuleDoc` (every new module needs `@moduledoc`), `Credo.Check.Refactor.CyclomaticComplexity` (keep `run/2` linear).
* **dialyzer** — Provide typespecs for:
  * `Registry.owner/2`, `put_owner/3`, `put_owner/4`, `mark_preamble_consumed/2`, `mark_prompt_injected/2`, `clear/2`
  * `Router.resolve_session_owner/6`, `Router.build_preamble/3`
  * `Handoff.new/1`
  * `Tools.Handoff.run/2 :: {:ok, map()} | {:error, JidoClaw.Tools.Error.t()}` — the wrapper normalizes any inner `{:error, reason}` (string, atom, struct) into the canonical `%{code, message, details}` map. Don't typespec the public function as `{:error, String.t()}`. If you split out a narrower inner helper that returns `{:error, String.t()}` for clarity, mark it **private** (`defp`) so Dialyzer doesn't surface the conflicting public contract.
  * Top-level `JidoClaw.handoff_owner/2`, `reset_handoff/2`, `reset_handoff/4`
* **format** — auto-fix.
* **deps.unlock --unused** — only new code, no new deps.
* **test** — must include MIX_ENV=test runs of every new file in Slice 10. The `ash.setup --quiet` prelude (via `test` alias) seeds the DB; the integration test must use `Ecto.Adapters.SQL.Sandbox` mode (`async: false` for the Session-Worker driven test since it uses a named GenServer).

## Concrete files

**New (10 files)**:
1. `lib/jido_claw/agent/handoff.ex` — struct
2. `lib/jido_claw/agent/handoff/registry.ex` — GenServer
3. `lib/jido_claw/agent/handoff/router.ex` — `resolve_session_owner/6` + `build_preamble/3`
4. `lib/jido_claw/tools/handoff.ex` — `JidoClaw.Tools.Action`
5. `test/jido_claw/agent/handoff/registry_test.exs`
6. `test/jido_claw/agent/handoff/router_test.exs`
7. `test/jido_claw/tools/handoff_test.exs`
8. `test/jido_claw/conversations/handoff_routing_integration_test.exs`
9. `test/jido_claw/public_api_handoff_test.exs`
10. `test/jido_claw/platform/session/worker_handoff_hydration_test.exs`

**Edited (10 files)**:
1. `lib/jido_claw/application.ex` — Registry child spec
2. `lib/jido_claw/conversations/resources/session.ex` — `set_current_agent_template` action + code_interface entry
3. `lib/jido_claw/agent/agent.ex` — append `Tools.Handoff` to `tools:`
4. `lib/jido_claw/tool_context.ex` — add `:agent_template` to `@canonical_keys`; update moduledoc canonical keys list
5. `lib/jido_claw/cli/repl.ex` `handle_message/2` — full rewrite per Slice 4: fetch session record via new `fetch_session_record/1` helper, build preamble BEFORE `Worker.add_message(:user, …)`, rewrite `tool_context.agent_id` AND `tool_context.agent_template` to the routed values, route to `routed_pid` in `Agent.ask` AND `poll_with_tool_display`, swap `routed_template` into display accounting (line 434), and mark `preamble_consumed?` after dispatch
6. `lib/jido_claw.ex` `run_chat_turn/8` — same reordering using existing local `actor`, parameters `project_dir`, `session`; build preamble BEFORE `SessionWorker.add_message(:user, …)` (line 180); rewrite `tool_context.agent_id` AND `tool_context.agent_template`; route to `routed_pid` in `Agent.ask_sync`. Plus new module-level `handoff_owner/2` + `reset_handoff/2` + `reset_handoff/4`
7. `lib/jido_claw/cli/commands.ex` — `/reset` handler
8. `lib/jido_claw/cli/branding.ex` — `/reset` help line
9. `lib/jido_claw/platform/session/worker.ex` — `seed_handoff_from_metadata/4` called from `{:set_session_uuid, uuid}` clause (line 235), not from `handle_continue(:load, ...)`
10. `priv/defaults/system_prompt.md` — count 30→31 + `**handoff**` entry + quick-reference row

**Edited existing tests (1–2 files)**:
1. `test/jido_claw/tool_context_shape_test.exs` — add `:agent_template` to `@canonical_keys` (line 6–16) to keep the stable golden-contract test passing; add a `child/2` assertion that `child.agent_template == nil` for the parent-reset semantics.
2. `test/jido_claw/tool_context_test.exs` (if audit finds key-count or unrecognized-key assertions; verify during implementation).

## Verification

```bash
# Module-level smoke
mix test test/jido_claw/agent/handoff/registry_test.exs
mix test test/jido_claw/agent/handoff/router_test.exs
mix test test/jido_claw/tools/handoff_test.exs
mix test test/jido_claw/platform/session/worker_handoff_hydration_test.exs

# ToolContext canonical-key updates (`:agent_template` addition + child/2 reset)
mix test test/jido_claw/tool_context_shape_test.exs test/jido_claw/tool_context_test.exs

# End-to-end
mix test test/jido_claw/conversations/handoff_routing_integration_test.exs

# Manual REPL drive — smoke scenario only (the integration test is the real gate;
# this depends on the LLM choosing to call `handoff`, which is intentionally not
# automated).
mix jidoclaw
> "Review the recent diff"   # main may call handoff(to_template: "reviewer", ...)
> "Anything to fix in lib/jido_claw/agent.ex?"
# Smoke-check: tool calls show under "reviewer" not "main"; first message included preamble
> /reset
# Output: "Handoff ownership cleared. Next turn goes to main."
> "What's the project structure?"
# Smoke-check: tool calls show under "main"

# Gate
mix precommit
```

The integration test is the load-bearing one — manual REPL drive is for sanity, but `mix precommit` (including full `test`) is the acceptance gate.

## Risks & open considerations

* **LLM doesn't stop after handoff** — Mitigation: tool description + system-prompt entry say "last action of your turn, brief acknowledgement only." If this proves chatty in practice, v2 switches to error-channel termination (Jidoka's pattern).
* **Worker pid lifecycle** — v1 starts a fresh worker pid per `(session_uuid, template)` lazily and never explicitly stops it. Stale pids accumulate (same shape as the existing swarm). v2 can add an idle-timeout via `JidoClaw.AgentTracker`.
* **Cold-start race** — Worker boots → receives `set_session_uuid` → seeds Registry. If a `run_chat_turn` arrives before that, Router's defense-in-depth metadata read covers it.
* **Preamble truncation pathology** — A very long handoff message + summary could squeeze out the conversation history window. Bound: handoff message + summary capped at ~2_000 chars each; history window takes whatever's left up to ~4_000 total. Worth a focused test.
* **Discord/Telegram/MCP** — All enter via `JidoClaw.run_chat_turn/8`, so they get routing automatically. MCP `tools/call` is request-scoped (no conversation memory), so no routing change is needed there.
* **Trace metadata drift** — `lib/jido_claw/trace/collector.ex` is already configured (line 103) to attach `[:jido_claw, :handoff, :event]`. The collector's `normalize_event/4` (`collector.ex:315–354`) reads `:event`, `:status`, and the label key; the emitter must match. Slice 10's telemetry test asserts the event lands in `Trace.list/2` for the request (after `TraceTestHelpers.sync_collector/0`).
* **System-prompt injection failure mode** — `Startup.inject_system_prompt/3` is best-effort. If it returns `{:error, _}`, Router logs and continues — the worker runs without the project-specific prompt. The `prompt_injected?` flag is set on **prompt injection success only**, so a subsequent turn retries injection. This avoids a permanent "missing prompt" state if the first injection raced with worker startup, at the cost of injection running again on retry (idempotent on the worker side). When `session_record` is `nil` (e.g., cold-start before the Session row is fetched), `Startup.inject_system_prompt/3` falls back to a live prompt; the only hard prerequisite is `project_dir`.

## Information I still need from you

None — the four design-decision answers plus the review findings settle everything material.

Two non-blockers I'll surface during implementation if they bite:
1. Tool name: defaulting to `handoff` (matches Jidoka). Could switch to `agent_handoff` if LLM disambiguation matters.
2. Preamble caps: defaulting `max_summary_chars: 4_000` to match the Compactor. Can tune.
