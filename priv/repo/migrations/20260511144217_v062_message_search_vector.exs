defmodule JidoClaw.Repo.Migrations.V062MessageSearchVector do
  @moduledoc """
  Add a `search_vector` generated column to `messages` so the
  consolidator and forward-looking conversation-search consumers have
  a real FTS surface.

  Hand-edited from the `mix ash_postgres.generate_migrations` output to
  add the `IMMUTABLE` wrapper SQL function and the `GENERATED ALWAYS AS
  (... ) STORED` clause — AshPostgres can't emit those declaratively.
  Mirrors the Solutions migration shape at
  `priv/repo/migrations/20260501113129_v061_solutions.exs:26-39, 113-116`.

  ## Online-migration caveat

  Adding a STORED GENERATED column to a populated table acquires
  `ACCESS EXCLUSIVE LOCK` for the duration of the rewrite — Postgres
  backfills the generated column for every existing row in place.
  Acceptable in local development and any environment where `messages`
  is small (≤ a few hundred thousand rows). For very large message
  tables in production, restructure into a regular nullable column +
  online backfill — out of scope for this sprint.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION messages_search_vector(p_content text)
    RETURNS tsvector LANGUAGE sql IMMUTABLE AS $$
      SELECT to_tsvector('english', coalesce(p_content, ''))
    $$;
    """)

    alter table(:messages) do
      add(:search_vector, :tsvector,
        generated: "ALWAYS AS (messages_search_vector(content)) STORED"
      )
    end

    create(index(:messages, [:search_vector], name: "messages_search_vector_idx", using: "gin"))
  end

  def down do
    drop_if_exists(index(:messages, [:search_vector], name: "messages_search_vector_idx"))

    alter table(:messages) do
      remove(:search_vector)
    end

    execute("DROP FUNCTION IF EXISTS messages_search_vector(text)")
  end
end
