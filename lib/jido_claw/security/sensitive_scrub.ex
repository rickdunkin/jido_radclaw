defmodule JidoClaw.Security.SensitiveScrub do
  @moduledoc """
  Centralized placeholder/digest policy for `sanitize_sensitive_context`
  (AR-2 Phase 2b, Theme B): one definition so every durable sink redacts to
  identical, type-correct placeholders.

  When a composer subagent's turn is marked sensitive, every durable sink its
  derived output reaches (Recorder, Audit, Trace, SubagentTranscript,
  OutputShaper, MCPScope) replaces the content with a placeholder from here —
  **whole-write sanitization, never row-suppression** (P2): a sanitized row is
  written so durable subagent context survives.

  ## Type-preserving placeholders (P3-1)

  A bare string in a `:map` column breaks the cast and downstream consumers, so
  each sink applies the helper matching the **destination column/field type** it
  writes:

    * `redacted_text/0` — string fields (`messages.content`,
      `ToolOutput.content`/`command`, a `run_failed` `:error` string leaf).
    * `redacted_map/0` — `:map` fields (`messages.metadata`,
      `Audit.Event.payload` sub-maps, `WorkflowStep.output` / `WorkflowRun.result`,
      trace `metadata`/`measurements`, `typed_output`).
    * `redacted_summary/0` — a shape-valid `ToolOutput.summary` map placeholder.

  The `command_fingerprint` leak is handled at the sink, not here: a marked
  `run_command` skips the delta path entirely and stores `command_fingerprint:
  nil` (no equality oracle, no raw hash at rest) — see `OutputShaper.Store`.
  """

  @redacted_text "[composer-sensitive:redacted]"

  @doc "Placeholder for a redacted **string** field."
  @spec redacted_text() :: String.t()
  def redacted_text, do: @redacted_text

  @doc "Placeholder for a redacted **map** field (keeps the column a valid map)."
  @spec redacted_map() :: map()
  def redacted_map, do: %{"redacted" => true}

  @doc "Shape-valid placeholder for a redacted `ToolOutput.summary` map."
  @spec redacted_summary() :: map()
  def redacted_summary, do: %{"redacted" => true}
end
