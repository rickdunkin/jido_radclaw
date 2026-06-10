defmodule JidoClaw.Messaging do
  @moduledoc """
  Messaging runtime powered by jido_messaging.

  Provides room-based messaging with agent registration, thread management,
  and bridge support for external platforms (Discord). A single instance is
  started in the application supervision tree.

  ## Usage

      # Create a room for a session
      {:ok, room} = JidoClaw.Messaging.create_room(%{type: :direct, name: "cli-session"})

      # Register an agent in the room
      {:ok, _} = JidoClaw.Messaging.register_agent(room.id, %{
        agent_id: "main",
        name: "JidoClaw",
        handler: &JidoClaw.Messaging.handle_message/2
      })

      # Save a message (triggers agent handler via Signal Bus)
      {:ok, msg} = JidoClaw.Messaging.save_message(%{
        room_id: room.id,
        sender_id: "user",
        role: :user,
        content: [%{type: :text, text: "Hello"}]
      })
  """

  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.ETS
end
