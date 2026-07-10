defmodule JidoClaw.Web.ChatControllerTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Web.ChatController

  defmodule ChatFacade do
    @moduledoc false

    @spec chat(String.t(), String.t(), String.t(), keyword()) ::
            {:ok, String.t()} | {:error, term()}
    def chat(tenant_id, session_id, prompt, opts) do
      target = Application.fetch_env!(:jido_claw, :chat_controller_test_target)
      send(target, {:chat, tenant_id, session_id, prompt, opts})
      Application.get_env(:jido_claw, :chat_controller_test_response, {:ok, "answer"})
    end
  end

  setup do
    previous_facade = Application.fetch_env(:jido_claw, :chat_facade)
    previous_target = Application.fetch_env(:jido_claw, :chat_controller_test_target)
    previous_response = Application.fetch_env(:jido_claw, :chat_controller_test_response)

    Application.put_env(:jido_claw, :chat_facade, ChatFacade)
    Application.put_env(:jido_claw, :chat_controller_test_target, self())
    Application.put_env(:jido_claw, :chat_controller_test_response, {:ok, "answer"})

    on_exit(fn ->
      restore_env(:chat_facade, previous_facade)
      restore_env(:chat_controller_test_target, previous_target)
      restore_env(:chat_controller_test_response, previous_response)
    end)

    :ok
  end

  test "passes the complete ordered transcript and uses an ephemeral UUID session" do
    user_id = Ecto.UUID.generate()

    messages = [
      %{"role" => "system", "content" => "Be concise"},
      %{"role" => "user", "content" => "First question"},
      %{"role" => "assistant", "content" => "First answer"},
      %{"role" => "user", "content" => "Follow-up"}
    ]

    conn = ChatController.create(conn(user_id), %{"model" => "default", "messages" => messages})

    assert conn.status == 200

    assert_receive {:chat, ^user_id, "api_" <> session_uuid, prompt, opts}
    assert {:ok, _} = Ecto.UUID.cast(session_uuid)
    assert prompt =~ Jason.encode!(messages)
    assert Keyword.fetch!(opts, :ephemeral_runtime)
    assert Keyword.fetch!(opts, :stateless_completion)

    assert Keyword.fetch!(opts, :stateless_completion_model) ==
             Jason.decode!(conn.resp_body)["model"]

    assert Keyword.fetch!(opts, :clarify) == :one_shot
    assert Keyword.fetch!(opts, :metadata) == %{"api_stateless" => true}

    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "chat.completion"
    assert is_binary(body["model"])
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "answer"
  end

  test "rejects malformed messages and unsupported model selection before dispatch" do
    user_id = Ecto.UUID.generate()

    malformed =
      ChatController.create(conn(user_id), %{
        "messages" => [%{"role" => "user", "content" => %{"text" => "not supported"}}]
      })

    assert malformed.status == 400
    assert Jason.decode!(malformed.resp_body)["error"]["type"] == "invalid_request_error"
    refute_received {:chat, _, _, _, _}

    unsupported =
      ChatController.create(conn(user_id), %{
        "model" => "some-other-provider:model",
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    assert unsupported.status == 400
    assert Jason.decode!(unsupported.resp_body)["error"]["message"] =~ "not configured"
    refute_received {:chat, _, _, _, _}
  end

  test "normalizes messages to role/content and caps their encoded form" do
    user_id = Ecto.UUID.generate()

    accepted =
      ChatController.create(conn(user_id), %{
        "messages" => [
          %{
            "role" => "user",
            "content" => "hello",
            "untrusted_extension" => String.duplicate("not-in-prompt", 1_000)
          }
        ]
      })

    assert accepted.status == 200
    assert_receive {:chat, ^user_id, _session, prompt, _opts}
    assert prompt =~ Jason.encode!([%{"role" => "user", "content" => "hello"}])
    refute prompt =~ "untrusted_extension"
    refute prompt =~ "not-in-prompt"

    # Raw content is below the per-message cap, but JSON escaping expands NUL
    # bytes enough to exceed the encoded transcript cap.
    rejected =
      ChatController.create(conn(user_id), %{
        "messages" => [%{"role" => "user", "content" => String.duplicate(<<0>>, 50_000)}]
      })

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["message"] =~ "encoded transcript"
    refute_received {:chat, _, _, _, _}
  end

  test "halts on an oversized transcript prefix before visiting later messages" do
    # Deliberate precedence (pinned): once the running raw-content sum crosses
    # the transcript cap, validation stops — the malformed FINAL message is
    # never visited, so the cap error wins over the malformed-message error.
    filler = String.duplicate("x", 60_000)

    # Five 60KB messages cross the 256KB cap; the sixth is malformed and
    # must never be reached.
    oversized_prefix =
      Enum.map(1..6, fn
        6 -> %{"role" => "user", "content" => 12_345}
        _under_cap -> %{"role" => "user", "content" => filler}
      end)

    rejected =
      ChatController.create(conn(Ecto.UUID.generate()), %{"messages" => oversized_prefix})

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["message"] =~ "encoded transcript"
    refute_received {:chat, _, _, _, _}
  end

  test "does not expose internal failure details" do
    Application.put_env(
      :jido_claw,
      :chat_controller_test_response,
      {:error, {:provider_error, "secret upstream body"}}
    )

    response =
      ChatController.create(conn(Ecto.UUID.generate()), %{
        "messages" => [%{"role" => "user", "content" => "hello"}]
      })

    assert response.status == 500
    body = Jason.decode!(response.resp_body)
    assert body["error"]["message"] == "The completion could not be generated"
    assert is_binary(body["error"]["request_id"])
    refute response.resp_body =~ "secret upstream body"
  end

  defp conn(user_id) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.assign(:current_user, %{id: user_id})
    |> Plug.Conn.assign(:current_actor, %{user_id: user_id, tenant_id: user_id})
  end

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
end
