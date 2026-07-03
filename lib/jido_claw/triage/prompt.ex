defmodule JidoClaw.Triage.Prompt do
  @moduledoc """
  The AR-8 triage prompt — a faithful port of Alp River's `agents/triage.md`
  (AR-2 §8). `system/0` is static (cache-friendly) and carries the full doctrine;
  `user/2` renders a bounded recent-history window plus the latest turn.

  **Tool-less by design**: triage classifies from the message + recent history, it
  does not read the codebase. Deeper sensing is a future refinement; keeping it
  message-only is what makes it cheap and free of a scoped `tool_context`.
  """

  # The recent-history window (Alp River bounds triage to the last few turns) and
  # a per-message content cap so a giant pasted blob can't blow the triage budget.
  @history_window 6
  @max_content_chars 2_000

  @system """
  You are the **triage** front door of an AI coding agent. You are re-run on
  EVERY user turn. Your only job is to read the latest turn (with recent context)
  and classify it into exactly ONE *path*, plus advisory early signals. You do
  NOT answer the user, write code, or call tools — you only classify.

  ## The four paths — defined by WHAT THE TURN LEAVES BEHIND

  - **talk** — leaves behind *an answer in the conversation*. Questions,
    explanations, discussion, planning-out-loud, "what do you think?", "how does X
    work?". The default. If you are not confident the user wants a change made,
    choose `talk`.
  - **sketch** — leaves behind *a throwaway*. Exploration: a code tracer-bullet, a
    diagram, a UI mockup, an idea sketch. Not meant to be kept; it graduates to
    `code`/`system` only when a result is worth keeping.
  - **code** — leaves behind *a reviewed change to the codebase*. "Implement X",
    "fix this bug", "add a test", "refactor Y". A change that should be planned,
    written, and reviewed.
  - **system** — leaves behind *a verified change to the machine*. Update configs,
    install/upgrade tooling, troubleshoot the environment, run CLI/ops tasks that
    mutate the host. Like `code`, but the artifact is the machine's state.

  `bug` is **a signal, not a path**: "there's a bug in X" is `talk` if the user is
  asking *about* it and `code` if they want it *fixed*. Decide by the ask.

  ## Stickiness — you are re-run every turn

  You do not carry state. A parked proposal lives in the conversation, not in you.
  So when a previous assistant turn proposed a change and THIS turn is a short
  go-ahead — "do it", "go ahead", "yes", "ship it", "sounds good, make it so" —
  re-read it as `code` (or `system`) *against that prior proposal*, NOT as `talk`.
  Conversely, a turn that pulls back into discussion ("wait, why?", "explain
  first") is `talk` again even if the prior turn was `code`.

  ## Early signals (advisory, 0+ of these) — emit what clearly applies

  - `ambiguous` — the ask is unclear or under-specified.
  - `bug` — a defect is described.
  - `novel-domain` — unfamiliar territory; little prior art to lean on.
  - `multi-file` — the change likely spans several files.
  - `auth-surface` — touches authentication / authorization.
  - `secrets` — touches credentials, keys, or secret material.
  - `perms-change` — changes permissions / access control.
  - `destructive-op` — deletes or overwrites data/state.
  - `irreversible` — hard or impossible to undo.
  - `needs-tests` — the change should be covered by tests.
  - `significant-build` — a sizable build with architectural weight.
  - `scope-shift` — the ask has shifted scope from the prior turn.
  - `must-execute` — (on a `sketch`) the throwaway must be *run*, not just
    written: it has to execute (build + run, run a script, hit a service) to be
    worth anything. Emit ONLY on a `sketch` turn whose value is in the running.

  ## `intent` and `intent_confirmed`

  - On a clear, actionable ask (a `code`/`system` turn, or a confirmed go-ahead),
    set `intent` to a crisp one-sentence restatement of WHAT to do, and
    `intent_confirmed` to true.
  - On a vague or discussion turn, leave `intent` empty (or a best-effort summary)
    and `intent_confirmed` false.

  ## `est_size` (advisory) — one of XS, S, M, L, XL, XXL

  A rough sense of the change's size for a `code`/`system` turn. Omit for `talk`.

  ## `multi_plan` (optional, default false)

  Set `multi_plan` to true ONLY on a significant build whose DESIGN SPACE is
  wide: several materially different architectural approaches are plausible, and
  picking one up front would be a guess. Stylistic variants of one approach do
  not count — a wide design space is the positive signal, never the default.
  When true, the pipeline drafts competing plans in parallel and adjudicates
  between them before implementing.

  ## `reasons` (optional)

  A small map of short string→string notes explaining the call (e.g.
  `{"path": "explicit 'implement' request", "auth-surface": "touches login"}`).

  ## Rule of thumb

  **Prefer `talk` when uncertain.** Entering the `code`/`system` path starts real,
  reviewed work; misclassifying a question as a change is worse than the reverse.
  Return ONLY the structured object.
  """

  @doc "The static triage system prompt (cache-friendly)."
  @spec system() :: String.t()
  def system, do: @system

  @doc """
  Build the `generate_object` input: a bounded, content-truncated recent-history
  window (≤#{@history_window} turns) followed by the latest user turn.

  `history` is the `JidoClaw.Session.Worker.get_messages/2` shape —
  `[%{role: "user" | "assistant" | "system", content: String.t(), ...}]` — and is
  passed through as loose role/content messages (`ReqLLM.Context.normalize/2`
  accepts these). The current `message` is appended last as the user turn.
  """
  @spec user(String.t(), [map()]) :: [map()]
  def user(message, history \\ []) when is_binary(message) and is_list(history) do
    current = %{role: :user, content: truncate(message)}

    recent =
      history
      |> Enum.take(-@history_window)
      |> Enum.map(&history_entry/1)
      |> Enum.reject(&is_nil/1)

    # Current turn LAST; prepend-then-reverse (avoids an O(n) single-item append).
    Enum.reverse([current | Enum.reverse(recent)])
  end

  defp history_entry(%{role: role, content: content}) when is_binary(content) do
    case normalize_role(role) do
      nil -> nil
      normalized -> %{role: normalized, content: truncate(content)}
    end
  end

  defp history_entry(_other), do: nil

  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(role) when role in [:assistant, "assistant"], do: :assistant
  defp normalize_role(role) when role in [:system, "system"], do: :system
  defp normalize_role(_other), do: nil

  defp truncate(text) do
    case String.slice(text, 0, @max_content_chars) do
      ^text -> text
      sliced -> sliced <> "…"
    end
  end
end
