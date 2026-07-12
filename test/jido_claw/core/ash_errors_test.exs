defmodule JidoClaw.Core.AshErrorsTest do
  use JidoClaw.TenantCase, async: true

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Changes.Required
  alias Ash.Error.Invalid
  alias JidoClaw.Conversations.Message
  alias JidoClaw.Conversations.Session
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

  describe "connection_error?/1" do
    test "recognizes the raw exception structs" do
      assert AshErrors.connection_error?(%DBConnection.ConnectionError{message: "tcp closed"})
      assert AshErrors.connection_error?(%Postgrex.Error{postgres: nil, message: "ssl down"})
    end

    test "a Postgrex error carrying a postgres map is a schema/programming error" do
      refute AshErrors.connection_error?(%Postgrex.Error{
               postgres: %{code: :undefined_column, message: ~s(column "nope" does not exist)}
             })
    end

    test "recognizes the Ash-wrapped string leaf on the exact exception banner" do
      # Splode's `Exception.format/2` path: the leaf's `.error` is a FORMATTED
      # STRING, not the exception struct — the production boot-scan shape.
      wrapped = %Ash.Error.Unknown{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error: "** (DBConnection.ConnectionError) tcp recv (idle): closed"
          }
        ]
      }

      assert AshErrors.connection_error?(wrapped)
    end

    test "a formatted Postgrex banner string is NOT retryable" do
      # A schema/programming Postgrex.Error stringifies through the same
      # splode path; a bare marker match would misread it as transient.
      wrapped = %Ash.Error.Unknown{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error:
              ~s{** (Postgrex.Error) ERROR 42703 (undefined_column) column "nope" does not exist}
          }
        ]
      }

      refute AshErrors.connection_error?(wrapped)
    end

    test "a loose mid-string mention away from the banner prefix is NOT recognized" do
      wrapped = %Ash.Error.Unknown{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error: "scan aborted; see DBConnection.ConnectionError in the logs"
          }
        ]
      }

      refute AshErrors.connection_error?(wrapped)
    end

    test "recognizes the struct-preserving splode leaf" do
      wrapped = %Ash.Error.Unknown{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error: %DBConnection.ConnectionError{message: "tcp recv: closed"}
          }
        ]
      }

      assert AshErrors.connection_error?(wrapped)
    end

    test "a non-connection exception in the leaf is NOT recognized" do
      wrapped = %Ash.Error.Unknown{
        errors: [%Ash.Error.Unknown.UnknownError{error: %ArgumentError{message: "defect"}}]
      }

      refute AshErrors.connection_error?(wrapped)
    end

    test "recurses through nested error classes" do
      inner = %Ash.Error.Invalid{
        errors: [
          %Ash.Error.Unknown.UnknownError{
            error: "** (DBConnection.ConnectionError) connection refused"
          }
        ]
      }

      assert AshErrors.connection_error?(%Ash.Error.Unknown{errors: [inner]})
    end

    test "returns false for arbitrary non-error input" do
      refute AshErrors.connection_error?(:timeout)
      refute AshErrors.connection_error?("DBConnection.ConnectionError")
      refute AshErrors.connection_error?({:error, %DBConnection.ConnectionError{message: "x"}})
      refute AshErrors.connection_error?(%{errors: :not_a_list})
    end
  end

  describe "not_found?/1" do
    test "classifies a REAL get?-miss from Session.by_id (the CLI exit-4 seam)" do
      %{tenant_id: tenant_id} = seed_full(tenant_label: "not-found")

      assert {:error, error} =
               Session.by_id(Ecto.UUID.generate(),
                 tenant: tenant_id,
                 actor: actor_for(tenant_id)
               )

      assert AshErrors.not_found?(error)
    end

    test "recognizes the bare leaf and the pure wrapped shape" do
      assert AshErrors.not_found?(%Ash.Error.Query.NotFound{})

      assert AshErrors.not_found?(%Ash.Error.Invalid{
               errors: [%Ash.Error.Query.NotFound{}]
             })
    end

    test "an infrastructure failure is NEVER a not-found (the exit-1 lane)" do
      # The `mix jidoclaw run` resolver branches 4-vs-1 on exactly this
      # predicate: a flaky DB read must keep the generic error lane, never
      # report a clean miss.
      refute AshErrors.not_found?(%Ash.Error.Unknown{
               errors: [
                 %Ash.Error.Unknown.UnknownError{
                   error: %DBConnection.ConnectionError{message: "tcp recv: closed"}
                 }
               ]
             })

      refute AshErrors.not_found?(%DBConnection.ConnectionError{message: "down"})
      refute AshErrors.not_found?(%Postgrex.Error{postgres: nil, message: "ssl down"})
    end

    test "a container MIXING not-found with any other leaf stays false" do
      refute AshErrors.not_found?(%Ash.Error.Invalid{
               errors: [
                 %Ash.Error.Query.NotFound{},
                 %Ash.Error.Unknown.UnknownError{error: %ArgumentError{message: "defect"}}
               ]
             })
    end

    test "empty containers and arbitrary input are false" do
      refute AshErrors.not_found?(%Ash.Error.Invalid{errors: []})
      refute AshErrors.not_found?(:not_found)
      refute AshErrors.not_found?("not found")
      refute AshErrors.not_found?(nil)
    end
  end

  describe "not_found_error?/1" do
    test "is a compatibility alias for the strict not-found classifier" do
      bare = %Ash.Error.Query.NotFound{resource: Message}

      assert AshErrors.not_found_error?(bare)
      assert AshErrors.not_found_error?(invalid_error([bare]))

      refute AshErrors.not_found_error?(invalid_error([bare, Required.exception(field: :name)]))

      refute AshErrors.not_found_error?(%DBConnection.ConnectionError{})
      refute AshErrors.not_found_error?(:timeout)
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
