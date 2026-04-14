defmodule JidoClaw.GitHub.IssueAnalysis do
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.GitHub,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("github_issue_analyses")
    repo(JidoClaw.Repo)
  end

  code_interface do
    define(:create)
    define(:update_status)
    define(:list_by_repo, action: :by_repo)
    define(:get_by_issue, action: :by_issue)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :issue_number,
        :repo_full_name,
        :classification,
        :confidence,
        :triage_data,
        :research_data,
        :pr_data,
        :status,
        :project_id
      ])
    end

    update :update_status do
      accept([])

      argument(:status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pending, :triaged, :researched, :pr_created, :closed]]
      )

      change(set_attribute(:status, arg(:status)))
    end

    read :by_repo do
      argument(:repo_full_name, :string, allow_nil?: false)
      filter(expr(repo_full_name == ^arg(:repo_full_name)))
    end

    read :by_issue do
      argument(:repo_full_name, :string, allow_nil?: false)
      argument(:issue_number, :integer, allow_nil?: false)

      filter(
        expr(repo_full_name == ^arg(:repo_full_name) and issue_number == ^arg(:issue_number))
      )
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :issue_number, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :repo_full_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :classification, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :confidence, :float do
      allow_nil?(true)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :triaged, :researched, :pr_created, :closed])
    end

    attribute :triage_data, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :research_data, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :pr_data, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :project_id, :uuid do
      allow_nil?(true)
      public?(true)
    end

    timestamps()
  end

  identities do
    identity(:unique_issue_per_repo, [:repo_full_name, :issue_number])
  end

  relationships do
    belongs_to(:project, JidoClaw.Projects.Project,
      define_attribute?: false,
      attribute_writable?: true
    )
  end
end
