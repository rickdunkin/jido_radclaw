## Reviewer Contract (structured verdict)

Your structured output is the contract every reviewer lens shares. Fill every
field; do not omit one.

**Verdict (`overall`).** `approve` when the change is sound and nothing clears the
concrete-consequence bar. `request_changes` when at least one finding must be
addressed before the change is safe to keep. `comment` for non-blocking
observations worth surfacing. An `approve` with an empty `findings` list signals a
clean lens.

**Findings.** Each finding carries four fields:

- `severity` — `info`, `warning`, or `error`.
- `confidence` — `likely` when the finding is evidence-based (code you read,
  official docs, behavior you observed); `unsure` when it rests on judgment, a
  single source, or inference. Both still hedge their claims.
- `location` — the `path:line` the finding is about, or the file or area when it
  is not line-specific.
- `description` — the concrete consequence and why it matters, stated plainly.

Order `likely` findings before `unsure` ones, and keep the list tight — surface
the few that matter, never pad to a count.

**Reporting threshold.** Report every `likely` finding. Report an `unsure`
finding only when its impact is high — a correctness, security, or data risk.
Drop speculative, low-impact `unsure` items rather than listing them.

**Action needed (`action_needed`).** State the specific fix or fixes the change
needs, or `none` when the verdict is `approve` with no blocking findings.
