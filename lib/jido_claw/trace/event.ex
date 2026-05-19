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
  """

  @type t :: %__MODULE__{
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
    measurements: %{},
    metadata: %{}
  ]
end
