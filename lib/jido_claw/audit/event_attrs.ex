defmodule JidoClaw.Audit.EventAttrs do
  @moduledoc """
  Builds the attrs map for an audit event.

  Centralizing the 7-key shape (`tenant_id`, `event_kind`, `actor_kind`,
  `actor_id`, `target_kind`, `target_id`, `payload`) keeps every
  producer / listener / plug emitting the identical contract that
  `JidoClaw.Audit.AsyncWriter` forwards into the `Audit.Event` create
  action.

  Returns a **plain map** (not a struct) so `AsyncWriter` can hand it
  straight to Ash without a `Map.from_struct/1` step.
  """

  @type t :: %{
          tenant_id: String.t() | nil,
          event_kind: atom(),
          actor_kind: atom(),
          actor_id: String.t() | nil,
          target_kind: atom(),
          target_id: String.t() | nil,
          payload: map()
        }

  @doc """
  Build an audit-event attrs map from keyword `opts`.

  `:payload` defaults to `%{}`; every other key is required (a missing
  one raises `KeyError`, surfacing the mistake at the call site).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %{
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      event_kind: Keyword.fetch!(opts, :event_kind),
      actor_kind: Keyword.fetch!(opts, :actor_kind),
      actor_id: Keyword.fetch!(opts, :actor_id),
      target_kind: Keyword.fetch!(opts, :target_kind),
      target_id: Keyword.fetch!(opts, :target_id),
      payload: Keyword.get(opts, :payload, %{})
    }
  end
end
