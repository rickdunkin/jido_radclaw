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

  ## Attribution columns (0.4.3)

  `agent_id :string` carries the runtime agent identity (e.g. `"main"` or
  a session id for API-driven calls). `forge_session_key :string` carries
  the runtime forge session key — a string per `forge/persistence.ex:18`,
  not a UUID FK. A nullable UUID FK can be added later once Forge threads
  its DB UUID through `tool_context` directly.

  ## Deprecated columns (v0.6.4)

  `workspace_id :string` and `agent_id :string` are deprecated. Phase 0
  added `workspace_uuid` and `session_uuid` UUID columns; Phase 4 stops
  writing to the string siblings. The columns + indexes remain through
  v0.6 for replay/audit access; a v0.7 migration will drop them. Do not
  read from these columns going forward — they will not reflect post-v0.6.4
  writes.
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
      index([:pipeline_name, :pipeline_stage])
      index([:forge_session_key])
      index([:agent_id, :started_at])
      index([:workspace_uuid, :started_at])
      index([:session_uuid, :started_at])
    end
  end

  code_interface do
    define(:record, action: :record)
    define(:read, action: :read)
    define(:destroy, action: :destroy)

    define(:list_by_task_type,
      action: :by_task_type,
      args: [:task_type, {:optional, :execution_kind}, {:optional, :since}]
    )
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      description("Record the outcome of a reasoning strategy execution.")
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
        :workspace_uuid,
        :session_uuid,
        :project_dir,
        :forge_session_key,
        :metadata,
        :started_at,
        :completed_at
      ])
    end

    read :by_task_type do
      description("List reasoning outcomes for a task type, optionally since a cutoff.")
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

    attribute :workspace_uuid, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :session_uuid, :uuid do
      allow_nil?(true)
      public?(true)
    end

    attribute :project_dir, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :agent_id, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :forge_session_key, :string do
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

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :workspace, JidoClaw.Workspaces.Workspace do
      define_attribute?(false)
      attribute_writable?(true)
      source_attribute(:workspace_uuid)
      allow_nil?(true)
    end

    belongs_to :session, JidoClaw.Conversations.Session do
      define_attribute?(false)
      attribute_writable?(true)
      source_attribute(:session_uuid)
      allow_nil?(true)
    end
  end
end
