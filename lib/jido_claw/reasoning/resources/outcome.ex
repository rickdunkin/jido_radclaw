defmodule JidoClaw.Reasoning.Resources.Outcome do
  @moduledoc """
  Per-run record of a reasoning strategy execution.

  Written asynchronously by `JidoClaw.Reasoning.Telemetry.with_outcome/4`
  around each non-react call in `JidoClaw.Tools.Reason.run_strategy/3`.
  Aggregated by `JidoClaw.Reasoning.Statistics` to answer
  "which strategy performs best for task type X?".

  ## 0.4.1 scope

  Only `execution_kind = :strategy_run` rows are produced in 0.4.1. The
  `:certificate_verification` and `:react_stub` values are reserved so that
  the DB column + codegen snapshot land now without a runtime producer; 0.4.2
  wires `verify_certificate.ex` into the same telemetry wrap.

  ## Deferred columns (0.4.3)

  `forge_session_id :uuid` and `agent_id :string` require plumbing the IDs
  through `tool_context`; they are intentionally absent in 0.4.1 so the
  column set reflects what we can actually populate today.
  """

  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Reasoning.Domain,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  postgres do
    table("reasoning_outcomes")
    repo(JidoClaw.Repo)

    custom_indexes do
      index([:strategy, :task_type])
      index([:execution_kind, :task_type])
      index([:workspace_id, :started_at])
      index([:status, :task_type])
    end
  end

  code_interface do
    define(:record, action: :record)

    define(:list_by_task_type,
      action: :by_task_type,
      args: [:task_type, {:optional, :execution_kind}, {:optional, :since}]
    )
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      primary?(true)

      accept([
        :strategy,
        :execution_kind,
        :base_strategy,
        :pipeline_name,
        :pipeline_stage,
        :task_type,
        :complexity,
        :domain,
        :target,
        :prompt_length,
        :status,
        :duration_ms,
        :tokens_in,
        :tokens_out,
        :certificate_verdict,
        :certificate_confidence,
        :workspace_id,
        :project_dir,
        :metadata,
        :started_at,
        :completed_at
      ])
    end

    read :by_task_type do
      argument(:task_type, JidoClaw.Reasoning.TaskType, allow_nil?: false)
      argument(:since, :utc_datetime_usec)
      argument(:execution_kind, JidoClaw.Reasoning.ExecutionKind, default: :strategy_run)

      filter(expr(task_type == ^arg(:task_type)))
      filter(expr(execution_kind == ^arg(:execution_kind)))

      prepare(fn query, _context ->
        case Ash.Query.get_argument(query, :since) do
          nil -> query
          since -> Ash.Query.filter(query, expr(started_at >= ^since))
        end
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :strategy, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :execution_kind, JidoClaw.Reasoning.ExecutionKind do
      allow_nil?(false)
      public?(true)
    end

    attribute :base_strategy, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pipeline_name, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :pipeline_stage, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :task_type, JidoClaw.Reasoning.TaskType do
      allow_nil?(false)
      public?(true)
    end

    attribute :complexity, JidoClaw.Reasoning.Complexity do
      allow_nil?(false)
      public?(true)
    end

    attribute :domain, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :target, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :prompt_length, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, JidoClaw.Reasoning.OutcomeStatus do
      allow_nil?(false)
      public?(true)
    end

    attribute :duration_ms, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :tokens_in, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :tokens_out, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :certificate_verdict, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :certificate_confidence, :float do
      allow_nil?(true)
      public?(true)
    end

    attribute :workspace_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_dir, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end
  end
end
