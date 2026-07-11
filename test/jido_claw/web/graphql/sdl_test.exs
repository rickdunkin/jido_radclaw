defmodule JidoClaw.Web.GraphQL.SDLTest do
  @moduledoc """
  Three-layer pin of the `/gql` schema (argus P1):

    1. **Golden drift** — `SDL.render/0` byte-matches the committed
       `ui/schema.graphql`; `problems/1` red/green via tmp goldens.
    2. **Semantic contract via the compiled schema** — exact field sets,
       exact root queries + argument shapes, no Mutation/Subscription root,
       the `WorkflowRunStatus` enum — asserted through
       `Absinthe.Schema.lookup_type/2`, never SDL text-parsing.
    3. **Deny-list** — sensitive names asserted absent from the schema's
       *identifiers* (fields, input fields, arguments, enum values), not the
       raw SDL text: descriptions legitimately contain words like `result`.
       A raw-text scan is retained ONLY for the cloak/lease set, which is
       prohibited even in documentation.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.WorkflowRun.Status
  alias JidoClaw.Web.GraphQL.Schema
  alias JidoClaw.Web.GraphQL.SDL

  # ---------------------------------------------------------------------------
  # 1. Golden drift
  # ---------------------------------------------------------------------------

  describe "golden drift" do
    test "the committed golden byte-matches the compiled schema" do
      assert SDL.render() == File.read!(SDL.golden_path())
    end

    test "problems/1 is empty against a fresh golden", %{} do
      assert SDL.problems() == []
    end

    @tag :tmp_dir
    test "problems/1 red/green via tmp goldens", %{tmp_dir: tmp_dir} do
      fresh = Path.join(tmp_dir, "fresh.graphql")
      File.write!(fresh, SDL.render())
      assert SDL.problems(golden_path: fresh) == []

      mutated = Path.join(tmp_dir, "mutated.graphql")
      File.write!(mutated, SDL.render() <> "\n")
      assert [problem] = SDL.problems(golden_path: mutated)
      assert problem =~ "does not match"
      assert problem =~ "mix jidoclaw.graphql.schema"

      missing = Path.join(tmp_dir, "missing.graphql")
      assert [problem] = SDL.problems(golden_path: missing)
      assert problem =~ "cannot read"
      assert problem =~ "mix jidoclaw.graphql.schema"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Semantic contract (compiled schema, not SDL text)
  # ---------------------------------------------------------------------------

  describe "semantic contract" do
    test "Project exposes exactly the allowlisted fields" do
      assert declared_field_identifiers(:project) == [
               :default_branch,
               :github_full_name,
               :id,
               :inserted_at,
               :name,
               :updated_at
             ]
    end

    test "WorkflowRun exposes exactly the allowlisted fields" do
      assert declared_field_identifiers(:workflow_run) == [
               :completed_at,
               :disposition,
               :findings_deferred_count,
               :id,
               :inserted_at,
               :name,
               :project,
               :started_at,
               :status,
               :updated_at,
               :workflow_type
             ]
    end

    test "the Query root exposes exactly the four read queries" do
      assert declared_field_identifiers(:query) == [
               :project,
               :projects,
               :recent_workflow_runs,
               :workflow_run
             ]
    end

    test "get queries take exactly a non-null id argument" do
      query = Absinthe.Schema.lookup_type(Schema, :query)

      for get <- [:workflow_run, :project] do
        args = query.fields[get].args
        assert Map.keys(args) == [:id]
        assert %Absinthe.Type.NonNull{of_type: :id} = args[:id].type
      end
    end

    test "list queries take exactly a nullable limit argument (default is action-side)" do
      query = Absinthe.Schema.lookup_type(Schema, :query)

      for list <- [:recent_workflow_runs, :projects] do
        args = query.fields[list].args
        assert Map.keys(args) == [:limit]
        # The 50 default lives in the read action, not the schema — the SDL
        # deliberately renders a plain nullable Int with no default.
        assert args[:limit].type == :integer
        assert args[:limit].default_value == nil
      end
    end

    test "no Mutation or Subscription root exists" do
      assert Absinthe.Schema.lookup_type(Schema, :mutation) == nil
      assert Absinthe.Schema.lookup_type(Schema, :subscription) == nil
    end

    test "WorkflowRunStatus is an enum with exactly the seven lifecycle values" do
      enum = Absinthe.Schema.lookup_type(Schema, :workflow_run_status)

      assert %Absinthe.Type.Enum{} = enum

      assert Enum.sort(Map.keys(enum.values)) == [
               :abandoned,
               :awaiting_approval,
               :cancelled,
               :completed,
               :failed,
               :pending,
               :running
             ]

      # The enum is the single source: it must stay in lockstep with the
      # resource's type module.
      assert Enum.sort(Map.keys(enum.values)) == Enum.sort(Status.values())
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Deny-list (leakage defense)
  # ---------------------------------------------------------------------------

  # Snake + camel forms of every sensitive name. Iterated one by one so a
  # leak names itself in the failure output.
  @denied_identifiers [
    "resume_checkpoint",
    "resumeCheckpoint",
    "replay_inputs",
    "replayInputs",
    "claim_token",
    "claimToken",
    "claimed_by",
    "claimedBy",
    "claim_expires_at",
    "claimExpiresAt",
    "settings",
    "tenant_id",
    "tenantId",
    "user_id",
    "userId",
    "project_id",
    "projectId",
    "metadata",
    "definition_hash",
    "definitionHash",
    "retry_of_id",
    "retryOfId",
    "config",
    "result",
    "error",
    "idempotency_key",
    "idempotencyKey"
  ]

  # Names the golden must not contain even inside descriptions/documentation:
  # the AshCloak-encrypted pair (and its decrypting calculations) plus the
  # lease credentials.
  @denied_even_in_docs [
    "resume_checkpoint",
    "resumeCheckpoint",
    "replay_inputs",
    "replayInputs",
    "encrypted_resume_checkpoint",
    "encrypted_replay_inputs",
    "claim_token",
    "claimToken",
    "claimed_by",
    "claimedBy",
    "claim_expires_at",
    "claimExpiresAt"
  ]

  describe "deny-list" do
    test "no denied name appears as a schema identifier" do
      identifiers = all_schema_identifiers()

      for denied <- @denied_identifiers do
        refute denied in identifiers,
               "denied identifier #{inspect(denied)} leaked into the GraphQL schema"
      end
    end

    test "no encrypted_* identifier appears (the AshCloak column fence)" do
      for identifier <- all_schema_identifiers() do
        refute String.starts_with?(String.downcase(identifier), "encrypted"),
               "encrypted-column identifier #{inspect(identifier)} leaked into the schema"
      end
    end

    test "the cloak/lease set is absent from the golden even as documentation" do
      golden = File.read!(SDL.golden_path())

      for denied <- @denied_even_in_docs do
        refute golden =~ denied,
               "#{inspect(denied)} appears in ui/schema.graphql (prohibited even in docs)"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Declared (non-introspection) field identifiers of a type, sorted.
  defp declared_field_identifiers(type_identifier) do
    Schema
    |> Absinthe.Schema.lookup_type(type_identifier)
    |> Map.fetch!(:fields)
    |> Map.keys()
    |> Enum.reject(&introspection_identifier?/1)
    |> Enum.sort()
  end

  defp introspection_identifier?(identifier),
    do: String.starts_with?(Atom.to_string(identifier), "__")

  # Every identifier the schema exposes: object/input-object field names,
  # argument names, and enum value names — collected via introspection so
  # the sweep covers types this test file never names explicitly.
  defp all_schema_identifiers do
    {:ok, %{data: %{"__schema" => %{"types" => types}}}} =
      Absinthe.run(
        """
        {
          __schema {
            types {
              name
              fields(includeDeprecated: true) { name args { name } }
              inputFields { name }
              enumValues(includeDeprecated: true) { name }
            }
          }
        }
        """,
        Schema
      )

    types
    |> Enum.reject(&String.starts_with?(&1["name"], "__"))
    |> Enum.flat_map(fn type ->
      fields = List.wrap(type["fields"])

      Enum.map(fields, & &1["name"]) ++
        Enum.flat_map(fields, fn field -> Enum.map(List.wrap(field["args"]), & &1["name"]) end) ++
        Enum.map(List.wrap(type["inputFields"]), & &1["name"]) ++
        Enum.map(List.wrap(type["enumValues"]), & &1["name"])
    end)
    |> Enum.reject(&String.starts_with?(&1, "__"))
    |> Enum.uniq()
  end
end
