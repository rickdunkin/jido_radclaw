defmodule JidoClaw.Reasoning.Compactor.Prompt do
  @moduledoc """
  Default summarizer prompt used by `JidoClaw.Reasoning.Compactor.Summarizer`.

  Built for the **continuation** case (the LLM is being asked to produce a
  summary that an agent will then use to keep working). It is NOT a tutorial
  summary; the audience is the same agent on its next turn.
  """

  @doc """
  Returns the default summarizer instruction text.
  """
  @spec default_text() :: String.t()
  def default_text do
    """
    You are compressing earlier turns of an active agent conversation so the \
    agent can keep working without re-reading every message. Your output will \
    be injected back into the conversation as a single delimited summary \
    block; downstream turns will refer to it as the authoritative record of \
    everything that happened before the kept tail.

    Produce a single dense summary. Preserve, in this priority order:

    1. The user's high-level goal and any constraints they restated.
    2. Decisions the agent already committed to (file paths, function names, \
    chosen approaches, ruled-out approaches).
    3. Concrete results from tool calls that the next turn would need to act on \
    (file contents, search hits, command output, errors).
    4. Open questions, blockers, and TODOs the agent has not yet resolved.
    5. Anything the user explicitly asked the agent to remember.

    Drop:

    * Greetings, acknowledgments, small talk.
    * Repeated tool noise (re-issued identical searches, retried lookups).
    * The agent's internal deliberation when the outcome is already captured \
    elsewhere in the summary.

    Format the summary as plain prose with short paragraphs and a brief \
    bullet list of open items at the end. Do not invent details. Do not add \
    new instructions, only describe what happened. Stay under the requested \
    character budget.
    """
  end

  @doc """
  Builds the prompt body sent to the summarizer LLM.

    * `transcript` — pre-formatted transcript of the source turns.
    * `prior_summary` — previous compaction's `summary` field, or nil for the
      first compaction. When present, the LLM is asked to fold it into the
      new summary (continuity).
    * `max_chars` — instructs the LLM to stay under this many characters.
  """
  @spec build(String.t(), String.t() | nil, pos_integer()) :: String.t()
  def build(transcript, prior_summary, max_chars)
      when is_binary(transcript) and is_integer(max_chars) and max_chars > 0 do
    instructions = default_text()

    prior_section =
      case prior_summary do
        nil ->
          ""

        "" ->
          ""

        s when is_binary(s) ->
          """

          Prior summary (from an earlier compaction — fold its contents into the \
          new summary; do not omit details just because they are old):

          #{s}
          """
      end

    """
    #{instructions}
    #{prior_section}
    Source turns (chronological):

    #{transcript}

    Produce the summary now. Maximum #{max_chars} characters. Do not include any \
    preamble like "Here is the summary"; output the summary directly.
    """
  end
end
