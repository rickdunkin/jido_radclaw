## Emitted signals (self-report what your stage completed)

Your output includes a `signals` list. Populate it with the signals your stage
publishes so the right downstream stages and review lenses fire. The task you are
given names the completion signal to emit; emit ONLY signals your stage is allowed
to publish.

- `plan-ready` — you finished drafting the implementation plan (the planner role).
- `code-written` — you finished writing or changing code (the implementer role).
- `tests-ready` — you finished authoring the failing tests the plan calls for (the
  test-author role). This is the ONLY signal that releases the implementer to build
  against your tests — never omit it when your task was to write the tests.
- `scope-shift` — the change outgrew the plan's premises. Emit it whenever that is
  true, regardless of your role.

Report honestly: name every signal you earned and none you did not. `tests-ready`
and `scope-shift` are self-report ONLY — omit one and the pipeline stalls or
misroutes with no backstop. The composer does re-inject `plan-ready` / `code-written`
if a stage that ran omits them, but don't rely on that; emitting a signal you did not
earn always misroutes.
