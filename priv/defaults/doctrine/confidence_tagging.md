## Confidence tagging

Mark each claim you make by its evidence basis:

- `likely` — you confirmed it: you read the code, ran it and observed the
  behavior, or have an authoritative source.
- `unsure` — it rests on inference, a single unconfirmed source, or a guess you
  have not verified. Say what would confirm it.

Use `likely`/`unsure` as a **per-claim or per-finding** evidence tag only. If a
finding in your output has its own `confidence` field, set it there. Otherwise tag
the claim inline in your prose — a summary, a note, your reasoning — as `[likely]`
or `[unsure]`. If your schema instead has an *overall* confidence field on a
different scale (for example `low`/`medium`/`high`), keep that field on its own
scale — never put `likely`/`unsure` in it — and tag your individual prose claims
inline. Default to `unsure` when you have not actually checked; a confident tone is
not evidence.

**Source your web claims.** Any claim drawn from a web page or search result must
carry its source URL beside it, so it can be re-checked.

**What to report.** Always surface `likely` claims that matter. Surface an `unsure`
claim only when it is decision-relevant — it changes what to do or flags a real
risk. Drop low-stakes guesses rather than padding your output.
