# Codebase Audit Remediation Plan

## Context

A comprehensive audit identified 20 issues at P0-P2 severity across security, Ash Framework
conventions, OTP reliability, and Jido tool patterns. This plan addresses all 20 in a phased
approach, ordered by blast radius: security first, then data layer, then reliability, then
cleanup. P3 items are tracked in `docs/TODO.md` for later.

---

## Phase 1: Security Fixes (P0)

### 1A. Wire ApiKeyAuth into API routes & protect admin/dashboard

**Files:**

- `lib/jido_claw/web/router.ex`
- `lib/jido_claw/web/plugs/require_auth.ex` (new — browser-session auth plug)

**Changes:**

- Add a new pipeline `:api_auth` with `JidoClaw.Web.Plugs.ApiKeyAuth`
- Move `POST /v1/chat/completions` into a scope piping through `:api` + `:api_auth`
- Keep `GET /health` and `POST /webhooks/github` unauthenticated
- Create a new `RequireAuth` plug that checks the browser session using the same helper as
  `LiveUserAuth` — `AshAuthentication.Plug.Helpers.authenticate_resource_from_session/4`
  with `(JidoClaw.Accounts.User, session, :jido_claw, [])` — and halts with 302 redirect to
  `/sign-in` if no user. This is a standard Plug (not LiveView on_mount) so it works for
  controller routes like `ash_admin` and `live_dashboard`.
- Wrap `ash_admin("/admin")` (line 22) in a scope that pipes through `:browser` + a
  pipeline containing the new `RequireAuth` plug
- Wrap `live_dashboard("/live-dashboard")` (lines 77-84) the same way, OR gate behind
  `if Mix.env() == :dev` at compile time
- Additionally, in `chat_controller.ex` (line 12): the User model has no `tenant_id`
  attribute, so we cannot derive tenant from the authenticated user yet. For now, hard-code
  tenant_id to `"default"` instead of trusting the `x-tenant-id` header. The header-based
  tenant selection is a privilege escalation risk since any authenticated user can choose any
  tenant. A real user-to-tenant model is a follow-up task.

### 1B. Add session-based WebSocket authentication

**Files:**

- `lib/jido_claw/web/endpoint.ex` (line 17)
- `lib/jido_claw/web/channels/user_socket.ex`
- `lib/jido_claw/web/channels/rpc_channel.ex`

**Changes:**

- In `endpoint.ex` line 17, change `socket("/ws", JidoClaw.Web.UserSocket, websocket: true)`
  to `socket("/ws", JidoClaw.Web.UserSocket, websocket: [connect_info: [session: @session_options]])`
  — this mirrors how the LiveView socket is configured on line 15
- In `user_socket.ex`, update `connect/3` to authenticate from the session using the same
  helper that `LiveUserAuth` uses (`authenticate_resource_from_session/4`):
  ```elixir
  def connect(_params, socket, connect_info) do
    session = connect_info[:session] || %{}
    case AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
           JidoClaw.Accounts.User, session, :jido_claw, []
         ) do
      {:ok, user} -> {:ok, assign(socket, :current_user, user)}
      :error -> {:error, :unauthorized}
    end
  end
  ```
  Update `id/1` to use a user-based identifier: `"user_socket:#{socket.assigns.current_user.id}"`
- In `rpc_channel.ex`, hard-code tenant_id to `"default"` instead of trusting
  client-supplied `tenant_id` in `sessions.create` and `sessions.sendMessage` (same rationale
  as chat_controller — User has no tenant model yet)

### 1C. Change sign-out from GET to DELETE

**Files:**

- `lib/jido_claw/web/router.ex` (line 44)

**Changes:**

- Change `get("/sign-out", AuthController, :sign_out)` to
  `delete("/sign-out", AuthController, :sign_out)`
- No layout link update needed — there is no sign-out link in `app.html.heex` currently

### 1D. Fix `check_origin` for production

**File:** `config/runtime.exs`

**Changes:**

- In the `config_env() == :prod` block (after line 50), add:
  ```elixir
  host = System.get_env("PHX_HOST", "localhost")
  config :jido_claw, JidoClaw.Web.Endpoint,
    check_origin: ["https://#{host}", "http://#{host}"]
  ```
  This merges with the existing `secret_key_base` config.

### 1E. Add CacheBodyReader for webhooks

**Files:**

- `lib/jido_claw/web/cache_body_reader.ex` (new)
- `lib/jido_claw/web/endpoint.ex` (line 29)
- `lib/jido_claw/web/controllers/webhook_controller.ex` (line 6)

**Changes:**

- Create `CacheBodyReader` module: reads body via `Plug.Conn.read_body/2`, stores raw bytes
  in `conn.private[:raw_body]`, returns the body to Plug.Parsers as normal
- Configure `Plug.Parsers` with `body_reader: {JidoClaw.Web.CacheBodyReader, :read_body, []}`
- Update `WebhookController.github/2` to read from `conn.private[:raw_body]` instead of
  calling `Plug.Conn.read_body(conn)`

### 1F. Fix String.to_atom on external input

**Files and changes:**

1. `lib/jido_claw/network/protocol.ex` (lines 203-204, 212)
   - Replace `String.to_atom("missing_#{key}")` with `{:missing, key}` (tuple error)
   - Replace `String.to_atom("invalid_#{key}")` with `{:invalid, key}`
   - Update any callers that pattern-match on the old atom error format

2. `lib/jido_claw/solutions/solution.ex` (lines 189-201)
   - Replace `normalize_keys/1` with a **whitelist conversion**. The struct accesses these
     atom keys: `:id`, `:problem_signature`, `:solution_content`, `:language`, `:framework`,
     `:runtime`, `:agent_id`, `:tags`, `:verification`, `:trust_score`, `:sharing`,
     `:inserted_at`, `:updated_at`. Build a map of `@known_keys` and convert only those:

     ```elixir
     @known_keys ~w(id problem_signature solution_content language framework
       runtime agent_id tags verification trust_score sharing inserted_at updated_at)a
       |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)

     defp normalize_keys(map) do
       Map.new(map, fn
         {k, v} when is_atom(k) -> {k, v}
         {k, v} when is_binary(k) -> {Map.get(@known_keys, k, k), v}
       end)
     end
     ```

     Unknown string keys are kept as strings (harmless — `Map.get(struct, "unknown")` returns nil).

3. `lib/jido_claw/platform/memory.ex` (lines 103, 216)
   - Define an allowlist of valid memory types:
     ```elixir
     @valid_memory_types %{
       "fact" => :fact, "pattern" => :pattern, "decision" => :decision,
       "preference" => :preference, "context" => :context
     }
     ```
   - Replace `String.to_atom(type)` with `Map.get(@valid_memory_types, type, :fact)`

4. `lib/jido_claw/forge/harness.ex` (lines 759, 801)
   - Line 759 (`recover_extra_sandboxes`): Sandbox names MUST be atoms because
     `Forge.attach_sandbox/3` (forge.ex:60) has a `when is_atom(name)` guard. Use
     `String.to_existing_atom/1` here — sandbox names created during the original session are
     already in the atom table, so `to_existing_atom` will succeed for valid recovery. If it
     raises (corrupted checkpoint data), rescue and skip that sandbox with a warning log.
   - Line 801 (`atomize_spec_keys`): Use `String.to_existing_atom/1`, keep string on failure.
     The spec keys that matter (`:sandbox`, etc.) are already defined as atoms in the codebase.

5. `lib/jido_claw/web/live/folio_live.ex` (line 82) and
   `lib/jido_claw/web/live/setup_live.ex` (line 102)
   - Wrap `String.to_existing_atom/1` calls in a rescue so forged LiveView events return
     `{:noreply, socket}` instead of crashing the LiveView:
     ```elixir
     def handle_event("tab", %{"tab" => tab}, socket) do
       {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
     rescue
       ArgumentError -> {:noreply, socket}
     end
     ```

### 1G. Remove double on_mount in web.ex

**File:** `lib/jido_claw/web.ex` (line 34)

**Change:** Remove `on_mount({JidoClaw.Web.LiveUserAuth, :live_user_optional})` from the
`live_view/0` macro. The router's `live_session` blocks already specify the correct on_mount
per session (`:live_no_user`, `:live_user_optional`, or `:live_user_required`).

---

## Phase 2: Ash Framework (P1)

### 2A. Add code_interface blocks to all resources missing them

Follow the pattern in `Projects.Project` (lines 13-18). Add `code_interface do ... end`
blocks to the **resource modules** (where the existing pattern is).

**Files — 12 resources to add interfaces to:**

1. `lib/jido_claw/folio/inbox_item.ex` — define: `:capture`, `:process`, `:discard`, `:list_unprocessed` (action: `:unprocessed`), `:list_by_user` (action: `:by_user`)
2. `lib/jido_claw/folio/action.ex` — define: `:create`, `:complete`, `:defer`, `:wait`, `:list_next_actions`, `:list_waiting`, `:list_by_context`, `:list_by_project`, `:list_by_user`
3. `lib/jido_claw/folio/project.ex` — define: `:create`, `:complete`, `:defer`, `:reactivate`, `:list_active`, `:list_by_user`
4. `lib/jido_claw/orchestration/workflow_run.ex` — define: `:create`, `:start`, `:await_approval`, `:resume`, `:complete`, `:fail`, `:cancel`, `:list_active`, `:list_by_project`
5. `lib/jido_claw/orchestration/workflow_step.ex` — define: `:create`, `:start`, `:complete`, `:fail`, `:skip`
6. `lib/jido_claw/orchestration/approval_gate.ex` — define: `:create`, `:approve`, `:reject`, `:list_pending_for_run` (action: `:pending_for_run`)
7. `lib/jido_claw/security/secret_ref.ex` — define: `:create`, `:update`, `:get_by_name` (action: `:by_name`), `:list_by_category` (action: `:by_category`)
8. `lib/jido_claw/github/issue_analysis.ex` — define: `:create`, `:update_status`, `:list_by_repo` (action: `:by_repo`), `:get_by_issue` (action: `:by_issue`)
9. `lib/jido_claw/forge/resources/session.ex` — define: `:create`, `:start`, `:update_phase`, `:mark_failed`, `:complete`, `:cancel`, `:set_sandbox_id`, `:list_active`
10. `lib/jido_claw/forge/resources/exec_session.ex` — define: `:start`, `:complete`
11. `lib/jido_claw/forge/resources/checkpoint.ex` — define: `:create`, `:latest_for_session`
12. `lib/jido_claw/forge/resources/event.ex` — define: `:create`, `:list_for_session` (action: `:for_session`)

**Note:** We will NOT refactor callers (e.g. `forge/persistence.ex`) to use the new
interfaces in this pass. The interfaces need to exist and compile first. Caller migration
is a follow-up.

### 2B. Add missing belongs_to relationships

Only where the FK attribute already exists. Use `define_attribute? false` since the column
is already present, and `attribute_writable? true` since existing actions accept the FK
directly.

**Files:**

1. `lib/jido_claw/folio/inbox_item.ex` — Add `relationships do` block:
   - `belongs_to :user, JidoClaw.Accounts.User` (FK: `user_id`)

2. `lib/jido_claw/folio/action.ex` — Add `relationships do` block:
   - `belongs_to :user, JidoClaw.Accounts.User` (FK: `user_id`)
   - `belongs_to :project, JidoClaw.Folio.Project` (FK: `project_id`)

3. `lib/jido_claw/folio/project.ex` — Add to existing `relationships` block:
   - `belongs_to :user, JidoClaw.Accounts.User` (FK: `user_id`)

4. `lib/jido_claw/orchestration/workflow_run.ex` — Add to existing `relationships` block:
   - `belongs_to :user, JidoClaw.Accounts.User` (FK: `user_id`)
   - `belongs_to :project, JidoClaw.Projects.Project` (FK: `project_id`)

5. `lib/jido_claw/orchestration/approval_gate.ex` — Add to existing `relationships` block:
   - `belongs_to :requester, JidoClaw.Accounts.User` (FK: via `source_attribute :requested_by_id`)

6. `lib/jido_claw/security/secret_ref.ex` — Add `relationships do` block:
   - `belongs_to :user, JidoClaw.Accounts.User` (FK: `user_id`)

7. `lib/jido_claw/github/issue_analysis.ex` — Add `relationships do` block:
   - `belongs_to :project, JidoClaw.Projects.Project` (FK: `project_id`)

### 2C. State machine validations, IssueAnalysis.status, and InboxItem.process comment

**Files:**

1. `lib/jido_claw/github/issue_analysis.ex`
   - Change the `status` attribute (line ~75) from `:string` to `:atom` with
     `constraints: [one_of: [:pending, :triaged, :researched, :pr_created, :closed]]`
   - The backing column is already `:text` — Ash stores atom enums as text, so no migration
     needed for column type
   - Update the `:update_status` action (line ~31): its `status` argument should also change
     to `:atom` with matching constraints

2. `lib/jido_claw/orchestration/workflow_run.ex` — Add `validate` to transition actions:
   - `:start` (line 21) — `validate attribute_equals(:status, :pending)`
   - `:await_approval` (line 27) — `validate attribute_equals(:status, :running)`
   - `:resume` (line 32) — `validate attribute_equals(:status, :awaiting_approval)`
   - `:complete` (line 37) — `validate attribute_equals(:status, :running)`
   - `:fail` (line 45) — `validate attribute_in(:status, [:running, :awaiting_approval])`
   - `:cancel` (line 53) — `validate negate(attribute_in(:status, [:completed, :failed, :cancelled]))`
     (`negate/1` and `attribute_in/2` are both in `Ash.Resource.Validation.Builtins`)

3. `lib/jido_claw/folio/inbox_item.ex`
   - `:process` action (line 21): Add a comment explaining the `outcome` argument is
     reserved for future use. Keep the existing constraints exactly as-is
     (`[:action, :project, :reference, :someday, :trash]`):
     ```elixir
     # outcome argument reserved for future routing logic — tracks how the item was resolved
     argument(:outcome, :atom, ...)
     ```
   - Also add: `validate attribute_equals(:status, :inbox)` to prevent double-processing
     (the stored status is `:inbox`, not `:unprocessed` — `:unprocessed` is the read action name)

### 2D. Verification (Phase 2-specific)

After making resource changes:

1. `mix ash.codegen add_code_interfaces_and_relationships` — generate any needed migration/snapshot changes
2. `mix ash.migrate` — apply migrations (likely no-op if columns already exist)
3. Verify code interfaces via Tidewave `project_eval`:
   `Ash.Resource.Info.interfaces(JidoClaw.Folio.InboxItem)` should return non-empty list
4. `mix compile --warnings-as-errors`
5. `mix test`

---

## Phase 3: OTP Reliability (P1)

### 3A. Convert init/1 to handle_continue/2 (7 GenServers)

For each module, change `init/1` to return `{:ok, initial_state, {:continue, :load}}`
and move the heavy work into `handle_continue(:load, state)`.

**Files:**

1. `lib/jido_claw/platform/skills.ex` (line 280) — Move `load_from_disk/1` to handle_continue; init returns `%{project_dir: dir, skills: []}`
2. `lib/jido_claw/solutions/store.ex` (lines 115-128) — Move ETS init + `load_from_disk/1` to handle_continue
3. `lib/jido_claw/solutions/reputation.ex` (lines 121-122) — Move `ensure_table()` + `load_from_disk/1` to handle_continue
4. `lib/jido_claw/platform/memory.ex` (lines 76-90) — Move `ensure_ready` + disk load loop to handle_continue
5. `lib/jido_claw/platform/session/worker.ex` (line 68) — Move `load_from_jsonl/2` to handle_continue; init assigns empty messages list
6. `lib/jido_claw/agent_tracker.ex` (lines 83-100) — Move SignalBus subscriptions + telemetry attaches to handle_continue
7. `lib/jido_claw/heartbeat.ex` (line 31) — Move `write_heartbeat/1` to handle_continue; keep `schedule_tick()` in init (just a `Process.send_after`)

### 3B. Add terminate/2 callbacks (5 GenServers)

**Files:**

1. `lib/jido_claw/solutions/store.ex` — Add `terminate/2` that calls `persist_to_disk/1`
2. `lib/jido_claw/solutions/reputation.ex` — Add `terminate/2` that calls `persist_to_disk/1`
3. `lib/jido_claw/platform/memory.ex` — Add `terminate/2` that calls `persist_to_disk/1`
4. `lib/jido_claw/platform/background_process/registry.ex` — Add `terminate/2` that kills tracked processes and logs
5. `lib/jido_claw/agent_tracker.ex` — Add `terminate/2` that calls `:telemetry.detach/1` for both handler IDs (`"agent-tracker-tool-stop"` and `"agent-tracker-tool-start"`)

**Note:** `Tools.Approval` does NOT need ETS cleanup in `terminate/2` — private ETS tables
are automatically destroyed when the owning process exits. However, add a `terminate/2` that
replies `{:error, :shutting_down}` to any pending approval callers in `state.pending` so
they don't hang for 120 seconds.

### 3C. Replace Task.start with Task.Supervisor

**Files:**

- `lib/jido_claw/application.ex` — Add `{Task.Supervisor, name: JidoClaw.TaskSupervisor}` to core children (early in the list, after registries)
- `lib/jido_claw/forge/manager.ex` (line 182) — Replace `Task.start(fn -> ...)` with `Task.Supervisor.start_child(JidoClaw.TaskSupervisor, fn -> ...)`
- `lib/jido_claw/forge/harness.ex` (line 353) — Same replacement

### 3D. Restructure supervision tree

**File:** `lib/jido_claw/application.ex`

Minimal restructuring — extract foundational infrastructure into a nested supervisor so
that if Repo/PubSub/SignalBus crash, dependent children are also restarted:

```elixir
# Group 1: Infrastructure (nested supervisor, :one_for_one)
{Supervisor, name: JidoClaw.InfraSupervisor, strategy: :one_for_one, children: [
  registries, Repo, Vault, PubSub, TaskSupervisor, SignalBus
]}

# Remaining children stay at top level under :rest_for_one
# so infra restart cascades to everything that follows
```

Change the top-level supervisor strategy from `:one_for_one` to `:rest_for_one`. This means
if `InfraSupervisor` restarts, all children started after it are also restarted.

Also add `:max_restarts` tuning: with 20+ children, increase from default (3 in 5s) to
something like `max_restarts: 10, max_seconds: 30`.

---

## Phase 4: Tool & Medium-Priority Fixes (P1-P2)

### 4A. Fix edit_file.ex File.write!

**File:** `lib/jido_claw/tools/edit_file.ex` (line 33)

Replace `File.write!(path, new_content)` with a non-raising variant, preserving the existing
success payload shape (`%{path:, diff:, status: "edited"}` — expected by Display and tests):

```elixir
case File.write(path, new_content) do
  :ok ->
    diff = build_diff(old_str, new_str)
    {:ok, %{path: path, diff: diff, status: "edited"}}
  {:error, reason} ->
    {:error, "Failed to write #{path}: #{inspect(reason)}"}
end
```

Remove the `File.write!` line and the `diff`/`{:ok, ...}` lines that follow it (lines 33-36),
replacing with the above block.

### 4B. Fix schedule_task.ex error wrapping

**File:** `lib/jido_claw/tools/schedule_task.ex` (lines 84-95)

Change `{:error, reason} -> {:ok, %{result: "Failed..."}}` to return `{:error, ...}` tuples
so the Jido runtime (and the LLM) can distinguish success from failure.

### 4C. Relocate approval.ex

**Files:**

- Move `lib/jido_claw/tools/approval.ex` to `lib/jido_claw/platform/approval.ex`
- Rename module from `JidoClaw.Tools.Approval` to `JidoClaw.Platform.Approval`
- Grep for all references and update them

### 4D. Fix cast -> call for back-pressure (2 modules)

**Files:**

1. `lib/jido_claw/platform/session/worker.ex` (line 43) — Change `add_message` from `cast` to `call`, update `handle_cast({:add_message, ...}, ...)` to `handle_call({:add_message, ...}, from, ...)` with `{:reply, :ok, ...}`
2. `lib/jido_claw/agent_tracker.ex` (line 39) — Change `register` from `cast` to `call`, update handler to reply `:ok`

Leave `Cron.Worker.trigger` as cast — fire-and-forget is correct for async job execution.

### 4E. Fix O(n^2) list appends

**Files:**

1. `lib/jido_claw/forge/context_builder.ex` (lines 210, 212) — Replace `acc ++ [line]` with `[line | acc]` and `Enum.reverse` after the reduce
2. `lib/jido_claw/platform/session/worker.ex` (line 90) — Replace `state.messages ++ [message]` with `[message | state.messages]` and reverse when reading
3. `lib/jido_claw/agent_tracker.ex` (line 154) — Replace `state.order ++ [id]` with `[id | state.order]` and reverse when reading

### 4F. Pass actor in LiveView Ash reads

**Files:**

- `lib/jido_claw/web/live/folio_live.ex` (lines 6-8)
- `lib/jido_claw/web/live/workflows_live.ex` (line 6)
- `lib/jido_claw/web/live/projects_live.ex` (line 6)

Add `actor: socket.assigns.current_user` to all Ash reads. Keep `authorize?: false` for now
since most resources lack policies. This establishes the actor-passing pattern so policies
can be enabled per-resource as they're added.

### 4G. Narrow broad rescue \_ patterns

Focus on the most impactful:

**File:** `lib/jido_claw/heartbeat.ex` (lines 55-59, 62-66)

- Replace `rescue _ ->` with specific exception catches (`rescue e in [RuntimeError, ErlangError] ->`)
  and add `Logger.debug("[Heartbeat] Stats unavailable: #{Exception.message(e)}")`

---

## Verification (all phases)

After each phase:

1. `mix compile --warnings-as-errors`
2. `mix format --check-formatted`
3. `mix test`

Phase 1 additionally:

- Verify `POST /v1/chat/completions` returns 401 without API key
- Verify `/admin` and `/live-dashboard` require authentication (redirect to `/sign-in`)
- Verify WebSocket connection without a valid session is rejected

Phase 2 additionally:

- `mix ash.codegen add_code_interfaces_and_relationships` — generate migration/snapshot
- `mix ash.migrate` — apply any new migrations
- Tidewave eval: `Ash.Resource.Info.interfaces(JidoClaw.Folio.InboxItem)` returns non-empty list
- Tidewave eval: verify relationships load with `Ash.load!/2`

Phase 3 additionally:

- Verify app boots without deadlocks (`mix run --no-halt`)
- Verify GenServers respond quickly to initial calls (not blocked by init)
