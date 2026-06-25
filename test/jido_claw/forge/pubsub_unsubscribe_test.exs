defmodule JidoClaw.Forge.PubSubUnsubscribeTest do
  @moduledoc "AR-8b-2 F2 (1.1): `Forge.PubSub.unsubscribe/1` drops the session topic."
  use ExUnit.Case, async: true

  alias JidoClaw.Forge.PubSub

  test "unsubscribe/1 stops delivery of later session broadcasts" do
    sid = "pubsub_unsub_#{:erlang.unique_integer([:positive])}"

    :ok = PubSub.subscribe(sid)
    PubSub.broadcast(sid, {:ping, sid})
    assert_receive {:ping, ^sid}, 1_000

    :ok = PubSub.unsubscribe(sid)
    PubSub.broadcast(sid, {:ping_after, sid})
    refute_receive {:ping_after, ^sid}, 200
  end
end
