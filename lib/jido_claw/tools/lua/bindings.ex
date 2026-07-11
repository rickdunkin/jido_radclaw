defmodule JidoClaw.Tools.Lua.Bindings do
  # The docs entries, per-binding projections, and result maps are the
  # LLM-facing wire contract of the Lua sandbox — explicit API surfaces,
  # not incidental duplication.
  # reach:disable-for-this-file fixed_shape_map
  @moduledoc """
  The `jido.*` host-binding table for the `lua_query` sandbox — **the
  single source** (the `Stage.to_map/1` / G2-1b precedent): each
  `%Entry{}` carries both the wiring `install/4` sets into the VM and
  the docs surface `lua_docs` serves, so the two can never drift.

  Every binding is **read-only** (`assert_read_only!/0` is called per
  eval and pinned by a unit test — the forward-guard for any future
  write binding, which must be approval-require-listed the day it
  lands). Every callback is arity-2 and threads the post-`Lua.encode!`
  VM state back (`{[encoded], updated_state}`) — encode allocates table
  refs *into* the state, so returning an encoded ref without the
  updated `%Lua{}` would hand Lua dangling trefs.

  All reads pass both `tenant:` and `actor:` (a tenant-bound system
  actor unless the scope carries one). Violations — bad args, missing
  scope, budget refusal — surface as **raised Lua errors** (the
  `{:error, message, state}` callback contract): bad-arg errors are
  script-recoverable via `pcall` by design, while budget refusals are
  additionally latched in `CallTrace.refused?/1` so the Runner can
  override a `pcall`-swallowed refusal post-eval.

  Inbound Lua option tables are string-keyed and pass a **fixed-key
  allowlist translation** (never `String.to_atom/1` on script input);
  unknown keys fail loudly. `normalize_lua_value/1` (ported from jidoka
  `lib/jidoka/workflow/lua.ex` @ 9469dc09, Apache-2.0) converts decoded
  pair-lists to maps and numeric-keyed tables to arrays.
  """

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Cases
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Solutions.Matcher
  alias JidoClaw.Tools.Lua.CallTrace
  alias JidoClaw.Tools.Lua.Policy
  alias JidoClaw.Tools.OutputLimit
  alias JidoClaw.Tools.OutputRef
  alias JidoClaw.Tools.OutputShaper.Generic
  alias JidoClaw.WorkflowView

  defmodule Entry do
    @moduledoc """
    One host binding: VM wiring (`path`, `callback_builder`,
    `read_only?`) plus the docs fields `lua_docs` renders.
    """
    @enforce_keys [
      :name,
      :path,
      :read_only?,
      :callback_builder,
      :signature,
      :description,
      :params,
      :returns,
      :example
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            path: [String.t()],
            read_only?: boolean(),
            callback_builder: (map(), pid(), Policy.t() -> function()),
            signature: String.t(),
            description: String.t(),
            params: [map()],
            returns: String.t(),
            example: String.t()
          }
  end

  # Bounds owned by the binding layer (backing reads carry their own).
  @cases_default_limit 25
  @cases_max_limit 50
  @solutions_default_limit 5
  @solutions_max_limit 20
  @solution_content_bytes 4 * 1024
  @output_default_max_bytes 16_384

  @doc """
  Install every binding into `lua`, closing over the (normalized)
  caller scope, the eval's `CallTrace`, and the resolved policy.
  """
  @spec install(Lua.t(), map(), pid(), Policy.t()) :: Lua.t()
  def install(%Lua{} = lua, tool_context, trace, %Policy{} = policy)
      when is_map(tool_context) and is_pid(trace) do
    scope = normalize_scope(tool_context)

    Enum.reduce(entries(), lua, fn %Entry{} = entry, acc ->
      Lua.set!(acc, entry.path, entry.callback_builder.(scope, trace, policy))
    end)
  end

  @doc """
  The wire maps `lua_docs` serves — rendered from the same entries
  `install/4` wires, so docs and behavior cannot drift.
  """
  @spec docs() :: [map()]
  def docs do
    Enum.map(entries(), fn %Entry{} = e ->
      %{
        "name" => e.name,
        "signature" => e.signature,
        "description" => e.description,
        "params" => e.params,
        "returns" => e.returns,
        "example" => e.example,
        "read_only" => e.read_only?
      }
    end)
  end

  @doc """
  Raises unless every entry is read-only. Called per eval by the Runner;
  the day a write binding lands it must clear this guard deliberately
  (and join the approval require-list).
  """
  @spec assert_read_only!() :: :ok
  def assert_read_only! do
    case Enum.reject(entries(), & &1.read_only?) do
      [] ->
        :ok

      offenders ->
        names = Enum.map_join(offenders, ", ", & &1.name)

        raise "lua_query bindings must be read-only; non-read-only entries: #{names} " <>
                "(a write binding needs its own approval gating before it can ship)"
    end
  end

  @doc """
  Normalize a decoded Lua value: pair-lists become maps, numeric-keyed
  maps become arrays. Ported from jidoka `lib/jidoka/workflow/lua.ex`
  @ 9469dc09 (Apache-2.0).
  """
  @spec normalize_lua_value(term()) :: term()
  def normalize_lua_value(value) when is_list(value) do
    if keyword_pairs?(value) do
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), normalize_lua_value(nested)} end)
      |> Map.new()
      |> maybe_array_from_numeric_keys()
    else
      Enum.map(value, &normalize_lua_value/1)
    end
  end

  def normalize_lua_value(value), do: value

  # ── Entries ─────────────────────────────────────────────────────────────

  @spec entries() :: [Entry.t()]
  defp entries do
    [
      %Entry{
        name: "jido.runs",
        path: ["jido", "runs"],
        read_only?: true,
        callback_builder: callback_builder("jido.runs", &runs_read/2),
        signature: "jido.runs(filter?) -> [run]",
        description:
          "List tenant workflow runs (operator projections). Defaults to the active set " <>
            "(pending/running/awaiting_approval); pass a status filter for terminal runs.",
        params: [
          %{
            "name" => "filter",
            "type" => "table?",
            "doc" =>
              "status = string or array of strings (pending, running, awaiting_approval, " <>
                "completed, failed, cancelled, abandoned); limit = integer 1..50 (default 25)"
          }
        ],
        returns:
          "array of run maps: run_id, name, workflow_type, status, disposition " <>
            "(e.g. done_with_findings; nil for most runs), findings_deferred_count, " <>
            "started_at, completed_at, duration_ms, error, result_summary, deadline, " <>
            "claimed_by, claim_expires_at (raw/frozen claim columns — on a terminal " <>
            "run the last-claim value, not live lease state)",
        example: ~s|return jido.runs({status = "failed", limit = 5})|
      },
      %Entry{
        name: "jido.run",
        path: ["jido", "run"],
        read_only?: true,
        callback_builder: callback_builder("jido.run", &run_read/2),
        signature: "jido.run(id) -> run | nil",
        description:
          "Full snapshot of one workflow run — the jido.runs projection (incl. " <>
            "disposition/findings_deferred_count) plus, for a composer run, the composer " <>
            "summary (route/waves/held/dropped) and gate-block state (incl. " <>
            "review_stall_pending).",
        params: [%{"name" => "id", "type" => "string", "doc" => "workflow run UUID"}],
        returns: "run map, or nil when the run does not exist in this tenant",
        example: ~s|local run = jido.run(id)\nreturn run and run.status|
      },
      %Entry{
        name: "jido.events",
        path: ["jido", "events"],
        read_only?: true,
        callback_builder: callback_builder("jido.events", &events_read/2),
        signature: "jido.events(run_id, opts?) -> feed",
        description:
          "A run's durable event feed, byte-bounded and seq-paginated. Page forward by " <>
            "passing the previous feed.next_seq back as after_seq.",
        params: [
          %{"name" => "run_id", "type" => "string", "doc" => "workflow run UUID"},
          %{
            "name" => "opts",
            "type" => "table?",
            "doc" => "after_seq = integer cursor; limit = integer 1..200 (default 50)"
          }
        ],
        returns:
          "feed map: run_id, run_status, count, events (seq/kind/occurred_at/payload/" <>
            "metadata), next_seq (nil when exhausted)",
        example:
          ~s|local feed = jido.events(run_id, {limit = 100})\n| <>
            ~s|local n = 0\nfor _, e in ipairs(feed.events) do\n| <>
            ~s|  if e.kind == "wave_completed" then n = n + 1 end\nend\nreturn n|
      },
      %Entry{
        name: "jido.cases",
        path: ["jido", "cases"],
        read_only?: true,
        callback_builder: callback_builder("jido.cases", &cases_read/2),
        signature: "jido.cases(filter?) -> [case]",
        description:
          "Pending approval cases (workflow gates and tool-call approvals). Read-only: " <>
            "deciding a case stays on the operator surfaces (/gates, /approvals).",
        params: [
          %{
            "name" => "filter",
            "type" => "table?",
            "doc" =>
              "run_id = run UUID (that run plus its direct child runs); session = true " <>
                "(only the calling session's cases); limit = integer 1..50 (default 25). " <>
                "run_id and session are mutually exclusive; neither means the whole tenant."
          }
        ],
        returns:
          "array of case maps: id, kind, status, step_name, tool_name, details, " <>
            "session_id, workflow_run_id, decision, decided_by_id, decided_at, " <>
            "decision_comment, inserted_at",
        example: ~s|return jido.cases({session = true})|
      },
      %Entry{
        name: "jido.debt",
        path: ["jido", "debt"],
        read_only?: true,
        callback_builder: callback_builder("jido.debt", &debt_read/2),
        signature: "jido.debt() -> ledger",
        description:
          "The tenant's deferred-findings debt ledger (BO2-6): every approved " <>
            "review-stall case with its waive records, plus the severity rollup. " <>
            "Read-only — waiving happens on the operator surfaces (/gates, /approvals).",
        params: [],
        returns:
          "ledger map: cases (case_id, workflow_run_id, step_name, decided_at, " <>
            "decided_by_id, decision_comment, waive_records [key/severity/note]), " <>
            "severity_counts, total_waived",
        example: ~s|return jido.debt().severity_counts|
      },
      %Entry{
        name: "jido.solutions",
        path: ["jido", "solutions"],
        read_only?: true,
        callback_builder: callback_builder("jido.solutions", &solutions_read/2),
        signature: "jido.solutions(query, opts?) -> [solution]",
        description:
          "Search stored solutions for the calling workspace. Lexical-only from the " <>
            "sandbox (exact signature + FTS/trigram): embedding resolution is deliberately " <>
            "disabled so a read-only script can never trigger external egress or cost.",
        params: [
          %{"name" => "query", "type" => "string", "doc" => "problem description"},
          %{
            "name" => "opts",
            "type" => "table?",
            "doc" => "language = string; framework = string; limit = integer 1..20 (default 5)"
          }
        ],
        returns:
          "array of solution maps: signature, language, framework, tags, trust_score, " <>
            "sharing, content (truncated to 4KB), inserted_at, updated_at, score, match_type",
        example: ~s|return jido.solutions("postgres migration lock timeout", {limit = 3})|
      },
      %Entry{
        name: "jido.output",
        path: ["jido", "output"],
        read_only?: true,
        callback_builder: callback_builder("jido.output", &output_read/2),
        signature: "jido.output(ref, opts?) -> slice | nil",
        description:
          "Read a stored tool-output ref (the out_… refs shaped run_command/git_diff " <>
            "results carry) as a byte-offset slice, so a script can grep/aggregate large " <>
            "output server-side with Lua string.* instead of paging it through context. " <>
            "Session-scoped exactly like fetch_output (S-M2).",
        params: [
          %{"name" => "ref", "type" => "string", "doc" => ~s|an output ref, e.g. "out_a1b2…"|},
          %{
            "name" => "opts",
            "type" => "table?",
            "doc" =>
              "offset = integer byte offset >= 0 (default 0); max_bytes = integer slice " <>
                "size (default 16384, capped at the inline output cap). Both slice ends " <>
                "are made UTF-8 safe, so byte-offset paging can drop a multibyte character " <>
                "spanning a page boundary."
          }
        ],
        returns:
          "slice map: content, total_bytes, offset, returned_bytes, clipped (content is " <>
            "not the whole stored output), truncated (capture hit its own cap) — or nil " <>
            "for an unknown/expired/out-of-scope ref",
        example:
          ~s|local out = jido.output(ref, {offset = 0, max_bytes = 8192})\n| <>
            ~s|return out and string.match(out.content, "error[^\\n]*")|
      }
    ]
  end

  # ── Shared callback plumbing ────────────────────────────────────────────

  # Reserve BEFORE any work (the budget check must precede reads), decode
  # after, and thread the post-encode VM state back. Handler contract:
  # {:ok, data} | {:error, message}.
  defp callback_builder(name, handler) do
    fn scope, trace, %Policy{} = policy ->
      fn args, %Lua{} = state ->
        dispatch_call(name, handler, args, state, {scope, trace, policy})
      end
    end
  end

  defp dispatch_call(name, handler, args, state, {scope, trace, policy}) do
    case CallTrace.reserve(trace, name, args, policy.max_calls) do
      {:error, {:lua_call_budget_exceeded, max}} ->
        {:error, "#{name}: host-call budget exceeded (max #{max} jido.* calls per eval)", state}

      {:ok, call_id} ->
        run_handler(handler, args, state, scope, trace, call_id)
    end
  end

  defp run_handler(handler, args, state, scope, trace, call_id) do
    decoded = decode_args(args, state)

    case handler.(decoded, scope) do
      {:ok, data} ->
        :ok = CallTrace.complete(trace, call_id, "ok", data)
        encode_result(state, data)

      {:error, message} ->
        :ok = CallTrace.complete(trace, call_id, "error", message)
        {:error, message, state}
    end
  end

  defp decode_args(args, %Lua{} = state) when is_list(args) do
    state
    |> Lua.decode_list!(args)
    |> Enum.map(&normalize_lua_value/1)
  end

  # `Lua.encode!/2` turns the ATOM nil into the string "nil" (its atom
  # clause), while nil is already a valid encoded Lua value — pass it
  # through directly.
  defp encode_result(state, nil), do: {[nil], state}

  defp encode_result(state, data) do
    {encoded, new_state} = Lua.encode!(state, JsonSafe.encode(data))
    {[encoded], new_state}
  end

  # ── jido.runs ───────────────────────────────────────────────────────────

  defp runs_read([], scope), do: runs_read([%{}], scope)

  defp runs_read([filter], scope) when is_map(filter) do
    with {:ok, opts} <-
           translate_opts(filter, %{"status" => :status, "limit" => :limit}, "jido.runs"),
         {:ok, statuses} <- validate_statuses(Map.get(opts, :status)),
         {:ok, limit} <- optional_int(Map.get(opts, :limit), "jido.runs", "limit") do
      view_opts =
        []
        |> put_present(:statuses, statuses)
        |> put_present(:limit, limit)

      case WorkflowView.runs(scope_opts(scope), view_opts) do
        {:ok, runs} -> {:ok, runs}
        {:error, :tenant_required} -> {:error, "jido.runs: no tenant scope on this call"}
        {:error, :runs_unavailable} -> {:error, "jido.runs: workflow run read failed"}
      end
    end
  end

  defp runs_read(_args, _scope),
    do: {:error, ~s|jido.runs takes an optional filter table: {status = "failed", limit = 10}|}

  # Validate raw status input against the WorkflowRun enum via a fixed
  # string->atom map introspected from the resource — never String.to_atom.
  defp validate_statuses(nil), do: {:ok, nil}
  # An explicit empty array means "no filter" (the jidoka normalize_allowed_tools posture).
  defp validate_statuses([]), do: {:ok, nil}
  defp validate_statuses(status) when is_binary(status), do: validate_statuses([status])

  defp validate_statuses(statuses) when is_list(statuses) do
    allowed = run_status_map()

    valid_names =
      allowed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    result =
      Enum.reduce_while(statuses, {:ok, []}, fn value, {:ok, acc} ->
        case is_binary(value) and Map.fetch(allowed, value) do
          {:ok, atom} ->
            {:cont, {:ok, [atom | acc]}}

          _ ->
            {:halt,
             {:error, "jido.runs: unknown status #{inspect(value)} (valid: #{valid_names})"}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp validate_statuses(_other),
    do: {:error, "jido.runs: status must be a string or an array of strings"}

  # The value set moved from an inline `one_of` constraint into the
  # `WorkflowRun.Status` enum type (argus P1) — read it there, not from
  # attribute constraints (enum types carry no `one_of`).
  defp run_status_map do
    Map.new(WorkflowRun.Status.values(), &{Atom.to_string(&1), &1})
  end

  # ── jido.run ────────────────────────────────────────────────────────────

  defp run_read([id], scope) when is_binary(id) and id != "" do
    case WorkflowView.snapshot(id, scope_opts(scope)) do
      {:ok, view} -> {:ok, view}
      {:error, :not_found} -> {:ok, nil}
      {:error, :tenant_required} -> {:error, "jido.run: no tenant scope on this call"}
    end
  end

  defp run_read(_args, _scope), do: {:error, "jido.run takes one run id string"}

  # ── jido.events ─────────────────────────────────────────────────────────

  defp events_read([run_id], scope), do: events_read([run_id, %{}], scope)

  defp events_read([run_id, opts], scope) when is_binary(run_id) and is_map(opts) do
    with {:ok, translated} <-
           translate_opts(
             opts,
             %{"after_seq" => :after_seq, "limit" => :limit},
             "jido.events"
           ),
         {:ok, after_seq} <-
           optional_int(Map.get(translated, :after_seq), "jido.events", "after_seq"),
         {:ok, limit} <- optional_int(Map.get(translated, :limit), "jido.events", "limit") do
      feed_opts =
        []
        |> put_present(:after_seq, after_seq)
        |> put_present(:limit, limit)

      case WorkflowView.event_feed(run_id, scope_opts(scope), feed_opts) do
        {:ok, feed} -> {:ok, feed}
        {:error, :not_found} -> {:error, "jido.events: run not found: #{run_id}"}
        {:error, :event_feed_unavailable} -> {:error, "jido.events: event read failed"}
        {:error, :tenant_required} -> {:error, "jido.events: no tenant scope on this call"}
      end
    end
  end

  defp events_read(_args, _scope),
    do:
      {:error,
       "jido.events takes a run id string and an optional opts table {after_seq = n, limit = n}"}

  # ── jido.cases ──────────────────────────────────────────────────────────

  defp cases_read([], scope), do: cases_read([%{}], scope)

  defp cases_read([filter], scope) when is_map(filter) do
    with {:ok, opts} <-
           translate_opts(
             filter,
             %{"run_id" => :run_id, "session" => :session, "limit" => :limit},
             "jido.cases"
           ),
         {:ok, limit} <- optional_int(Map.get(opts, :limit), "jido.cases", "limit") do
      limit = clamp(limit || @cases_default_limit, 1, @cases_max_limit)
      read_opts = [query: [limit: limit]] ++ scope_opts_kw(scope)

      case cases_query(opts, scope, read_opts) do
        {:ok, cases} -> {:ok, Enum.map(cases, &case_view/1)}
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, _} -> {:error, "jido.cases: case read failed (is run_id a valid uuid?)"}
      end
    end
  end

  defp cases_read(_args, _scope),
    do:
      {:error,
       "jido.cases takes an optional filter table: {run_id = uuid} | {session = true} | {limit = n}"}

  defp cases_query(%{run_id: _, session: _}, _scope, _read_opts),
    do: {:error, "jido.cases: pass either run_id or session, not both"}

  defp cases_query(%{run_id: run_id}, _scope, read_opts) when is_binary(run_id) do
    AgentCase.pending_for_run_tree(run_id, read_opts)
  end

  defp cases_query(%{run_id: other}, _scope, _read_opts),
    do: {:error, "jido.cases: run_id must be a run UUID string, got #{inspect(other)}"}

  defp cases_query(%{session: true}, scope, read_opts) do
    case scope.session_uuid do
      session_uuid when is_binary(session_uuid) and session_uuid != "" ->
        AgentCase.pending_for_session(session_uuid, read_opts)

      _ ->
        {:error, "jido.cases: session = true needs a session scope, and this surface has none"}
    end
  end

  defp cases_query(%{session: other}, _scope, _read_opts),
    do: {:error, "jido.cases: session must be the boolean true, got #{inspect(other)}"}

  defp cases_query(_opts, _scope, read_opts) do
    AgentCase.pending_for_tenant(read_opts)
  end

  # Fixed field allowlist — NOT whole-struct JsonSafe.encode, which is
  # broad and future-field-sensitive. `details` is already operator-safe
  # via Gate.Presentation at write time.
  defp case_view(case_record) do
    JsonSafe.encode(%{
      "id" => case_record.id,
      "kind" => case_record.kind,
      "status" => case_record.status,
      "step_name" => case_record.step_name,
      "tool_name" => case_record.tool_name,
      "details" => case_record.details,
      "session_id" => case_record.session_id,
      "workflow_run_id" => case_record.workflow_run_id,
      "decision" => case_record.decision,
      "decided_by_id" => case_record.decided_by_id,
      "decided_at" => case_record.decided_at,
      "decision_comment" => case_record.decision_comment,
      "inserted_at" => case_record.inserted_at
    })
  end

  # ── jido.debt ───────────────────────────────────────────────────────────

  # The BO2-6 deferred-findings ledger, read through the single
  # `Cases.waived_findings_ledger/2` seam (approved review-stall cases + the
  # waive records on their :approved timeline events). Read-only like every
  # binding; waiving itself stays on the operator surfaces.
  defp debt_read([], scope) do
    case Cases.waived_findings_ledger(scope.tenant_id, scope.actor) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, _reason} -> {:error, "jido.debt: ledger read failed"}
    end
  end

  defp debt_read(_args, _scope), do: {:error, "jido.debt takes no arguments"}

  # ── jido.solutions ──────────────────────────────────────────────────────

  defp solutions_read([query], scope), do: solutions_read([query, %{}], scope)

  defp solutions_read([query, opts], scope) when is_binary(query) and is_map(opts) do
    with {:ok, workspace_uuid} <- require_workspace(scope),
         {:ok, translated} <-
           translate_opts(
             opts,
             %{"language" => :language, "framework" => :framework, "limit" => :limit},
             "jido.solutions"
           ),
         {:ok, limit} <- optional_int(Map.get(translated, :limit), "jido.solutions", "limit"),
         {:ok, language} <-
           optional_string(Map.get(translated, :language), "jido.solutions", "language"),
         {:ok, framework} <-
           optional_string(Map.get(translated, :framework), "jido.solutions", "framework") do
      matcher_opts =
        [
          limit: clamp(limit || @solutions_default_limit, 1, @solutions_max_limit),
          tenant_id: scope.tenant_id,
          workspace_id: workspace_uuid,
          # Visibility opts verbatim from the find_solution tool.
          local_visibility: [:local, :shared, :public],
          cross_workspace_visibility: [:public],
          # The no-egress seam: a read-only sandbox binding must never
          # trigger embedding resolution (Voyage HTTP / cost).
          resolve_embedding?: false,
          actor: scope.actor
        ]
        |> put_present(:language, language)
        |> put_present(:framework, framework)

      views =
        query
        |> Matcher.find_solutions(matcher_opts)
        |> Enum.map(&solution_view/1)

      {:ok, views}
    end
  end

  defp solutions_read(_args, _scope),
    do:
      {:error,
       ~s|jido.solutions takes a query string and an optional opts table {language = "elixir", limit = 5}|}

  defp require_workspace(scope) do
    case scope.workspace_uuid do
      workspace_uuid when is_binary(workspace_uuid) and workspace_uuid != "" ->
        {:ok, workspace_uuid}

      _ ->
        {:error, "jido.solutions: needs a workspace scope, and this surface has none"}
    end
  end

  # Projection dropping the vector machinery (embedding / search_vector /
  # lexical_text) and bounding content — solutions can be large.
  defp solution_view(%{solution: s, score: score, match_type: match_type}) do
    JsonSafe.encode(%{
      "signature" => s.problem_signature,
      "language" => s.language,
      "framework" => s.framework,
      "tags" => s.tags,
      "trust_score" => s.trust_score,
      "sharing" => s.sharing,
      "content" => bounded_content(s.solution_content),
      "inserted_at" => s.inserted_at,
      "updated_at" => s.updated_at,
      "score" => score,
      "match_type" => match_type
    })
  end

  defp bounded_content(nil), do: nil

  defp bounded_content(content) when is_binary(content) do
    if byte_size(content) > @solution_content_bytes do
      content
      |> binary_part(0, @solution_content_bytes)
      |> OutputLimit.valid_utf8_prefix()
      |> Kernel.<>("… (truncated)")
    else
      content
    end
  end

  # ── jido.output ─────────────────────────────────────────────────────────

  defp output_read([ref], scope), do: output_read([ref, %{}], scope)

  defp output_read([ref, opts], scope) when is_binary(ref) and ref != "" and is_map(opts) do
    with {:ok, translated} <-
           translate_opts(
             opts,
             %{"offset" => :offset, "max_bytes" => :max_bytes},
             "jido.output"
           ),
         {:ok, offset} <- optional_int(Map.get(translated, :offset), "jido.output", "offset"),
         {:ok, max_bytes} <-
           optional_int(Map.get(translated, :max_bytes), "jido.output", "max_bytes"),
         :ok <- require_non_negative(offset, "jido.output", "offset") do
      # Ceiling at the inline cap: a larger slice would be leaf-truncated
      # by the wrapper AFTER returned_bytes/clipped were computed, making
      # the metadata lie (the fetch_output self-cap lesson).
      max_bytes = clamp(max_bytes || @output_default_max_bytes, 1, OutputLimit.max_bytes())

      case OutputRef.lookup(ref, scope.tenant_id, scope) do
        {:ok, row} -> {:ok, output_slice(row, offset || 0, max_bytes)}
        # Unknown/expired/out-of-scope ref ⇒ nil (indistinguishable by design).
        {:error, _} -> {:ok, nil}
      end
    end
  end

  defp output_read(_args, _scope),
    do:
      {:error,
       "jido.output takes a ref string and an optional opts table {offset = n, max_bytes = n}"}

  defp output_slice(row, offset, max_bytes) do
    content = row.content || ""
    total = byte_size(content)
    start = min(offset, total)
    slice_len = min(max_bytes, total - start)

    slice =
      content
      |> binary_part(start, slice_len)
      # An offset landing mid-codepoint leaves continuation bytes at the
      # front; the end cut can land mid-codepoint too. Fix both ends.
      |> Generic.valid_utf8_suffix()
      |> OutputLimit.valid_utf8_prefix()

    returned = byte_size(slice)

    %{
      "content" => slice,
      "total_bytes" => total,
      "offset" => offset,
      "returned_bytes" => returned,
      "clipped" => returned < total,
      "truncated" => row.truncated
    }
  end

  defp require_non_negative(nil, _binding, _key), do: :ok
  defp require_non_negative(value, _binding, _key) when is_integer(value) and value >= 0, do: :ok

  defp require_non_negative(value, binding, key),
    do: {:error, "#{binding}: #{key} must be a non-negative integer, got #{inspect(value)}"}

  # ── Scope / option helpers ──────────────────────────────────────────────

  # Coerce every scope read (the present-nil ToolContext trap) and default
  # the actor to a tenant-bound system actor.
  defp normalize_scope(tool_context) do
    tenant_id = binary_or_nil(Map.get(tool_context, :tenant_id))

    %{
      tenant_id: tenant_id,
      session_uuid: binary_or_nil(Map.get(tool_context, :session_uuid)),
      workspace_uuid: binary_or_nil(Map.get(tool_context, :workspace_uuid)),
      actor: Map.get(tool_context, :actor) || (tenant_id && Actor.system(tenant_id))
    }
  end

  defp binary_or_nil(value) when is_binary(value) and value != "", do: value
  defp binary_or_nil(_value), do: nil

  defp scope_opts(scope), do: %{tenant_id: scope.tenant_id, actor: scope.actor}

  defp scope_opts_kw(scope), do: [tenant: scope.tenant_id, actor: scope.actor]

  # Fixed-key allowlist translation for string-keyed Lua option tables —
  # never String.to_atom on script input; unknown keys fail loudly so a
  # typo'd option is immediately visible.
  defp translate_opts(map, allowlist, binding) when is_map(map) do
    valid_keys =
      allowlist
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(allowlist, key) do
        {:ok, atom_key} ->
          {:cont, {:ok, Map.put(acc, atom_key, value)}}

        :error ->
          {:halt, {:error, "#{binding}: unknown option #{inspect(key)} (valid: #{valid_keys})"}}
      end
    end)
  end

  # Lua numbers can arrive as floats (5.3 semantics notwithstanding);
  # accept integral floats, reject the rest loudly.
  defp optional_int(nil, _binding, _key), do: {:ok, nil}
  defp optional_int(value, _binding, _key) when is_integer(value), do: {:ok, value}

  defp optional_int(value, binding, key) when is_float(value) do
    truncated = trunc(value)

    if truncated * 1.0 == value do
      {:ok, truncated}
    else
      {:error, "#{binding}: #{key} must be an integer, got #{inspect(value)}"}
    end
  end

  defp optional_int(value, binding, key),
    do: {:error, "#{binding}: #{key} must be an integer, got #{inspect(value)}"}

  defp optional_string(nil, _binding, _key), do: {:ok, nil}
  defp optional_string(value, _binding, _key) when is_binary(value), do: {:ok, value}

  defp optional_string(value, binding, key),
    do: {:error, "#{binding}: #{key} must be a string, got #{inspect(value)}"}

  defp put_present(list, _key, nil), do: list
  defp put_present(list, key, value), do: Keyword.put(list, key, value)

  defp clamp(value, lo, hi) when is_integer(value), do: min(max(value, lo), hi)

  defp keyword_pairs?(value), do: Enum.all?(value, &match?({_key, _value}, &1))

  defp maybe_array_from_numeric_keys(map) do
    keys = Map.keys(map)

    if keys != [] and Enum.all?(keys, &numeric_string?/1) do
      map
      |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
      |> Enum.map(fn {_key, value} -> value end)
    else
      map
    end
  end

  defp numeric_string?(value) when is_binary(value), do: String.match?(value, ~r/^\d+$/)
  defp numeric_string?(_value), do: false
end
