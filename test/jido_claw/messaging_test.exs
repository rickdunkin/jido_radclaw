defmodule JidoClaw.MessagingTest do
  use ExUnit.Case, async: true

  # JidoClaw.Messaging is started by the Application supervision tree with
  # Jido.Messaging.Persistence.ETS. Canary test exercises the generated API
  # end-to-end so that a subtle drift in Jido.Messaging.__using__/1 or in
  # Runtime/Persistence wiring is caught at `mix test` instead of at runtime.

  test "create_room/1 returns a room struct with an id" do
    {:ok, room} = JidoClaw.Messaging.create_room(%{type: :direct, name: "canary-room"})

    assert is_binary(room.id)
    assert room.type == :direct
    assert room.name == "canary-room"
  end

  test "save_message/1 + get_message/1 round-trip a message" do
    {:ok, room} = JidoClaw.Messaging.create_room(%{type: :direct, name: "canary-save"})

    {:ok, saved} =
      JidoClaw.Messaging.save_message(%{
        room_id: room.id,
        sender_id: "canary-user",
        role: :user,
        content: [%{type: :text, text: "ping"}]
      })

    assert is_binary(saved.id)
    assert saved.room_id == room.id
    assert saved.role == :user
    assert saved.content == [%{type: :text, text: "ping"}]

    {:ok, fetched} = JidoClaw.Messaging.get_message(saved.id)
    assert fetched.id == saved.id
    assert fetched.content == saved.content
  end
end
