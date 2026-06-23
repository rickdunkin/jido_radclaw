defmodule JidoClaw.Orchestration.PrototypeReferenceTest do
  @moduledoc """
  AR-8b-2 C3 reference guard: `reference_state/1` over the
  `:referencing_prototype_global` JSONB read. Pins the three states and
  self-verifies that the `config["premises"]["prototype_id"]` filter compiles to
  native JSONB extraction.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.PrototypeReference
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Repo

  setup do
    %{tenant_id: tenant_id} = seed_full(tenant_label: "proto-ref")
    {:ok, tenant_id: tenant_id, actor: actor_for(tenant_id)}
  end

  defp unique, do: System.unique_integer([:positive])

  defp create_run!(prototype_id, ctx) do
    {:ok, run} =
      WorkflowRun.create(
        %{
          name: "ref-test",
          workflow_type: "composer",
          config: %{"premises" => %{"prototype_id" => prototype_id}}
        },
        tenant: ctx.tenant_id,
        actor: ctx.actor
      )

    run
  end

  describe "reference_state/1" do
    test "a non-terminal (pending) run referencing the id is :referenced", ctx do
      id = "proto-#{unique()}"
      create_run!(id, ctx)
      assert :referenced = PrototypeReference.reference_state(id)
    end

    test "an unreferenced id is :unreferenced", _ctx do
      assert :unreferenced = PrototypeReference.reference_state("proto-none-#{unique()}")
    end

    test "a terminal run does NOT protect the prototype", ctx do
      id = "proto-#{unique()}"
      run = create_run!(id, ctx)
      # Drive the run terminal directly (status is projection-owned; raw SQL is the
      # same age-the-row escape hatch the trace sweeper test uses). The id param is
      # dumped to its 16-byte binary form for the uuid column.
      Repo.query!("UPDATE workflow_runs SET status = 'completed' WHERE id = $1", [
        Ecto.UUID.dump!(run.id)
      ])

      assert :unreferenced = PrototypeReference.reference_state(id)
    end

    test "another run's prototype_id is not matched", ctx do
      create_run!("proto-other-#{unique()}", ctx)
      assert :unreferenced = PrototypeReference.reference_state("proto-mine-#{unique()}")
    end
  end

  describe "the JSONB filter (self-verifying)" do
    test "compiles to native jsonb path extraction with LIMIT 1" do
      query = WorkflowRun.query_to_list_referencing_prototype_global("abc")
      %{query: ecto_query} = Ash.data_layer_query!(query)
      {sql, _params} = Repo.to_sql(:all, ecto_query)

      assert sql =~ "jsonb_extract_path_text" or sql =~ "#>>" or sql =~ "->>"
      assert sql =~ "LIMIT"
    end
  end
end
