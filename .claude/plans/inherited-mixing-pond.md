# Code-review followups for `JidoClaw.Error` rollout

## Context

The Splode-based `JidoClaw.Error` contract from the previous plan
(`.claude/plans/please-review-docs-exploration-jidoka-fe-scalable-lark.md`)
shipped, but a follow-up review surfaced four issues. All four are validated
against the merged code:

1. **P1a — wire `details` can stop being a map.** `Tools.Error.sanitize_details/1`
   pipes its result through `cap_collection/1`, which replaces oversized maps
   with the string `"[truncated: map with N keys]"`. The documented wire shape
   is `%{code, message, details: map}` and `Tools.Error.t/0` declares
   `required(:details) => map()`, so consumers and the new test suite are
   exposed to a contract break for any leaf whose `details:` exceeds
   `@max_collection_bytes` (8 KB).
2. **P1b — string truncation can produce invalid UTF-8.** `truncate_string/1`
   slices with `binary_part/3` at byte 2048 and concatenates a marker. Multi-
   byte codepoints crossing that boundary leave the result as invalid UTF-8.
   `OutputLimit.valid_utf8_prefix/1` already implements the safe-trim helper
   for the same problem.
3. **P2 — PIDs/refs/ports are stringified instead of dropped.** The plan calls
   for dropping these (and stacktraces); the implementation stringifies them
   via `"[#{inspect(value)}]"`. The new test pins the stringify behavior,
   meaning the regression cement matches the bug. User has decided to align
   with the plan: drop them entirely.
4. **P3 — canary migrations are incomplete and undocumented.** The plan's
   step 8 explicitly listed `spawn_agent.ex:{57,101,124,127}`,
   `kill_agent.ex:41`, and `send_to_agent.ex:{22,73,78,81}` as audit-then-
   convert candidates with a "leave a TODO if deferred" rule. Only
   `send_to_agent:22` was migrated; the rest are still raw strings with no
   TODOs. User has decided to migrate the remaining sites (tests use
   `%{message: ...}` patterns that work with both shapes).

Goal: restore the wire-format contract, fix the UTF-8 hazard, realign with
the plan's PID-handling rule, and finish the canary migration set.

## Approach

### 1. Fix `sanitize_details/1` to always return a map (P1a)

`lib/jido_claw/tools/error.ex:230-237` is the only top-level entrypoint that
must guarantee `map()`. Replace the trailing `cap_collection(sanitized)` with
type-preserving truncation that preserves a small allow-list of useful
debugging keys:

```elixir
@kept_when_truncated [
  :phase, :field, :code, :status, :agent_id, :operation, :reason, :kind
]

def sanitize_details(value) when is_map(value) and not is_struct(value) do
  sanitized =
    value
    |> Enum.map(fn {k, v} -> {k, sanitize_value(v)} end)
    |> Enum.reject(fn {_k, v} -> drop?(v) end)
    |> Map.new()

  if approximate_byte_size(sanitized) > @max_collection_bytes do
    %{
      truncated: true,
      description: describe(sanitized),
      kept: Map.take(sanitized, @kept_when_truncated)
    }
  else
    sanitized
  end
end

def sanitize_details(_value), do: %{}
```

The allow-list is small on purpose — these are the keys consumers actually
log/route on (matching the wire-format tests and constructor opts). Adding
new ones is cheap; over-including risks the placeholder itself being too
large.

`cap_collection/1` stays in use for *inner* values (called from
`sanitize_value/1` on nested maps and lists at lines 254-265). Inner values
can legitimately end up as strings — `details: %{cause: %{...big map...}}`
becoming `details: %{cause: "[truncated: ...]"}` keeps the top-level map
shape intact and the type change is scoped to a value, not the contract.

### 2. Reuse UTF-8-safe truncation (P1b)

Two changes:

- Promote `valid_utf8_prefix/1` (and its private `trim_to_valid_utf8/2`)
  from `lib/jido_claw/tools/output_limit.ex:49-67` to a shared helper. The
  smallest change is to expose `OutputLimit.valid_utf8_prefix/1` as a
  `@doc false` public function (it's already pure) with a typespec, and call
  it from `Tools.Error`. Avoid a new shared module — both files already live
  under `lib/jido_claw/tools/`.

  ```elixir
  @doc false
  @spec valid_utf8_prefix(binary()) :: binary()
  def valid_utf8_prefix(value) do
    ...
  end
  ```
- Rewrite `truncate_string/1` in `lib/jido_claw/tools/error.ex:290-294`:

  ```elixir
  defp truncate_string(str) when is_binary(str) and byte_size(str) > @max_string_bytes do
    str
    |> binary_part(0, @max_string_bytes)
    |> JidoClaw.Tools.OutputLimit.valid_utf8_prefix()
    |> Kernel.<>("... (truncated)")
  end
  ```

  Result remains a binary; multi-byte codepoints straddling the 2048-byte
  cut are trimmed back to a valid UTF-8 boundary before the marker is
  appended.

### 3. Drop PIDs / refs / ports from sanitized details (P2)

`lib/jido_claw/tools/error.ex:251-252` currently emits an inspect string.
Replace with a tagged-tuple drop sentinel that the map-walk strips out, so
the keys vanish entirely. Use a tagged tuple (not an atom) to avoid
colliding with any legitimate user value:

```elixir
# Sentinel value emitted by sanitize_value/1 when an input must be removed
# entirely (PIDs, refs, ports). Tagged with __MODULE__ so a legitimate
# user-supplied atom can never collide.
@drop {__MODULE__, :drop}

defp drop?(@drop), do: true
defp drop?(_), do: false

defp sanitize_value(value) when is_pid(value) or is_reference(value) or is_port(value),
  do: @drop
```

In the map/list paths (lines 254-266), filter the sentinel via `drop?/1`:

```elixir
defp sanitize_value(value) when is_map(value) do
  value
  |> Enum.map(fn {k, v} -> {k, sanitize_value(v)} end)
  |> Enum.reject(fn {_k, v} -> drop?(v) end)
  |> Map.new()
  |> cap_collection()
end

defp sanitize_value(value) when is_list(value) do
  cond do
    stacktrace?(value) -> "[stacktrace dropped]"
    true ->
      value
      |> Enum.map(&sanitize_value/1)
      |> Enum.reject(&drop?/1)
      |> cap_collection()
  end
end
```

The same `Enum.reject/2` filter is already wired into `sanitize_details/1`
in step 1 so any top-level PID is removed before the byte-size check.

**Tuple handling (line 268)** — tuples used in `details:` are rare, but the
sentinel must not leak. Replace any dropped element with a visible neutral
marker so agent-facing output never contains the internal sentinel:

```elixir
defp sanitize_value(value) when is_tuple(value) do
  value
  |> Tuple.to_list()
  |> Enum.map(&sanitize_value/1)
  |> Enum.map(fn v -> if drop?(v), do: :dropped_runtime_handle, else: v end)
  |> List.to_tuple()
end
```

This preserves tuple arity (changing it would be more surprising than the
marker) while keeping `{__MODULE__, :drop}` out of agent context.

**Update the pinned test** at
`test/jido_claw/error/tools_wire_format_test.exs:155-161`:

```elixir
test "PIDs and refs in details are dropped, not leaked" do
  err =
    Error.validation_error("ok", details: %{worker: self(), token: make_ref(), kept: :ok})

  wire = Wire.normalize(err)

  refute Map.has_key?(wire.details, :worker)
  refute Map.has_key?(wire.details, :token)
  assert wire.details.kept == :ok
end
```

PID + ref coverage is enough for the shared guard clause; skip port testing
(spawning a real port is OS-fragile and the clause is shared, so a passing
PID/ref test transitively covers ports).

### 4. Finish the canary migrations (P3)

For each site below, replace the legacy `{:error, "string"}` with the
appropriate `JidoClaw.Error.*` constructor. Confirmed safe because the only
tests that pattern-match these are
`spawn_agent_test.exs:{104,118}` and `send_to_agent_test.exs:{82,86}`, all
of which use `%{message: ...}` — that matches both legacy wire maps and
`%JidoClaw.Error.ValidationError{}` directly. No `kill_agent` tests exist.

**Message-preservation rule.** Two of the proposed migrations below
*intentionally* move the inspected reason out of the message body and into
structured `details:` — `spawn_agent:57` drops the `: #{inspect(reason)}`
tail; `send_to_agent:73,81` drop their `:#{inspect(...)}` tails. The
information is preserved (in `details.reason` / `details.metadata`), the
agent-visible message is cleaner, and no test asserts on the dropped
substring. Sites where the existing message is referenced by a test (`is
already in use.`, `not registered in AgentTracker`) keep their wording
verbatim.

**`lib/jido_claw/tools/spawn_agent.ex`:**

- `:57` `"Failed to spawn agent: #{inspect(reason)}"` →
  `JidoClaw.Error.execution_error("Failed to spawn agent.", phase: :spawn,
  details: %{reason: inspect(reason), template: template_name})`
  *(message change: tail moves to `details.reason`)*
- `:101` `"Agent ID '#{tag}' is already in use."` →
  `JidoClaw.Error.validation_error("Agent ID '#{tag}' is already in use.",
  field: :tag, value: tag, details: %{reason: :agent_id_taken})`
  *(message preserved verbatim — pinned by `spawn_agent_test.exs:104`)*
- `:124,:127` (same string in `ensure_agent_id_available/1`) — same
  `validation_error/2` shape as `:101`. Extract a small helper to avoid
  the duplicated literal.

Add `alias JidoClaw.Error` at the top (mirroring `get_agent_result.ex:21`).

**`lib/jido_claw/tools/kill_agent.ex:41`:**

- `"Agent '#{params.agent_id}' not found."` →
  `JidoClaw.Error.not_found(:agent, params.agent_id)` (the exact constructor
  already used at `send_to_agent.ex:24` and `get_agent_result.ex:31`).

Add `alias JidoClaw.Error` at the top.

**`lib/jido_claw/tools/send_to_agent.ex`:**

- `:73` `"Template '#{template_name}' for agent '#{agent_id}' is unavailable:
  #{inspect(reason)}"` →
  `JidoClaw.Error.execution_error("Template '#{template_name}' for agent
  '#{agent_id}' is unavailable.", phase: :template_lookup, details:
  %{template: template_name, agent_id: agent_id, reason: inspect(reason)})`
  *(message change: `: #{inspect(reason)}` tail moves to `details.reason`)*
- `:78` `"Agent '#{agent_id}' is running but is not registered in
  AgentTracker."` →
  `JidoClaw.Error.execution_error("Agent '#{agent_id}' is running but is
  not registered in AgentTracker.", phase: :tracker_lookup, details:
  %{agent_id: agent_id, reason: :not_registered})`
  *(message preserved verbatim — pinned by `send_to_agent_test.exs:82`)*
- `:81` `"Agent '#{agent_id}' has invalid tracker metadata: #{inspect(other)}"`
  → `JidoClaw.Error.execution_error("Agent '#{agent_id}' has invalid tracker
  metadata.", phase: :tracker_lookup, details: %{agent_id: agent_id, metadata:
  inspect(other)})`
  *(message change: `: #{inspect(other)}` tail moves to `details.metadata`)*

The `alias JidoClaw.Error` is already at the top of `send_to_agent.ex:18`.

Re-confirm the test assertions still match after migration:

- `spawn_agent_test.exs:104,118` look for `%{message: "Agent ID '...' is
  already in use."}`. `%ValidationError{message: ...}` satisfies that.
- `send_to_agent_test.exs:82` does a regex on `~= "not registered in
  AgentTracker"`. The new `ExecutionError` message includes that phrase
  verbatim.
- `send_to_agent_test.exs:86` looks for `%{message: "Agent 'missing' not
  found."}`. Already going through `Error.not_found/3` at `:24`, unchanged.

**Add structured-wire assertions** to lock in that the migration actually
happened — not just that the message survived. Pick one branch per migrated
tool and pattern-match through `Wire.normalize/1`:

```elixir
# spawn_agent_test.exs — extend the `:agent_id_taken` test
assert {:error, %JidoClaw.Error.ValidationError{} = err} =
         SpawnAgent.run(%{template: "coder", task: "do work", tag: "coder_existing"},
                         %{tool_context: %{}})

wire = JidoClaw.Tools.Error.normalize(err)
assert wire.code == :validation_error
assert wire.details.field == :tag
assert wire.details.value == "coder_existing"
assert wire.details.reason == :agent_id_taken

# kill_agent_test.exs (new) — assert not_found shape
{:error, %JidoClaw.Error.ValidationError{} = err} =
  KillAgent.run(%{agent_id: "missing"}, %{})

wire = JidoClaw.Tools.Error.normalize(err)
assert wire.code == :validation_error
assert wire.details.kind == :agent
assert wire.details.reason == :not_found

# send_to_agent_test.exs — extend the tracker-missing test
{:error, %JidoClaw.Error.ExecutionError{} = err} =
  SendToAgent.run(%{agent_id: "untracked_123", message: "hello"}, %{})

wire = JidoClaw.Tools.Error.normalize(err)
assert wire.code == :execution_error
assert wire.details.phase == :tracker_lookup
assert wire.details.reason == :not_registered
```

This is the difference between "message survived" and "migration happened" —
without these, the `%{message: ...}` patterns silently pass on the legacy
shape too.

### 5. Test additions / updates

- `test/jido_claw/error/tools_wire_format_test.exs`:
  - Replace the PID test (`:155-161`) with the drop assertion in Step 3.
  - Add a test asserting that an oversized details map stays a map:
    `assert is_map(wire.details)`, `assert wire.details.truncated == true`,
    `assert wire.details.description =~ "map with"`, and
    `assert wire.details.kept[:phase] == :load` (using a `phase:` in the
    oversized input to prove the allow-list survives). Pins P1a regression-
    free without baking in an exact key count.
  - Add a UTF-8 test: build a 3 KB binary of `"€"` repeats, push through
    `details: %{blob: huge}`, assert `String.valid?(wire.details.blob)` and
    `String.ends_with?(wire.details.blob, "... (truncated)")` — pins P1b.
- `test/jido_claw/tools/spawn_agent_test.exs` and
  `test/jido_claw/tools/send_to_agent_test.exs`: keep the existing
  `%{message: ...}` assertions and *extend* one branch each with the
  structured-wire pattern shown in Step 4 (`code`, `details.field`,
  `details.reason`, etc.) so the migration is actually pinned.
- `test/jido_claw/tools/kill_agent_test.exs` *(new)*: the `KillAgent.run/2`
  return is the raw `%JidoClaw.Error.ValidationError{}` (no wrapper
  normalizes it at the call boundary), so the test calls
  `JidoClaw.Tools.Error.normalize(err)` itself to assert the wire shape, as
  shown in Step 4.

### 6. Verification

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/jido_claw/error/
mix test test/jido_claw/tools/spawn_agent_test.exs test/jido_claw/tools/send_to_agent_test.exs
mix test
```

Live smoke (from `iex -S mix`):

```elixir
alias JidoClaw.Error
alias JidoClaw.Tools.Error, as: Wire

# P1a — large details stays a map
huge = Map.new(1..200, fn i -> {:"k#{i}", String.duplicate("x", 100)} end)
wire = Wire.normalize(Error.validation_error("ok", details: huge))
true = is_map(wire.details)
%{truncated: true} = wire.details

# P1b — UTF-8 survives
blob = String.duplicate("€", 1_000)
wire = Wire.normalize(Error.validation_error("ok", details: %{blob: blob}))
true = String.valid?(wire.details.blob)

# P2 — PIDs are dropped
wire = Wire.normalize(Error.validation_error("ok", details: %{w: self(), kept: 1}))
false = Map.has_key?(wire.details, :w)
1 = wire.details.kept

# P3 — kill_agent returns a structured error
{:error, %JidoClaw.Error.ValidationError{field: :agent}} =
  JidoClaw.Tools.KillAgent.run(%{agent_id: "missing"}, %{})
```

## Critical files

- `lib/jido_claw/tools/error.ex` — `sanitize_details/1`, `sanitize_value/1`
  PID clause, `truncate_string/1`, new `@drop` sentinel + filter helpers.
- `lib/jido_claw/tools/output_limit.ex` — promote `valid_utf8_prefix/1` to
  a public `@doc false` function (no behavior change).
- `lib/jido_claw/tools/spawn_agent.ex` — three `{:error, "string"}` sites
  + `alias`.
- `lib/jido_claw/tools/kill_agent.ex` — one site + `alias`.
- `lib/jido_claw/tools/send_to_agent.ex` — three `{:error, "string"}` sites
  in `template_for_agent/1`.
- `test/jido_claw/error/tools_wire_format_test.exs` — update PID test,
  add oversized-map test, add UTF-8 test.

## Pitfalls

- **Sentinel collisions.** Using a tagged tuple `{__MODULE__, :drop}` instead
  of a bare atom means a legitimate `details:` value of any atom can never
  vanish silently. Always check with the private `drop?/1` helper, never with
  direct equality against the literal — the tagged form makes future
  refactors safer.
- **Tuple sentinel must not leak.** `sanitize_value/1` for tuples replaces
  any dropped element with the public-facing `:dropped_runtime_handle` atom
  instead of leaving the internal `@drop` sentinel in agent context.
  Changing tuple arity is worse than leaving a marker.
- **`OutputLimit.valid_utf8_prefix/1` visibility.** Making it public is a
  trivial change but technically widens the public surface of a tool module.
  Mark `@doc false` and include `@spec valid_utf8_prefix(binary()) ::
  binary()` so the contract is explicit. The alternative (duplicating ~15
  LOC across two files) is the worse trade.
- **Migration error-message wording.** Tests use `=~` and exact-string
  matches. The Step 4 table is explicit about which messages preserve their
  text verbatim and which drop their `inspect(...)` tails into `details:`.
  When in doubt, preserve the message and add `details:` alongside it.
- **`%{message: ...}` patterns are weak migration evidence.** They match
  both legacy wire maps and `%JidoClaw.Error.*{}` structs, so a passing test
  doesn't prove the migration happened. Step 4 adds structured-wire
  assertions (`code`, `details.field`, `details.reason`) to lock in the
  conversion.
- **`cap_collection/1` still in use inside `sanitize_value/1`.** Don't
  delete it — inner-value truncation to a string is still acceptable since
  `details` values are any type. The contract only constrains the
  top-level `details` *itself* to be a map.
