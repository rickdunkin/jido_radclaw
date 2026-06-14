defmodule JidoClaw.Core.AshErrorsTest do
  use JidoClaw.TenantCase, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Changes.Required
  alias Ash.Error.Invalid
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Core.AshErrors

  describe "unique_violation?/2 against a real Postgres unique violation" do
    test "classifies a duplicate import_hash and pins the ash_postgres error shape" do
      %{session: session, tenant_id: tenant_id} =
        seed_full(
          tenant_label: "ash-errors",
          session: [kind: :repl, external_id: "sess-#{System.unique_integer([:positive])}"]
        )

      hash = "dup-#{System.unique_integer([:positive])}"

      import_message = fn sequence, content ->
        Message.import(
          %{
            session_id: session.id,
            role: :user,
            sequence: sequence,
            content: content,
            inserted_at: DateTime.utc_now(),
            import_hash: hash
          },
          tenant: tenant_id,
          actor: actor_for(tenant_id)
        )
      end

      assert {:ok, _} = import_message.(1, "same")
      assert {:error, %Invalid{} = err} = import_message.(99, "again")

      assert AshErrors.unique_violation?(err, ["unique_import_hash"])
      refute AshErrors.unique_violation?(err, ["unique_live_tool_row"])

      # Pin the ash_postgres private_vars shape the classifier depends
      # on (data_layer.ex builds constraint:/constraint_type: from the
      # Postgres constraint error, naming the *index*). If ash_postgres
      # changes this shape, fail loudly here instead of silently
      # breaking duplicate-key classification everywhere.
      inner =
        err.errors
        |> Enum.flat_map(fn
          %Invalid{errors: nested} -> nested
          other -> [other]
        end)
        |> Enum.find(&match?(%InvalidAttribute{}, &1))

      assert %InvalidAttribute{private_vars: vars} = inner
      assert vars[:constraint_type] == :unique
      assert is_binary(vars[:constraint])
      assert vars[:constraint] =~ "unique_import_hash"
    end
  end

  describe "unique_violation?/2 on constructed errors" do
    test "matches when the index name contains a fragment" do
      err = invalid_error([unique_violation("messages_unique_import_hash_index")])

      assert AshErrors.unique_violation?(err, ["unique_import_hash"])
      assert AshErrors.unique_violation?(err, ["nope", "unique_import_hash"])
      refute AshErrors.unique_violation?(err, ["other_index"])
    end

    test "recurses into nested Ash.Error.Invalid" do
      inner = invalid_error([unique_violation("mf_promoted_user_idx")])
      outer = invalid_error([inner])

      assert AshErrors.unique_violation?(outer, ["mf_promoted_"])
      refute AshErrors.unique_violation?(outer, ["unrelated"])
    end

    test "ignores non-unique constraint violations" do
      err =
        invalid_error([
          InvalidAttribute.exception(
            field: :session_id,
            message: "does not exist",
            private_vars: [
              constraint: "messages_session_id_fkey",
              constraint_type: :foreign_key
            ]
          )
        ])

      refute AshErrors.unique_violation?(err, ["messages_session_id"])
    end

    test "ignores inner errors without private_vars or of other types" do
      err =
        invalid_error([
          InvalidAttribute.exception(field: :x, message: "bad"),
          Required.exception(field: :y, type: :attribute)
        ])

      refute AshErrors.unique_violation?(err, ["unique_import_hash"])
    end

    test "returns false for non-Invalid input" do
      refute AshErrors.unique_violation?(:some_error, ["unique_import_hash"])
      refute AshErrors.unique_violation?(%RuntimeError{message: "x"}, ["unique_import_hash"])
      refute AshErrors.unique_violation?({:error, :nope}, ["unique_import_hash"])
    end
  end

  describe "db_errors/0" do
    test "returns the exact canonical rescue list" do
      # Pins the single source of truth for `rescue _ in @db_errors` sites
      # across the app. Drift here (e.g. a module dropping Ash.Error.Forbidden)
      # is exactly what this consolidation fixed — fail loudly if it recurs.
      assert AshErrors.db_errors() == [
               Ash.Error.Invalid,
               Ash.Error.Unknown,
               Ash.Error.Forbidden,
               Ash.Error.Query.NotFound,
               DBConnection.ConnectionError,
               DBConnection.OwnershipError,
               Postgrex.Error
             ]
    end
  end

  defp invalid_error(errors), do: Invalid.exception(errors: errors)

  defp unique_violation(constraint) do
    InvalidAttribute.exception(
      field: :import_hash,
      message: "has already been taken",
      private_vars: [constraint: constraint, constraint_type: :unique, detail: nil]
    )
  end
end
