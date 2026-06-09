defmodule JidoClaw.Orchestration.GateDslTest do
  @moduledoc """
  WS6: the gate-definition Spark DSL — declared data reads back through
  `Gate.Info`, the select-options verifier rejects at compile time, the kind
  vocabulary stays in lockstep with `AgentCase.kind` — plus the WS1
  claim/fencing data-model introspection (columns + global indexes).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Gates.PlanGate
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Gate
  alias JidoClaw.Orchestration.WorkflowRun

  describe "gate DSL introspection" do
    test "the three kind modules declare their kinds" do
      assert Gate.Info.gate_kind!(JidoClaw.Gates.IrreversibleWriteGate) == :irreversible_write
      assert Gate.Info.gate_kind!(JidoClaw.Gates.ToolCallGate) == :tool_call
      assert Gate.Info.gate_kind!(JidoClaw.Gates.PlanGate) == :plan
    end

    test "title/description/fields read back as declared data" do
      assert Gate.Info.gate_title!(JidoClaw.Gates.IrreversibleWriteGate) ==
               "Approve irreversible write"

      assert {:ok, description} =
               Gate.Info.gate_description(JidoClaw.Gates.IrreversibleWriteGate)

      assert description =~ "cannot be undone"

      assert [%Gate.Field{} = field] = Gate.Info.fields(JidoClaw.Gates.IrreversibleWriteGate)
      assert field.name == :comment
      assert field.type == :textarea
      assert field.label == "Comment"
      refute field.required?
    end

    test "the migrated test gate exposes the same DSL surface + hooks" do
      assert Gate.Info.gate_kind!(JidoClaw.Gates.TestIrreversibleWrite) == :irreversible_write

      assert [%Gate.Field{name: :comment}] =
               Gate.Info.fields(JidoClaw.Gates.TestIrreversibleWrite)

      # The HumanGate base injected the Gates behaviour (hooks defined).
      assert function_exported?(JidoClaw.Gates.TestIrreversibleWrite, :after_approved, 1)
      assert function_exported?(JidoClaw.Gates.TestIrreversibleWrite, :after_rejected, 1)
    end

    test "HumanGate injects overridable no-op hooks" do
      assert PlanGate.after_approved(:ctx) == :ok
      assert PlanGate.after_rejected(:ctx) == :ok
    end
  end

  describe "compile-time validation" do
    # Verifier errors surface through Spark's @after_verify hook as
    # diagnostics, not raises — Spark.Test collects them as data.
    import Spark.Test

    test "a :select field with no options is rejected by the verifier" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BadSelectGate do
            use JidoClaw.Orchestration.HumanGate

            gate do
              kind(:plan)
              title("Bad")

              fields do
                field(:scope, type: :select)
              end
            end
          end
        end

      assert error.message =~ "select field :scope must declare non-empty options"
    end

    test "an unknown kind is rejected by the schema" do
      assert_raise Spark.Error.DslError, fn ->
        defmodule BadKindGate do
          use JidoClaw.Orchestration.HumanGate

          gate do
            kind(:nonsense)
            title("Bad")
          end
        end
      end
    end

    test "duplicate field names are rejected (entity identifier uniqueness)" do
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule DupFieldGate do
          use JidoClaw.Orchestration.HumanGate

          gate do
            kind(:plan)
            title("Bad")

            fields do
              field(:comment)
              field(:comment, type: :textarea)
            end
          end
        end
      end
    end
  end

  describe "kind vocabulary lockstep" do
    test "AgentCase.kind one_of equals Gate.Kinds.all()" do
      constraints = Ash.Resource.Info.attribute(AgentCase, :kind).constraints
      assert Enum.sort(constraints[:one_of]) == Enum.sort(Gate.Kinds.all())
    end
  end

  describe "WS1 claim/fencing data model" do
    test "the three claim columns exist (nullable, private)" do
      for name <- [:claimed_by, :claim_expires_at, :claim_token] do
        attribute = Ash.Resource.Info.attribute(WorkflowRun, name)
        assert attribute, "expected #{name} attribute"
        assert attribute.allow_nil?
        refute attribute.public?
      end
    end

    test "the claim scan indexes are global (all_tenants?), not tenant-prefixed" do
      indexes = AshPostgres.DataLayer.Info.custom_indexes(WorkflowRun)

      claim_scan = Enum.find(indexes, &(&1.fields == [:status, :claim_expires_at]))
      claimed_by = Enum.find(indexes, &(&1.fields == [:claimed_by]))

      assert claim_scan, "expected [:status, :claim_expires_at] custom index"
      assert claim_scan.all_tenants?
      assert claimed_by, "expected [:claimed_by] custom index"
      assert claimed_by.all_tenants?
    end
  end
end
