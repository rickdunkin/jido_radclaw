# T1-4: Structured Error Contract (`JidoClaw.Error` via Splode)

## Context

`docs/exploration/jidoka/FEATURES-WORTH-BORROWING.md` Tier 1 item **T1-4** identifies that
jido_radclaw has no unified public error contract. Today errors take at least four shapes:

- `lib/jido_claw/tools/error.ex` — `normalize/1` produces an agent-facing
  `%{code:, message:, details:}` map for every tool failure (called via
  `JidoClaw.Tools.Action.__before_compile__`).
- `lib/jido_claw/forge/error.ex` — five plain `defexception` modules with `classify/1`
  returning recovery tuples. **Zero callers — dead code waiting for adoption.**
- `Ash.Error.*` — pattern-matched in 15+ consumer sites (memory, audit, persistence).
- ~50+ `{:error, "string"}` and `{:error, %{reason: …}}` sites across `tools/`,
  `reasoning/`, `forge/`, `web/`.

The goal is a single Splode-based contract callers can pattern-match on
(`%JidoClaw.Error.ValidationError{}`, `%ExecutionError{}`, `%ConfigError{}`) without losing
the agent-facing wire format the Tools layer already publishes. This sits beneath every other
T1 recommendation (Trace, Output, Compaction all return errors).

Splode (`~> 0.3`, currently `0.3.1`) is already pinned in `mix.exs:236`. `Ash.Error`,
`Jido.Error`, and `Reactor.Error` already run as parallel Splode trees in the VM — no
class-atom conflicts, dispatch is module-keyed.

## Architecture

Two layers:

1. **Contract layer** (`JidoClaw.Error`) — Splode registration of three classes
   (`Invalid` / `Execution` / `Config`) plus an `Internal` class for unknown-error wrapping.
   Three concrete leaf structs (`ValidationError` / `ConfigError` / `ExecutionError`).
   Public constructors return Exception structs callers wrap as `{:error, %X{}}`.

2. **Normalize layer** (`JidoClaw.Error.Normalize`) — per-domain `*_error/2`
   functions that accept the heterogeneous shapes already returned by each subsystem
   (atoms, tagged tuples, strings, exceptions) and produce a `%JidoClaw.Error.*{}` —
   with passthrough if the input is already first-party.

The agent-facing wire format from `Tools.Error.normalize/1` is **preserved for legacy
non-structured inputs** (strings, atoms, tagged tuples, bare maps). New clauses near the
top recognize `%JidoClaw.Error.*{}` (leaves and class wrappers) and produce richer
`{code, message, details}` triples — migrated sites intentionally change codes (e.g.
`:tool_error` → `:validation_error`). Existing clauses for everything else flow through
unchanged.

### Foreign Splode tree policy

The VM hosts several Splode trees today: `Ash.Error`, `Jido.Error`
(`deps/jido/lib/jido/error.ex`), `Jido.AI.Error` (`deps/jido_ai/lib/jido_ai/error.ex`),
and `Reactor.Error`. The policy is explicit and asymmetric:

- **`Normalize.*_error/2` is the boundary, NOT `to_class/1`.** Splode 0.3's
  `to_class/1` is an aggregator, not a policy gate: fresh leaves often have
  `splode: nil`, and Splode may accept those as compatible with the current
  tree even when their owning tree is not in `merge_with`. So a raw
  `%Jido.Error.ValidationError{}` can end up as a child of `%JidoClaw.Error.Invalid{}`
  without ever passing through `Normalize`. The architecture treats this as
  acceptable: `to_class/1` is best-effort flattening, not a security boundary.
  The Normalize layer is where the contract is enforced — code that needs a
  guaranteed `%JidoClaw.Error.*{}` must call `Normalize.tool_error/2` (or its
  peer) explicitly.

- **`merge_with: [Ash.Error]`** — Ash is included because 15+ consumer sites in
  `memory.ex`, `audit/`, `forge/persistence.ex`, `tools/store_solution.ex` already
  pattern-match on `%Ash.Error.*{}`. Merging ensures Ash class containers
  (`%Ash.Error.Invalid{errors: [...]}`) flatten cleanly through `to_class/1`
  rather than being re-wrapped. Note the realistic guarantee: `to_class/1`
  on a typed Ash class wrapper stays Ash; behavior on raw Ash leaves is
  best-effort and not load-bearing.

- **`Reactor.Error` is not in `merge_with`.** There's no first-party Reactor-error
  construction in jido_radclaw, and the transitive guarantee via Ash's own
  `merge_with: [Reactor.Error]` is not load-bearing for typed Reactor class
  containers. If a Reactor error ever needs to be converted, `Normalize.*_error/2`
  handles it via the foreign-exception fallback. Add `Reactor.Error` to `merge_with`
  later if Reactor passthrough becomes important; ship without it for now.

- **`Jido.Error` and `Jido.AI.Error` are NOT in `merge_with`.** This decision
  is documentary: it signals "the canonical conversion happens in `Normalize`",
  not "`to_class/1` will reject these." Tool-flow code that bubbles up
  Jido/Jido.AI exceptions MUST route through `Normalize.tool_error/2` to get
  a `%JidoClaw.Error.*{}`; relying on `to_class/1` implicit behavior is wrong.

- **Two intents, two operations.** Use `JidoClaw.Error.Normalize.<domain>_error/2`
  to **convert** any foreign or first-party error into a guaranteed
  `%JidoClaw.Error.*{}`. Use `JidoClaw.Error.to_class/1` only to aggregate a
  list of already-normalized errors into a class container for return — it is
  not an enforcement point.

The policy is documented in the `JidoClaw.Error` moduledoc and gated by tests
that exercise `Normalize.*` end-to-end (see step 9). The foreign-interop test
intentionally does not pin exact `to_class/1` behavior on raw foreign leaves —
that behavior is Splode-internal and may shift with Splode versions.

## File layout

Split files (Ash convention):

```
lib/jido_claw/
├── error.ex                              # use Splode + constructors + format/1
├── error/
│   ├── invalid.ex                        # use Splode.ErrorClass, class: :invalid
│   ├── execution.ex                      # use Splode.ErrorClass, class: :execution
│   ├── config.ex                         # use Splode.ErrorClass, class: :config
│   ├── internal.ex                       # use Splode.ErrorClass, class: :internal
│   ├── internal/
│   │   └── unknown_error.ex              # use Splode.Error, class: :internal
│   ├── validation_error.ex               # use Splode.Error, class: :invalid
│   ├── config_error.ex                   # use Splode.Error, class: :config
│   ├── execution_error.ex                # use Splode.Error, class: :execution
│   ├── normalize.ex                      # per-domain *_error/2 entrypoints
│   └── normalize/
│       ├── common.ex                     # validation/, execution/, timeout/, passthrough
│       └── context.ex                    # details/2, detail/3, jido_claw_error?/1
```

Reference implementations: `deps/ash/lib/ash/error/error.ex` (top-level shape),
`deps/ash/lib/ash/error/invalid.ex` (class container),
`deps/ash/lib/ash/error/invalid/no_such_action.ex` (leaf).
Jidoka reference: `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error.ex` and
`/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error/normalize.ex` (+ `normalize/common.ex`, `normalize/context.ex`).

## Implementation steps

### 1. Build the contract layer (`JidoClaw.Error` + classes + leaves)

`lib/jido_claw/error.ex` declares Splode:

```elixir
use Splode,
  error_classes: [
    invalid: JidoClaw.Error.Invalid,
    execution: JidoClaw.Error.Execution,
    config: JidoClaw.Error.Config,
    internal: JidoClaw.Error.Internal
  ],
  merge_with: [Ash.Error],
  filter_stacktraces: ["Splode."],
  unknown_error: JidoClaw.Error.Internal.UnknownError
```

`filter_stacktraces:` intentionally does **not** include `"JidoClaw."` — keeping
jido_claw frames in stacktraces aids debugging.

Leaf structs follow Jidoka's pattern exactly: `use Splode.Error, class: …, fields: […]`
with an `exception/1` override that seeds default `:message` and `:details`. Field shapes:

| Module                                 | Class      | Fields                                  |
|----------------------------------------|------------|-----------------------------------------|
| `JidoClaw.Error.ValidationError`       | `:invalid` | `[:message, :field, :value, :details]`  |
| `JidoClaw.Error.ConfigError`           | `:config`  | `[:message, :field, :value, :details]`  |
| `JidoClaw.Error.ExecutionError`        | `:execution` | `[:message, :phase, :details]`        |
| `JidoClaw.Error.Internal.UnknownError` | `:internal` | `[:message, :details, :error]`         |

Each leaf's `exception/1` is the Jidoka shape (verbatim port — see jidoka `error.ex:58-100`):

```elixir
@impl true
def exception(opts) do
  opts = if is_map(opts), do: Map.to_list(opts), else: opts
  opts
  |> Keyword.put_new(:message, "Invalid JidoClaw input")  # per-leaf default
  |> Keyword.put_new(:details, %{})
  |> super()
end
```

`UnknownError.exception/1` keeps Jidoka's special derivation of `:message` from
`opts[:error]` (binary passthrough, `nil → "Unknown JidoClaw error"`, else `inspect/1`)
— jidoka `error.ex:32-46`:

```elixir
@impl true
def exception(opts) do
  opts = if is_map(opts), do: Map.to_list(opts), else: opts
  message = Keyword.get(opts, :message) || unknown_message(opts[:error])
  opts |> Keyword.put(:message, message) |> Keyword.put_new(:details, %{}) |> super()
end

defp unknown_message(error) when is_binary(error), do: error
defp unknown_message(nil), do: "Unknown JidoClaw error"
defp unknown_message(error), do: inspect(error)
```

### 2. Public constructors on `JidoClaw.Error`

Mirror Jidoka's primary three plus jido_radclaw-specific patterns that scanning the
existing `{:error, …}` sites reveals:

```elixir
@spec validation_error(String.t(), keyword() | map()) :: Exception.t()
@spec config_error(String.t(), keyword() | map()) :: Exception.t()
@spec execution_error(String.t(), keyword() | map()) :: Exception.t()

# jido_radclaw-specific — common patterns from the existing string sites:
@spec not_found(atom(), term(), keyword() | map()) :: Exception.t()
# not_found(:agent, "abc")   → "Agent 'abc' not found."   (ValidationError)
# not_found(:session, uuid)  → "Session 'uuid' not found."
# not_found(:tool, "edit_file") → "Tool 'edit_file' not found."

@spec invalid_argument(atom(), term(), keyword() | map()) :: Exception.t()
# For agent-correctable bad input only (e.g. invalid cron string, malformed path).
# Builds ValidationError(field: name, value: term).
# NOT for runtime failures like read/write errors — those are ExecutionError.

@spec timeout(atom(), non_neg_integer() | nil, keyword() | map()) :: Exception.t()
# timeout(:agent_completion, 60_000) → ExecutionError(phase: :timeout, details: %{operation: …, timeout: …})

@spec missing_required(atom() | String.t(), keyword() | map()) :: Exception.t()
# Equivalent of Jidoka's missing_context, reframed (context is overloaded in jido_radclaw).
```

Do **not** port `invalid_context/2`, `invalid_context_schema/2`, `invalid_option/3` —
those are tied to Jidoka's Zoi-schema DSL with no analog here.

### 3. `JidoClaw.Error.format/1`

Verbatim port from Jidoka `error.ex:240-329` with substitution `"Jidoka" → "JidoClaw"`.
Handles error-class structs (flattens nested classes, dedupes, sorts, joins as
`"Multiple JidoClaw errors:\n- …"` or single-line), `%{message: binary}` maps, binaries,
and `inspect/1` fallback. The schema-error formatter (`flatten_schema_errors/2`) is dropped
unless we need it — it's tied to Jidoka's Zoi flow.

### 4. Normalize layer

`lib/jido_claw/error/normalize.ex` exposes per-domain entrypoints. Initial domains
chosen to cover the heaviest error-producing subsystems:

```elixir
@spec tool_error(term(), context()) :: Exception.t()
@spec forge_error(term(), context()) :: Exception.t()
@spec conversation_error(term(), context()) :: Exception.t()
@spec reasoning_error(term(), context()) :: Exception.t()
@spec session_error(term(), context()) :: Exception.t()
```

Each accepts `binary | atom | {atom, _} | Exception.t() | %JidoClaw.Error.*{}` and
returns `%JidoClaw.Error.*{}`. Passthrough on first-party errors. Context allow-list
(in `Normalize.Context.details/2`): `[:operation, :tenant_id, :request_id, :session_id,
:workspace_uuid, :agent_id, :run_id, :phase, :field, :value, :timeout]`.

**Ash error classification by class, not blanket-validation.** Inside each domain
entrypoint, dispatch on the Ash class:

```elixir
defp from_ash(%Ash.Error.Invalid{} = e, ctx), do: # → ValidationError
defp from_ash(%Ash.Error.Forbidden{} = e, ctx), do: # → ExecutionError (authz failure)
defp from_ash(%Ash.Error.Framework{} = e, ctx), do: # → ExecutionError (framework bug)
defp from_ash(%Ash.Error.Unknown{} = e, ctx), do: # → Internal.UnknownError
defp from_ash(other, ctx), do: # leaf or unrecognized — wrap as UnknownError
```

Jido and Jido.AI follow the same shape — dispatch on the foreign type, route
to the JidoClaw class that best matches the semantics.

`Normalize.Common`: `validation/4`, `execution/5`, `passthrough_or_validation/4`,
`passthrough_or_execution/4`, `timeout_error/3` — direct ports from Jidoka with
JidoClaw-specific reason vocabulary substituted (see Jidoka `error/normalize/common.ex`).

### 5. Retrofit `lib/jido_claw/tools/error.ex`

**Wire format preserved for legacy non-structured inputs.** Strings, atoms,
tagged tuples, and bare maps continue to produce the same `%{code:, message:, details:}`
shape they produce today. Migrated sites *intentionally* change codes (e.g. from
the generic fallback `:tool_error` or `:failed` to `:validation_error` /
`:execution_error`) — that's the point of the contract.

Two new clauses near the top — one for leaf errors, one for class containers —
plus a strict `struct_code/1` mapping (no `phase` fall-through) and aggressive
details sanitization.

```elixir
@jido_claw_leaf_structs [
  JidoClaw.Error.ValidationError,
  JidoClaw.Error.ConfigError,
  JidoClaw.Error.ExecutionError,
  JidoClaw.Error.Internal.UnknownError
]

@jido_claw_class_structs [
  JidoClaw.Error.Invalid,
  JidoClaw.Error.Config,
  JidoClaw.Error.Execution,
  JidoClaw.Error.Internal
]

# Leaf — use Exception.message/1 (one error, one line).
def normalize(%struct{} = error) when struct in @jido_claw_leaf_structs do
  %{
    code: struct_code(error),
    message: Exception.message(error),
    details: sanitize_details(error_details(error))
  }
end

# Class container — use JidoClaw.Error.format/1 (handles multi-error class summary).
# Splode's default Exception.message/1 on a class may include stacktrace-heavy output;
# format/1 produces the curated "Multiple JidoClaw errors:\n- …" rendering instead.
def normalize(%struct{errors: errors, class: class} = error)
    when struct in @jido_claw_class_structs and is_list(errors) do
  %{
    code: struct_code(error),
    message: JidoClaw.Error.format(error),
    details: sanitize_details(%{
      class: class,  # use the :class atom Splode already set on the struct
      errors: Enum.map(errors, &child_error_summary/1)
    })
  }
end

# struct_code/1 — explicit mapping, NEVER conflate phase with code.
defp struct_code(%JidoClaw.Error.ValidationError{}), do: :validation_error
defp struct_code(%JidoClaw.Error.ConfigError{}),     do: :config_error
defp struct_code(%JidoClaw.Error.ExecutionError{}),  do: :execution_error
defp struct_code(%JidoClaw.Error.Internal.UnknownError{}), do: :unknown_error
defp struct_code(%JidoClaw.Error.Invalid{}),         do: :validation_error
defp struct_code(%JidoClaw.Error.Config{}),          do: :config_error
defp struct_code(%JidoClaw.Error.Execution{}),       do: :execution_error
defp struct_code(%JidoClaw.Error.Internal{}),        do: :internal_error
# Existing fallbacks (status/code/__exception__/_) unchanged.
```

The `:phase` field on `ExecutionError` continues to live in `details` (where it
belongs as a debugging hint), not in `:code`. Callers that need finer-grained
codes either:

1. Construct a `ValidationError`/`ConfigError` instead, or
2. Add an explicit `:code` key inside the `details` map via the constructor opts.

**Details sanitization** (`sanitize_details/1`) — recursively walks the details
map and:

- Replaces nested exception structs with `%{module: "File.Error", message: …}` —
  module is a **string** (`inspect(struct)`), not an atom, for JSON-ish stability
  on agent-facing surfaces.
- Drops PIDs, refs, ports, and stacktraces.
- Truncates strings >2 KB to a leading slice + `… (truncated)`.
- Truncates lists/maps that would serialize to >8 KB total.

This compensates for `OutputRedaction` and `OutputLimit` skipping structs
(`lib/jido_claw/tools/output_redaction.ex:20`,
`lib/jido_claw/tools/output_limit.ex:29`) — without explicit sanitization here,
raw exception payloads, `old_string` blobs, or large embeddings inside `details.cause`
would reach the agent.

`error_details/1` flattens the leaf's inner `:details` map into the wire details
map, then overlays the leaf-specific top-level fields (`:field`, `:value`,
`:phase`). For `UnknownError`, it also projects the `:error` field as a
sanitized representation. The wire shape ends up flat:

```elixir
# Leaf:  %ExecutionError{message: "Boom", phase: :read, details: %{cause: …, operation: :load}}
# Wire details: %{phase: :read, cause: …, operation: :load}
#                                ^^^^^^   ^^^^^^^^^^
#                                inner details flattened in, top-level field overlaid
```

Constructors MUST NOT put raw user payloads (like `old_string` blobs) into
`details:` to begin with — only metadata (field names, atom codes, IDs).

`child_error_summary/1` extracts `%{code:, message:}` from each child error.
It handles **three cases**:

1. `%JidoClaw.Error.*{}` — extract via `struct_code/1` + `Exception.message/1`
2. Other exceptions (foreign Splode leaves that `to_class/1` placed under a
   JidoClaw class, plain `defexception` structs) — `%{code: :foreign,
   module: inspect(struct), message: Exception.message(error)}`
3. Anything else — `%{code: :unknown, message: inspect(error)}`

The existing `def normalize(%module{} = reason)` generic-struct branch stays —
`%Ash.Error.*{}`, `%Jido.Error.*{}`, and any other foreign exception flows through
it with the legacy shape it produces today.

### 6. Convert `lib/jido_claw/forge/error.ex` to Splode

Five `defexception` modules → `use Splode.Error, class: :execution, fields: […]`. All five
land under the `:execution` class (no `:config` candidates; all are runtime failures).
Field lists stay identical. **`classify/1` keeps its `{kind, recovery}` return shape** —
it's the recovery-policy layer that hermes T1-4's `FailoverReason` will compose with
later.

Add Splode-form dispatch clauses to `classify/1`:

```elixir
def classify(%JidoClaw.Error.ExecutionError{phase: :provision}), do: {:provision_failed, :terminal}
def classify(%JidoClaw.Error.ExecutionError{phase: :bootstrap}), do: {:bootstrap_failed, :terminal}
def classify(%JidoClaw.Error.ExecutionError{phase: :timeout}),   do: {:timeout, :retry}
# legacy clauses on %ProvisionError{} etc. kept for symmetric coverage
```

No callers to update — verified zero references repo-wide.

### 7. Top-level `JidoClaw.format_error/1`

Add a one-line delegate in `lib/jido_claw.ex` near `version/0`:

```elixir
@spec format_error(term()) :: String.t()
defdelegate format_error(error), to: JidoClaw.Error, as: :format
```

### 8. Migrate representative `{:error, …}` sites — leaf tools only

**Scope rule**: migrate only **leaf tool modules whose public surface IS the
normalized tool result** (i.e. the only consumer is `Tools.Action.__before_compile__`
flowing through `Tools.Error.normalize/1`). Any module with direct callers or
tests asserting on string error reasons is **deferred** until each caller is
audited and moved to explicit `JidoClaw.format_error/1` formatting.

**Pre-migration audit for each candidate**:

1. Direct callers outside the tool's own file:
   `rg "JidoClaw\.Tools\.<ModuleName>" lib/ test/`
2. Tests asserting on the string:
   `rg -F "<exact error string>" test/`
3. If either is non-empty, defer the migration and leave a TODO referencing this plan.

**Initial migration set** (audit-then-convert):

- `lib/jido_claw/tools/get_agent_result.ex:30` — `"Agent '…' not found."` →
  `JidoClaw.Error.not_found(:agent, agent_id)`
- `lib/jido_claw/tools/get_agent_result.ex:68,71` — `{:error, %{agent_id, status, error}}` →
  `JidoClaw.Error.execution_error("Agent failed.", details: %{agent_id: …, status: …, code: status})`.
  Do NOT put `:status` in `phase:` (per finding 8 — phase ≠ code). The status atom
  goes into `details.code` for the wire.
- `lib/jido_claw/tools/edit_file.ex` — classify by reason, not blanket-validation:
  - `:62` `"old_string not found …"` → **`validation_error/2`** with `field: :old_string`
    (agent-correctable input error). Do NOT include the blob in `details:` — only
    the path and a short truncated preview.
  - `:55` `"Cannot read …"` → **`execution_error/2`** with `phase: :read` (filesystem
    failure; reason isn't classified into agent-correctable categories yet). Once a
    reason taxonomy exists, refine.
  - `:82` `"Failed to write …"` → **`execution_error/2`** with `phase: :write`
    (runtime filesystem failure).
- `lib/jido_claw/tools/spawn_agent.ex:57,101,124,127` and the simpler patterns in
  `lib/jido_claw/tools/kill_agent.ex:41`, `lib/jido_claw/tools/send_to_agent.ex:22,76,79` —
  audit each callsite individually; most map to `not_found/3` or `validation_error/2`.

**Explicitly deferred** (per review findings):

- `lib/jido_claw/reasoning/pipeline_validator.ex` and `pipeline_store.ex` —
  `pipeline_validator.ex:10` moduledoc declares string errors as a consumer
  contract, and `pipeline_store.ex:161` interpolates `#{reason}` directly.
  Converting to exception structs would crash interpolation. Defer until every
  caller is moved to explicit `JidoClaw.format_error/1`.
- `lib/jido_claw/shell/session_manager.ex:1464` — `"Command was cancelled"` is
  directly asserted in `test/jido_claw/shell/session_manager_vfs_test.exs:256`.
  Defer until that test (and any other direct callers) move to
  `JidoClaw.format_error/1` comparisons.
- `lib/jido_claw/tools/schedule_task.ex` — **migrate only at the `run/2` boundary**.
  Keep all private parser helpers (including `parse_schedule/1` and the
  validation-helper returns at `:130,:133,:147,:151,:155`) returning strings —
  they're interpolated at `:107`, and converting any of them to exception
  structs crashes the interpolation. Instead, the tool's outer clause can
  wrap a failed-validation result with `ValidationError.exception(message: msg, field: :schedule)`
  before returning `{:error, _}` to the agent. Runtime failures at `:99,:103`
  (persistence + scheduler) become `ExecutionError` at the same boundary.

The long tail of remaining `{:error, "string"}` sites continues to flow through
`Tools.Error.normalize/1` unchanged (non-breaking). Each subsequent migration
requires its own caller/test audit; the contract is in place to support that
iteration during code review.

### 9. Tests

```
test/jido_claw/error/format_test.exs              # port from jidoka/test/jidoka/error_format_test.exs
test/jido_claw/error/normalize_unit_test.exs      # port from jidoka/test/jidoka/error_normalize_unit_test.exs
test/jido_claw/error/tools_wire_format_test.exs   # NEW — Tools.Error.normalize over JidoClaw.Error structs
test/jido_claw/error/forge_classify_test.exs      # NEW — classify/1 over legacy + Splode shapes
test/jido_claw/error/foreign_interop_test.exs     # NEW — Ash / Jido / Jido.AI tree interop
```

**Drop** Jidoka tests for `invalid_context_schema/2` (Zoi-specific, not ported).

**`tools_wire_format_test.exs`** is the contract gate. It asserts the exact
`%{code:, message:, details:}` map for:

- Each leaf constructor (validation, config, execution, not_found, invalid_argument,
  timeout, missing_required)
- Each class-container shape (after `to_class/1`)
- Sanitization behavior: an exception passed in `details:` is replaced with
  `%{module: …, message: …}`; a string >2 KB is truncated; PIDs are dropped
- That `old_string` blobs passed accidentally do not reach the wire intact

**`foreign_interop_test.exs`** is the policy gate for the **Normalize layer**,
which is the actual conversion boundary. It does NOT pin exact `to_class/1`
behavior on raw foreign leaves — that's Splode-internal and may shift.

```elixir
# Normalize is the contract: any foreign error converts to JidoClaw.Error.*.
test "Normalize.tool_error/2 converts Ash invalid to JidoClaw ValidationError" do
  ash = Ash.Error.Invalid.exception(errors: [])
  assert %JidoClaw.Error.ValidationError{} = JidoClaw.Error.Normalize.tool_error(ash)
end

test "Normalize.tool_error/2 routes Ash.Forbidden to JidoClaw ExecutionError" do
  # Forbidden is not an input-validation error — don't classify it as ValidationError.
  forbidden = Ash.Error.Forbidden.exception(errors: [])
  assert %JidoClaw.Error.ExecutionError{} = JidoClaw.Error.Normalize.tool_error(forbidden)
end

test "Normalize.tool_error/2 converts a Jido.Error to JidoClaw" do
  jido = Jido.Error.validation_error("bad input", field: :foo)
  assert %JidoClaw.Error.ValidationError{} = JidoClaw.Error.Normalize.tool_error(jido)
end

test "Normalize.tool_error/2 converts a Jido.AI error leaf to JidoClaw" do
  ai = Jido.AI.Error.API.Request.exception(message: "upstream 500")
  assert %JidoClaw.Error.ExecutionError{} = JidoClaw.Error.Normalize.tool_error(ai)
end

# Ash class containers do flatten cleanly through to_class/1 — this is the
# guarantee merge_with: [Ash.Error] actually provides.
test "Ash.Error.Invalid container survives JidoClaw.Error.to_class/1" do
  ash = Ash.Error.Invalid.exception(errors: [])
  assert %Ash.Error.Invalid{} = JidoClaw.Error.to_class(ash)
end

# Passthrough — first-party errors are returned unchanged.
test "Normalize.tool_error/2 is idempotent on JidoClaw errors" do
  err = JidoClaw.Error.validation_error("x")
  assert ^err = JidoClaw.Error.Normalize.tool_error(err)
end
```

These tests pin the Normalize boundary so a future refactor that changes the
conversion behavior is loud rather than silent.

## Critical files (modify or create)

- `lib/jido_claw/error.ex` *(NEW)* — Splode registration, constructors, `format/1`
- `lib/jido_claw/error/{invalid,execution,config,internal}.ex` *(NEW)* — class containers
- `lib/jido_claw/error/internal/unknown_error.ex` *(NEW)* — registered `unknown_error:`
- `lib/jido_claw/error/{validation_error,config_error,execution_error}.ex` *(NEW)* — leaves
- `lib/jido_claw/error/normalize.ex` *(NEW)* — per-domain entrypoints
- `lib/jido_claw/error/normalize/{common,context}.ex` *(NEW)* — shared helpers
- `lib/jido_claw/tools/error.ex` *(MODIFY)* — add `%JidoClaw.Error.*{}` clause + `struct_code/1` mapping; preserve wire shape
- `lib/jido_claw/forge/error.ex` *(MODIFY)* — five `defexception` → `use Splode.Error`; extend `classify/1`
- `lib/jido_claw.ex` *(MODIFY)* — `defdelegate format_error/1` near `version/0` (line ~33)
- `test/jido_claw/error/*.exs` *(NEW)* — five test files above (format, normalize_unit, tools_wire_format, forge_classify, foreign_interop)
- Site migrations listed in step 8

## Reference implementations to reuse

- `deps/splode/lib/splode.ex` — `use Splode` macro options; behaviour
- `deps/splode/lib/splode/error.ex` — `use Splode.Error, class:, fields:`
- `deps/splode/lib/splode/error_class.ex` — `use Splode.ErrorClass, class:`
- `deps/ash/lib/ash/error/error.ex` — canonical `use Splode` shape (with `merge_with`)
- `deps/ash/lib/ash/error/invalid.ex` — class-container shape
- `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error.ex` — full reference (~334 LOC)
- `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error/normalize.ex` — domain entrypoints
- `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error/normalize/common.ex` — helpers
- `/Users/rickdunkin/workspace/claws/jidoka/lib/jidoka/error/normalize/context.ex` — allow-list

## Pitfalls

- **`to_class/1` is an aggregator, not a policy gate.** Splode 0.3 leaves with
  `splode: nil` (the default before they're attached to a tree) may flow through
  another tree's `to_class/1` without being wrapped as Unknown. Don't rely on
  `to_class/1` to enforce "Jido errors stay foreign" — the `Normalize` layer is
  the enforcement boundary. `merge_with: [Ash.Error]` only meaningfully guarantees
  that *typed* Ash class containers (`%Ash.Error.Invalid{errors: [...]}`) survive
  `to_class/1` flattening.

- **`merge_with: [Ash.Error]` is still effectively irreversible.** Removing it later
  can cause Ash class containers to be re-wrapped through `to_class/1`, silently
  changing return types. Document the decision in the `JidoClaw.Error` moduledoc.

- **Leaf vs class wire handling is different.** Use **`Exception.message/1`** for a
  single leaf (`%ValidationError{}`, etc.). Use **`JidoClaw.Error.format/1`** for a
  class wrapper (`%Invalid{errors: [...]}`) — Splode's default `Exception.message/1`
  on a class can include stacktrace-heavy output. The retrofit has two distinct
  clauses (step 5) for this reason.

- **`exception/1` defaults are load-bearing.** Forgetting `Keyword.put_new(:message, …)` in
  a leaf's `exception/1` gives `Exception.message/1 → ""` when no message is supplied.
  `UnknownError.exception/1` additionally derives the message from `opts[:error]` —
  not just a generic fallback (step 1). Port both patterns into the relevant leaves
  verbatim.

- **Do NOT conflate `phase` with wire `code`.** `ExecutionError`'s `:phase` field is
  a debugging hint (where it failed), not a machine-readable error kind. `struct_code/1`
  maps `ExecutionError → :execution_error` regardless of phase; callers that want a
  finer-grained code construct a different leaf or set `details.code` explicitly. This
  is the cause of finding 8.

- **`details` must be sanitized before reaching the wire.** `OutputRedaction`
  (`lib/jido_claw/tools/output_redaction.ex:20`) and `OutputLimit`
  (`lib/jido_claw/tools/output_limit.ex:29`) intentionally skip structs, so raw
  exceptions, PIDs, refs, stacktraces, and large blobs passed in `details:` reach
  the agent untouched without explicit sanitization in `Tools.Error.normalize/1`.
  `sanitize_details/1` (step 5) is mandatory, and constructors should never put
  user payloads like `old_string` or full file contents into `details:` to begin
  with.

- **`to_class/2` surprise for plain-`defexception` muscle memory.** Splode's
  `to_class/1` takes an error **value** (or list), not a result tuple. `Error.to_class(err)`
  is correct; `Error.to_class({:error, err})` treats the tuple as the payload and
  produces wrong output. See `deps/splode/lib/splode.ex:370`.

- **String errors are sometimes a public contract.** `PipelineValidator` /
  `PipelineStore` and `SessionManager` cancellation paths return strings that
  callers interpolate or directly assert on (`pipeline_store.ex:161`,
  `session_manager_vfs_test.exs:256`). Migrating these requires moving every
  caller to `JidoClaw.format_error/1` first — they're explicitly deferred
  in step 8.

- **CI tests that string-match on legacy error messages.** Any migrated site whose error
  message changes (e.g. from `"Failed to schedule task: …"` to a structured
  `invalid_argument`) requires the corresponding test to be updated. Tests in
  `test/jido_claw/tools/`, `test/jido_claw/forge/`, and `test/jido_claw/reasoning/` are
  the likely fallout — fix them rather than reverting the migration.

- **No first-party Ash error construction exists today.** We do not need to convert any
  `raise Ash.Error.*` sites — there are none. Ash error interop is purely consumer-side
  pattern matching, which `merge_with: [Ash.Error]` keeps stable.

- **Jido and Jido.AI errors are NOT merged — but this is documentary, not enforced.**
  Tool flows that bubble up Jido/Jido.AI exceptions must go through
  `Normalize.tool_error/2` explicitly to get a guaranteed `%JidoClaw.Error.*{}`.
  Splode may still pass raw foreign leaves through `to_class/1` without wrapping
  them; that behavior is best-effort. The architecture section spells out the
  rule: "Normalize is the boundary."

## Verification

1. **Compile clean**: `mix compile --warnings-as-errors` after each major step. Splode
   warns on field-name collisions (e.g. if a leaf field collides with a reserved Splode
   field like `:vars` or `:bread_crumbs`); the field lists chosen here don't collide.

2. **Format**: `mix format --check-formatted`.

3. **Unit tests**: `mix test test/jido_claw/error/` — all five new files. The
   wire-format and foreign-interop tests are the contract gates.

4. **Regression suite**: `mix test` — full run. Failures will concentrate in
   `test/jido_claw/tools/` and `test/jido_claw/forge/` if string-matching tests caught
   migrated messages; update those tests.

5. **Live smoke**: from `iex -S mix`, exercise the wire path end-to-end:

   ```elixir
   alias JidoClaw.Error
   alias JidoClaw.Tools.Error, as: Wire

   # Constructor produces leaf struct
   err = Error.not_found(:agent, "abc")
   #=> %JidoClaw.Error.ValidationError{field: :agent, value: "abc", message: "Agent 'abc' not found.", …}

   # Wire format — leaf uses Exception.message/1. Details are flat.
   Wire.normalize(err)
   #=> %{code: :validation_error, message: "Agent 'abc' not found.", details: %{field: :agent, value: "abc"}}

   # format/1 single-line
   JidoClaw.format_error(err)
   #=> "Agent 'abc' not found."

   # Class wrapping — to_class/1 takes the error VALUE, not a result tuple.
   class = Error.to_class(err)
   #=> %JidoClaw.Error.Invalid{errors: [%ValidationError{…}]}

   # Wire format — class uses JidoClaw.Error.format/1
   Wire.normalize(class)
   #=> %{code: :validation_error, message: "Agent 'abc' not found.", details: %{class: :invalid, errors: [...]}}

   # Ash class container passes through to_class/1 (merge_with: [Ash.Error])
   ash = Ash.Error.Invalid.exception(errors: [])
   Error.to_class(ash)
   #=> %Ash.Error.Invalid{…}

   # Normalize is the actual conversion boundary — works for any foreign tree.
   jido = Jido.Error.validation_error("bad", field: :foo)
   JidoClaw.Error.Normalize.tool_error(jido)
   #=> %JidoClaw.Error.ValidationError{message: "bad", field: :foo, …}

   ai = Jido.AI.Error.API.Request.exception(message: "upstream 500")
   JidoClaw.Error.Normalize.tool_error(ai)
   #=> %JidoClaw.Error.ExecutionError{message: "upstream 500", …}

   # Sanitization — exception in details is flattened and replaced.
   # `:module` is a string for JSON-ish stability.
   err2 = Error.execution_error("Boom",
     phase: :load,
     details: %{cause: %File.Error{path: "/x", reason: :enoent, action: "read"}, operation: :load_file})
   Wire.normalize(err2).details
   #=> %{
   #     phase: :load,
   #     operation: :load_file,
   #     cause: %{module: "File.Error", message: "could not read file \"/x\": no such file or directory"}
   #   }
   ```

6. **MCP / CLI tool exercise**: in the REPL, call a migrated tool with a bad argument
   (e.g. `get_agent_result agent_id=missing`) and confirm the agent-visible error map
   has the new `code: :validation_error` instead of `code: :tool_error`.

7. **Tidewave eval** (`mcp__tidewave__project_eval`) for ad-hoc checks against the
   running app.

## Out of scope (deferred to iteration during code review)

- The long tail of `{:error, "string"}` site migrations beyond the canary set in step 8.
- LiveView / Phoenix-controller / MCP-server error rendering overhauls — they continue
  to render via `inspect/1` and the agent wire map; a `JidoClaw.format_error/1`-based
  refactor of those surfaces can land in follow-up.
- `hermes T1-4` (FailoverReason classifier) — composes *above* `Forge.Error.classify/1`,
  not part of T1-4.
- Schema-error / Zoi-bridge formatter in `format/1` — not ported (no caller).
