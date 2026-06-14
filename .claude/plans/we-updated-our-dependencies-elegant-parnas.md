# Resolve `mix reach.check --smells --strict` findings surfaced by the dependency update

## Context

The same dependency bump that broke `credo --strict` (handled in the sibling plan
`we-just-updated-dependencies-vectorized-pearl.md`) also bumped **`reach` 2.7.1 → 2.7.5**, which
**adds a new cross-function smell, `redundant_computation`** ("duplicate pure calls within the same
function" — `deps/reach/lib/reach/smell/checks/redundant_computation.ex`). That step runs in the
`precommit` alias as `reach.check --arch --smells --strict` (`mix.exs:251`), so it now blocks
`mix precommit` locally (no CI gate — no `.github/`).

`mix reach.check --smells --strict` reports **6 findings, all `redundant_computation`**, in two
LiveViews:

- `lib/jido_claw/web/live/workflows_live.ex` — **4** findings (lines 213/219/223/229)
- `lib/jido_claw/web/live/setup_live.ex` — **2** findings (lines 35/42)

Every finding is the same message: `__live_event__ called twice with same args`. The flagged lines
are all `phx-click` attributes inside `~H` templates. The HEEx compiler lowers each `phx-click`
binding to an `__live_event__(...)` call in `render/1`; the detector groups calls by
`{module, function, arity}` within a sequential block and flags consecutive ones with identical args
(`same_args?`). So **repeated, structurally-identical `phx-click` bindings look like duplicate pure
calls** — even though each is a distinct DOM element. `reach --arch --strict` is already **OK**
(verified, exit 0), so these 6 smells are the *only* thing blocking the precommit reach step.

**Chosen strategy (confirmed with the user): refactor the templates so the repeated bindings collapse
to a single `__live_event__` call site each** — an honest dedup, not a suppression.

> Why not a config ignore? The per-kind `ignore:` block that scopes `fixed_shape_map`/`behaviour_candidate`
> in `.reach.exs` has **no equivalent for `redundant_computation`**: `Reach.Config` validates the keys
> allowed under `:smells` against `[:strict, :custom_checks, :ignore, :fixed_shape_map,
> :behaviour_candidate]` (`config.ex:786`), so adding a `redundant_computation:` block would be reported
> as an **unknown-key config error**, not a working ignore. The only suppression that applies to this
> smell is the inline file pragma `# reach:disable-for-this-file redundant_computation` (the precedent
> `inspection.ex` already sets for `bare_rescue`) — kept as the §3 fallback, not the primary fix.

## Changes

### 1. `setup_live.ex` — `for`-comprehension over the tabs + literal `handle_event` clauses
**(a) Template (fixes the 2 smells).** The three step-tab buttons (lines 26–46) are identical except
for the step id and label. Replace them with one comprehension; the lone `__live_event__("step", …)`
then exists once in the AST (inside the comprehension's function body), executed per-iteration at
runtime:

```heex
<div style="display: flex; gap: 0.25rem; margin-bottom: 1.5rem;">
  <%= for {step, label} <- [prerequisites: "Prerequisites", credentials: "Credentials", database: "Database"] do %>
    <button
      class={"btn #{if @step == step, do: "btn-primary"}"}
      phx-click="step"
      phx-value-step={step}
    >
      {label}
    </button>
  <% end %>
</div>
```

`step` is an atom from the keyword list; `phx-value-step={step}` renders it to the same string the
literals produced (`"prerequisites"`, …); `@step == step` is a direct atom compare.

**(b) Handler (idiomatic improvement requested in review).** Replace the current
`String.to_existing_atom/1` + `rescue ArgumentError` handler (`setup_live.ex:109-114`) with explicit
literal clauses, matching the repo's own documented convention in `workflows_live.ex:78-85`
("Explicit literal matching — never String.to_atom on params."). This drops rescue-as-control-flow and
prevents any arbitrary *existing* atom from becoming `@step`:

```elixir
@impl Phoenix.LiveView
def handle_event("step", %{"step" => "prerequisites"}, socket),
  do: {:noreply, assign(socket, step: :prerequisites)}

def handle_event("step", %{"step" => "credentials"}, socket),
  do: {:noreply, assign(socket, step: :credentials)}

def handle_event("step", %{"step" => "database"}, socket),
  do: {:noreply, assign(socket, step: :database)}

def handle_event("step", _params, socket), do: {:noreply, socket}
```

(The comprehension's atom values round-trip to exactly the strings these clauses match. `handle_event("recheck", …)` is unchanged.)

### 2. `workflows_live.ex` — extract a private `toggle_cell/1` function component
The 5 `<td>` cells (lines 209–231) inside `<%= for run <- @runs do %>` each carry an identical
`phx-click="toggle_steps" phx-value-id={run.id}`; only their style and content differ (the comment at
206–207 explains the toggle deliberately rides on the data cells, not the `<tr>`, so the Actions cell
never double-fires — preserve that intent). Move the binding into one component so `__live_event__`
appears once (inside `toggle_cell/1`); the parent loop body then holds only `toggle_cell` calls whose
args differ by content/style (no `same_args?` match).

Define near the other helpers (mirror the `core_components.ex:58-61` convention — `attr(...)` + `@spec`
+ head; `defp` is fine, `<.toggle_cell>` compiles to a local call). `run.id` is a `uuid_primary_key`
(`workflow_run.ex:197`), so the attr is a `:string` named `:run_id` (it is a value, not a DOM id):

```elixir
attr(:run_id, :string, required: true)
attr(:style, :string, default: "cursor: pointer;")
slot(:inner_block, required: true)

@spec toggle_cell(map()) :: Phoenix.LiveView.Rendered.t()
defp toggle_cell(assigns) do
  ~H"""
  <td phx-click="toggle_steps" phx-value-id={@run_id} style={@style}>
    {render_slot(@inner_block)}
  </td>
  """
end
```

Rewrite the 5 cells (cells 1/3/5 take the default style; 2/4 pass their full style string):

```heex
<.toggle_cell run_id={run.id}>{run.name}</.toggle_cell>
<.toggle_cell run_id={run.id} style="cursor: pointer; color: var(--muted);">
  {run.workflow_type || "—"}
</.toggle_cell>
<.toggle_cell run_id={run.id}><.status_badge status={run.status} /></.toggle_cell>
<.toggle_cell run_id={run.id} style="cursor: pointer; color: var(--muted); font-size: 0.875rem;">
  {format_time(run.started_at)}
</.toggle_cell>
<.toggle_cell run_id={run.id}><.deadline_badge evidence={run_view.deadline} /></.toggle_cell>
```

**Do not touch** the sibling action buttons (Cancel/Replay at 242–266) — distinct, non-repeated events
(`"cancel"`, `"replay"`). `handle_event("toggle_steps", …)` is unchanged. The expanded-steps sub-table
cells at 356/359 have no `phx-click` and are out of scope.

### 3. Fallback if a residual remains — file pragma, not more abstraction
Re-run reach after §1–§2. The expectation is 0 findings. If the function-component call sites somehow
still flag, **do not add further indirection to the HEEx to appease the detector** — apply the
kind-specific file pragma at the top of the affected module (after `use JidoClaw.Web, :live_view`),
which keeps every other smell running on the file:

```elixir
# reach:disable-for-this-file redundant_computation
# HEEx phx-* bindings lower to identical __live_event__ calls; each is a
# distinct DOM node, not a redundant computation (reach 2.7.5 false positive).
```

Keep the rationale short and avoid starting any wrapped comment line with the word "step" (ExSlop
EXS3004 trap).

### 4. Tests — close the coverage gap on the refactored surfaces
The existing `workflows_live_test.exs` covers only Cancel/Replay; there is **no** toggle-cell coverage
and **no** `setup_live_test.exs`. Add focused, direct-socket/direct-render coverage (the convention in
those tests — build assigns, call `render/0` or `handle_event/3`, assert on the string/return):

- **`test/jido_claw/web/live/workflows_live_test.exs`** (extend, reuse `render_runs/1`): assert a
  single rendered run row emits **exactly 5** `phx-click="toggle_steps"` bindings carrying
  `phx-value-id="#{run.id}"` (the 5 data cells), proving the toggle is on the data cells and the 6th
  (Actions) cell is excluded. This pins the "Actions cell does not toggle" invariant at the markup the
  refactor produces.
- **`test/jido_claw/web/live/setup_live_test.exs`** (new): assert the three literal `handle_event("step", …)`
  clauses each set `@step` to the right atom, and that an unknown step value is a no-op via the catch-all
  clause (`step` unchanged) — exactly the closed-set behavior introduced in §1(b). A render assertion
  that the 3 tab buttons appear (`phx-value-step="prerequisites|credentials|database"`) is a nice add;
  it needs a `@status` struct (`JidoClaw.Setup.Wizard.run()` produces one), so keep it optional if the
  env probe is awkward under test — the handler-clause tests are the required coverage.

## Critical files
- `lib/jido_claw/web/live/setup_live.ex` — `for`-comprehension over the tabs (template) + literal
  `handle_event("step", …)` clauses (handler)
- `lib/jido_claw/web/live/workflows_live.ex` — add private `toggle_cell/1`; rewrite the 5 toggle cells
- `test/jido_claw/web/live/workflows_live_test.exs` — toggle-cell / Actions-cell assertion (extend)
- `test/jido_claw/web/live/setup_live_test.exs` — new; step-clause + unknown-no-op coverage
- (fallback only, not expected) a `# reach:disable-for-this-file redundant_computation` pragma in the
  two LiveViews

## Verification
Run via `mise exec -- mix` (toolchain is mise-latest). Run gate commands **bare** (no `| tail` — a pipe
masks the real exit code; read the saved output instead):

1. `mix reach.check --smells --strict` → **must exit 0** (no `redundant_computation`). Direct proof the
   6 findings are gone.
2. `mix reach.check --arch --smells --strict` → exit 0 (the actual precommit step; arch already OK).
3. `mix format --check-formatted` (HEEx/`~H` is formatted).
4. `mix jidoclaw.compile_check` → no new warnings (the project's strict-compile gate per AGENTS.md).
5. `mix test test/jido_claw/web/live/setup_live_test.exs test/jido_claw/web/live/workflows_live_test.exs`
   → green (the new/extended coverage from §4), then `mix test test/jido_claw/web/live/` for the tier.
6. **Final gate:** `mix precommit` — must pass end-to-end (compile-check, format, reach, credo,
   dialyzer, test). Authoritative confirmation the blocker is cleared. (The credo half of this gate
   depends on the sibling `vectorized-pearl` plan also being applied.)

## Commit (per repo git policy — do NOT commit; user stages/commits)
Stage: `lib/jido_claw/web/live/setup_live.ex`, `lib/jido_claw/web/live/workflows_live.ex`,
`test/jido_claw/web/live/workflows_live_test.exs`, `test/jido_claw/web/live/setup_live_test.exs`.

Suggested message:
```
fix: clear reach --smells redundant_computation findings after reach 2.7.5 bump

reach 2.7.5 adds a redundant_computation smell that flags HEEx-compiled
__live_event__ calls from repeated phx-click bindings. Refactor the two
LiveViews so each binding compiles to a single call site:

- setup_live: collapse the 3 step-tab buttons into a `for` comprehension,
  and switch the "step" handler to explicit literal clauses (matching the
  repo convention; drops String.to_existing_atom + rescue)
- workflows_live: extract a private `toggle_cell/1` component for the 5
  clickable run cells (toggle stays on the cells, not the row)
- add toggle-cell + setup step-clause test coverage

No markup/behavior change; reach.check --arch --smells --strict is green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
