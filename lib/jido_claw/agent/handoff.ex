defmodule JidoClaw.Agent.Handoff do
  @moduledoc """
  Value struct describing a single conversation-ownership handoff.

  A `%Handoff{}` records the moment a worker (or the main agent) decided
  to transfer ownership of a conversation to a different template. The
  registry (see `JidoClaw.Agent.Handoff.Registry`) keys an owner record
  on `{tenant_id, runtime_session_id}`; the same struct is also written
  into the conversation's preamble on the first post-handoff user turn
  and emitted as a `[:jido_claw, :handoff, :event]` telemetry event.

  ## Identity fields

    * `:tenant_id` and `:runtime_session_id` — registry key.
    * `:session_uuid` — `Conversations.Session` UUID, used for all Ash
      reads/writes during routing and metadata mirroring.

  Both ids are carried so the Router can serve `run_chat_turn` callers
  that have one but not the other (e.g., cold-start before the
  Session.Worker has been told its UUID).
  """

  @enforce_keys [
    :id,
    :tenant_id,
    :runtime_session_id,
    :session_uuid,
    :to_template,
    :to_module,
    :message,
    :occurred_at
  ]

  defstruct [
    :id,
    :tenant_id,
    :runtime_session_id,
    :session_uuid,
    :from_template,
    :to_template,
    :to_module,
    :message,
    :summary,
    :reason,
    :request_id,
    :occurred_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          runtime_session_id: String.t(),
          session_uuid: String.t() | nil,
          from_template: String.t() | nil,
          to_template: String.t(),
          to_module: module(),
          message: String.t(),
          summary: String.t() | nil,
          reason: String.t() | nil,
          request_id: String.t() | nil,
          occurred_at: DateTime.t(),
          metadata: map()
        }

  @doc """
  Build a `%Handoff{}` from a map of attributes.

  Auto-fills `:id` (UUID) and `:occurred_at` (`DateTime.utc_now/0`)
  when absent. All enforced keys must be present in `attrs`.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new_lazy(:id, &Ecto.UUID.generate/0)
      |> Map.put_new_lazy(:occurred_at, &DateTime.utc_now/0)

    struct!(__MODULE__, attrs)
  end
end
