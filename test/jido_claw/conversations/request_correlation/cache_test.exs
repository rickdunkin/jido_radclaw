defmodule JidoClaw.Conversations.RequestCorrelation.CacheTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.RequestCorrelation.Cache

  test "a deletion extends an active global rejection window by a full correlation TTL" do
    original = :sys.get_state(Cache)
    now = System.monotonic_time(:millisecond)

    on_exit(fn -> :sys.replace_state(Cache, fn _state -> original end) end)

    :sys.replace_state(Cache, fn state ->
      %{
        state
        | deleted_sessions: %{},
          deleted_session_order: :queue.new(),
          reject_puts_until: now + 1_000
      }
    end)

    assert :ok = Cache.delete_for_session(Ecto.UUID.generate())
    %{reject_puts_until: extended_until} = :sys.get_state(Cache)

    # RequestCorrelation's durable TTL and the cache fence are both ten
    # minutes. Leave a little scheduler tolerance while proving this deletion
    # received a fresh window rather than the previous one's 1s remainder.
    assert extended_until >= now + 599_000
  end
end
