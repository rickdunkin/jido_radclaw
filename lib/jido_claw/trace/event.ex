defmodule JidoClaw.Trace.Event do
  @moduledoc """
  Normalized JidoClaw trace event.

  A `%JidoClaw.Trace.Event{}` is a flattened projection of a single
  Jido/Jido.AI telemetry event plus JidoClaw-specific lifecycle events
  (`[:jido_claw, <category>, :event]`). Events are appended to a
  `%JidoClaw.Trace{}` in order of `:seq` and carry their own
  correlation IDs so individual rows can be persisted and rehydrated
  without the surrounding trace.

  Atoms are used for `:source`, `:category`, `:event`, `:phase`, and
  `:status` because they're cheap to match on at query time. The
  persistence boundary (`JidoClaw.Trace.Persistence`) converts these
  to strings before writing to `trace_events.<source|category|...>`,
  keeping the schema open to new values without a migration.

  `schema_version/0` identifies the normalized event struct contract.
  The stable contract is the set of top-level struct fields; additive
  fields keep the same major version, while renaming or removing one
  requires a bump. Unlike Jidoka (in-memory only), jido_radclaw
  persists events to `trace_events`, so the stamp rides on every
  durable row as forward-migration insurance.
  """

  @schema_version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          seq: pos_integer(),
          at_ms: integer(),
          source: atom(),
          category: atom(),
          event: atom(),
          phase: atom() | nil,
          name: String.t() | nil,
          status: atom() | nil,
          duration_ms: non_neg_integer() | nil,
          request_id: String.t() | nil,
          run_id: String.t() | nil,
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          measurements: map(),
          metadata: map()
        }

  @doc """
  Returns the current normalized trace event schema version.

  Additive top-level fields keep the same major version. Renaming or
  removing a top-level field requires a new version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @enforce_keys [
    :seq,
    :at_ms,
    :source,
    :category,
    :event,
    :measurements,
    :metadata
  ]
  defstruct [
    :seq,
    :at_ms,
    :source,
    :category,
    :event,
    :phase,
    :name,
    :status,
    :duration_ms,
    :request_id,
    :run_id,
    :trace_id,
    :span_id,
    :parent_span_id,
    schema_version: @schema_version,
    measurements: %{},
    metadata: %{}
  ]
end
