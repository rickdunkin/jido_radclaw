defmodule JidoClaw.Conversations.MessageSearchVectorTest do
  @moduledoc """
  Phase 2 deferred feature (`phase-2-conversations.md:712-716`): the
  `Message.search_vector` generated column is populated by Postgres
  and FTS-queryable. Acts as the surface for forward-looking
  conversation-search consumers in Phase 3/4. The column is dormant
  until a consumer is added; this test pins the surface so the
  generated column + GIN index don't silently regress.
  """

  use JidoClaw.TenantCase, async: true

  alias JidoClaw.Conversations.Message
  alias JidoClaw.Repo

  test "Message.search_vector is populated by Postgres and supports FTS" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "msg-fts")
    actor = actor_for(tenant_id)

    {:ok, msg} =
      Message.append(
        %{
          session_id: session.id,
          role: :user,
          content: "deploy the postgres replica via pg_basebackup"
        },
        tenant: tenant_id,
        actor: actor
      )

    {:ok, %{rows: [[sv]]}} =
      Repo.query("SELECT search_vector::text FROM messages WHERE id = $1", [
        Ecto.UUID.dump!(msg.id)
      ])

    assert is_binary(sv)
    assert sv =~ "replica"
    assert sv =~ "deploy"

    {:ok, %{rows: [[count]]}} =
      Repo.query(
        """
        SELECT COUNT(*) FROM messages
         WHERE id = $1
           AND search_vector @@ websearch_to_tsquery('english', $2)
        """,
        [Ecto.UUID.dump!(msg.id), "postgres replica"]
      )

    assert count == 1
  end
end
