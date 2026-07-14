defmodule JidoClaw.MCPServer.ErrorCodes do
  @moduledoc """
  The closed error-code registry for the served MCP surface (pad PD1-2) —
  camus C1-3's closed-contract posture applied to the tool surface.

  Every machine-readable `code` a PUBLIC served-tool error envelope may carry
  is enumerated here, grouped into families, each with a one-line doc (the
  map shape makes doc-less codes structurally impossible). Enforcement lives
  at the wire boundary (`JidoClaw.MCPServer.ErrorBoundary`): an unregistered
  code is re-coded to `:tool_error` with `details.unregistered_code` and a
  drift log — the boundary fallback is the closure proof; the AST sweep test
  (`error_codes_sweep_test.exs`) is supplemental lint. Scope is the served
  MCP surface by construction — the app interior stays open (no global
  internal enum).

  Deliberately excluded details-level sub-codes (they never appear as an
  envelope's top-level `code`): `:foreign`/`:unknown` (inside
  `JidoClaw.Tools.Error`'s `details.errors[]` child summaries),
  `:dropped_runtime_handle` (a tuple-position placeholder), and tool
  approval's internal `:cache_unavailable`/`:invalid_mount_config`
  (collapsed to a fail-closed boolean before any envelope).

  ## Kinship with the `mix jidoclaw run` exit tiers (queue #4 ↔ #16)

  The one-shot CLI classifies run outcomes into exit tiers 0–6 via
  `JidoClaw.Orchestration.RunFailure` — the closed 22-kind run-failure
  vocabulary. That taxonomy and this registry are one contract family with
  two enforcement points: `RunFailure` closes *why an agent run failed* at
  the orchestration layer; this module closes *what a served tool error may
  say* at the MCP wire. Neither consumes the other's atoms — the kinship is
  the shared closed-vocabulary posture, applied per surface.

  ## Change rules

  Additions are MINOR on `JidoClaw.MCPServer.SurfaceVersion`; removals,
  renames, and refamilies are MAJOR — always a deliberate bump plus a golden
  fixture regen (`test/fixtures/mcp_surface/served_surface.json`) in the
  same diff.
  """

  @type family ::
          :pipeline
          | :normalization
          | :lua
          | :sandbox
          | :host_exec
          | :scope
          | :lookup
          | :workflow

  # Family tables: code => one-line doc. A code cannot join without its doc.
  @pipeline %{
    approval_pending: "the tool call is parked on a durable human-approval gate",
    approval_denied: "an operator rejected this tool call's approval case",
    approval_unavailable: "the approval gate could not run and fails closed",
    doom_loop: "the loop guard halted a repeating/runaway tool-call pattern"
  }

  @normalization %{
    tool_error: "generic tool failure (also the boundary's unregistered-code fallback)",
    validation_error: "input failed validation before or during the tool run",
    config_error: "missing or invalid configuration prevented the tool run",
    execution_error: "the tool body failed while executing",
    unknown_error: "an unclassified first-party error leaf",
    internal_error: "an internal platform error class container",
    exception: "a foreign exception struct was normalized into the envelope",
    failed: "legacy string status \"failed\" normalized into a code",
    error: "legacy string status \"error\" normalized into a code",
    still_running: "the referenced operation has not completed yet",
    timeout: "the operation exceeded its time budget"
  }

  @lua %{
    lua_call_budget_exceeded: "the script exceeded its host-binding call budget",
    lua_result_too_large: "the aggregate result exceeded max_result_bytes",
    lua_result_not_encodable: "the script result cannot be encoded for the wire",
    lua_compile_error: "the Lua script failed to compile",
    lua_runtime_error: "the Lua script raised at runtime",
    lua_timeout: "the Lua evaluation timed out (non-retryable by design)",
    lua_memory_exceeded: "the Lua VM exceeded its memory budget",
    lua_task_exited: "the sandboxed evaluation task exited abnormally",
    lua_empty_script: "an empty script was submitted",
    lua_script_too_large: "the script source exceeded the size cap",
    lua_deadline_exceeded: "the surrounding action deadline preempted the eval",
    unknown_binding: "lua_docs was asked about a host binding that does not exist"
  }

  @sandbox %{
    sandbox_unavailable: "the sbx sandbox runtime is not available on this host",
    sandbox_command_timeout: "the sandboxed command timed out (tainted, non-retryable)",
    sandbox_output_limit: "the sandboxed command exceeded its output cap (tainted)",
    sandbox_deadline_exceeded: "the action deadline left no viable sandbox budget"
  }

  @host_exec %{
    host_deadline_exceeded: "the action deadline preempted the host command",
    host_command_timeout: "the host command exceeded its own timeout"
  }

  @scope %{
    tenant_required: "the call carries no resolvable tenant scope",
    missing_tenant: "run_skill requires a tenant for the durable WorkflowRun",
    missing_scope_tenant: "solution tools require a tenant scope",
    missing_scope_workspace: "solution tools require a workspace scope"
  }

  @lookup %{
    session_not_found: "no session matches the supplied identifier",
    session_id_mismatch: "the supplied session id does not match the resolved session",
    session_not_resolved: "the input resolved neither a live worker nor a session",
    not_found: "the referenced entity does not exist in this scope",
    unknown_target: "the inspect target could not be resolved",
    unknown_kind: "the inspect kind is not a recognized target kind",
    handoff_not_found: "no handoff record matches the supplied identifier",
    absolute_glob_not_allowed: "list_directory rejects absolute glob patterns",
    glob_outside_project: "list_directory rejects globs escaping the project root",
    unknown_skill: "run_skill was asked for a skill name that is not registered"
  }

  @workflow %{
    replay_refused: "workflow replay was refused (definition drift or policy)",
    event_feed_unavailable: "the run's event feed could not be read (infra fault)",
    skill_run_failed: "the compiled skill's workflow run failed (see details.reason)",
    skill_cancelled: "the skill's workflow run was cancelled"
  }

  @families %{
    pipeline: @pipeline,
    normalization: @normalization,
    lua: @lua,
    sandbox: @sandbox,
    host_exec: @host_exec,
    scope: @scope,
    lookup: @lookup,
    workflow: @workflow
  }

  @all MapSet.new(Enum.flat_map(@families, fn {_family, codes} -> Map.keys(codes) end))

  @code_to_family Map.new(
                    for {family, codes} <- @families, {code, _doc} <- codes do
                      {code, family}
                    end
                  )

  # The served details.retry definition (PD1-2 review round P1c): all THREE
  # wire states, absence included — tier 4 ships empty details and
  # missing/non-boolean hints abstain, so omission is a real state a client
  # must not guess about. Single-sourced: served standalone in
  # jido://bootstrap's error_contract AND concatenated into the stability
  # sentence below (which rides server_instructions).
  @retry_semantics ~s(details.retry is retry-policy eligibility: false means the failure ) <>
                     ~s(class is not eligible for the runtime's immediate automatic retry ) <>
                     ~s(\(do not blindly repeat without intervention\); true means the ) <>
                     ~s(classification treats the failure as transient; ABSENT means ) <>
                     ~s(eligibility was not reported — do not infer retryability or ) <>
                     ~s(automatically repeat. It never records whether an in-call retry ran ) <>
                     ~s(or remains available.)

  @stability_sentence ~s(Tool-result errors from this server \(isError: true tool responses\) ) <>
                        ~s(carry a machine-readable JSON envelope {"code","message","details"} ) <>
                        ~s(as content[1] — the second content item of the raw error response; ) <>
                        ~s(downstream relays may append further items. Codes come from a closed ) <>
                        ~s(registry \(families and codes in jido://bootstrap under "error_contract"\); ) <>
                        ~s(unregistered codes arrive re-coded as "tool_error" with ) <>
                        ~s(details.unregistered_code carrying the original. This contract covers ) <>
                        ~s(tool-result errors only: unknown tools, authorization refusals, and ) <>
                        ~s(escaped runtime failures remain plain JSON-RPC protocol errors with no ) <>
                        ~s(envelope. Code additions are MINOR on the served-surface version; ) <>
                        ~s(removals, renames, and family moves are MAJOR. ) <> @retry_semantics

  @doc """
  The full registry: family => (code => one-line doc). The map shape makes a
  doc-less code structurally impossible.
  """
  @spec families() :: %{family() => %{atom() => String.t()}}
  def families, do: @families

  @doc "Every registered code, as a set."
  @spec all() :: MapSet.t(atom())
  def all, do: @all

  @doc "Whether `code` is a registered served-surface error code."
  @spec member?(atom()) :: boolean()
  def member?(code) when is_atom(code), do: MapSet.member?(@all, code)

  @doc "The family a registered `code` belongs to; `:error` for unregistered codes."
  @spec family(atom()) :: {:ok, family()} | :error
  def family(code) when is_atom(code), do: Map.fetch(@code_to_family, code)

  @doc """
  The served-surface error-contract stability sentence — served verbatim as
  the MCP `server_instructions` and inside `jido://bootstrap`'s
  `error_contract` block. Scoped to TOOL-RESULT errors only; ends with the
  `retry_semantics/0` definition (compile-time concat of the same
  attribute — single-sourced).
  """
  @spec stability_sentence() :: String.t()
  def stability_sentence, do: @stability_sentence

  @doc """
  The served `details.retry` definition — retry-policy ELIGIBILITY, all
  three wire states (true / false / absent) defined so a remote client can
  never mistake the field for a record of in-call retry execution or
  remaining budget. Served in `jido://bootstrap`'s `error_contract` block
  under `retry_semantics` and (via `stability_sentence/0`) in the MCP
  `server_instructions`.
  """
  @spec retry_semantics() :: String.t()
  def retry_semantics, do: @retry_semantics
end
