defmodule JidoClaw.Orchestration.Gate.Dsl do
  @moduledoc """
  The gate-definition Spark DSL — the first Spark DSL defined in this repo.

  A gate module (`use JidoClaw.Orchestration.HumanGate`) declares its kind,
  operator-facing presentation, and typed input fields as **data**:

      gate do
        kind(:irreversible_write)
        title("Approve workspace write")
        description("The agent wants to create a workspace on disk.")

        fields do
          field(:reason, type: :textarea, label: "Why?", required?: true)
          field(:scope, type: :select, options: ["repo", "global"])
        end
      end

  `JidoClaw.Orchestration.Gate.Info` reads it back (`gate_kind!/1`,
  `gate_title!/1`, `fields/1`); `GateStep` derives the `AgentCase.kind` and
  seeds the operator-visible `details` from it. The `kind` enum is sourced
  from `JidoClaw.Orchestration.Gate.Kinds` (the same list constraining
  `AgentCase.kind`), so the DSL and the column can never drift. The
  notification hooks stay plain behaviour callbacks on
  `JidoClaw.Orchestration.Gates` — they are code, not declarative data.

  No transformer: kinds are read on demand, not registered.
  """

  @field %Spark.Dsl.Entity{
    name: :field,
    describe: "An operator-facing input field rendered on the approval surfaces.",
    target: JidoClaw.Orchestration.Gate.Field,
    args: [:name],
    identifier: :name,
    examples: [
      ~S|field(:reason, type: :textarea, label: "Why?", required?: true)|,
      ~S|field(:scope, type: :select, options: ["repo", "global"])|
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The field key (unique per gate)."
      ],
      type: [
        type: {:one_of, [:text, :select, :textarea, :number, :boolean]},
        default: :text,
        doc: "The input widget type."
      ],
      label: [
        type: :string,
        doc: "Operator-facing label; defaults to the humanized name."
      ],
      options: [
        type: {:list, :string},
        default: [],
        doc: "The choices for a `:select` field (required there, verifier-enforced)."
      ],
      required?: [
        type: :boolean,
        default: false,
        doc: "Whether the operator must fill this field to decide."
      ]
    ]
  }

  @fields %Spark.Dsl.Section{
    name: :fields,
    describe: "The typed operator-facing input fields for this gate.",
    entities: [@field]
  }

  @gate %Spark.Dsl.Section{
    name: :gate,
    describe: "Declares the gate's kind, presentation, and operator input fields.",
    sections: [@fields],
    schema: [
      kind: [
        type: {:one_of, JidoClaw.Orchestration.Gate.Kinds.all()},
        required: true,
        doc: "The gate kind, mirrored onto the `AgentCase.kind` column."
      ],
      title: [
        type: :string,
        required: true,
        doc: "Operator-facing headline shown in the approval inbox."
      ],
      description: [
        type: :string,
        doc: "Longer operator-facing context for the decision."
      ],
      workflow: [
        type: :string,
        doc: "Optional workflow identifier this gate is associated with."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@gate],
    verifiers: [JidoClaw.Orchestration.Gate.Verifiers.ValidateSelectOptions]
end
