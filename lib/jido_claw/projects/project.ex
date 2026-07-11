defmodule JidoClaw.Projects.Project do
  @moduledoc false
  use Ash.Resource,
    otp_app: :jido_claw,
    domain: JidoClaw.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGraphql.Resource]

  postgres do
    table("projects")
    repo(JidoClaw.Repo)
  end

  # Read-only GraphQL exposure (argus P1). Field exposure is a positive
  # allowlist (`show_fields`) — a new attribute stays off the API until
  # deliberately listed here. Derived filter/sort inputs are disabled so the
  # surface stays fixed-shape (the `:alphabetical` action owns ordering).
  graphql do
    type(:project)
    derive_filter?(false)
    derive_sort?(false)
    show_fields([:id, :name, :github_full_name, :default_branch, :inserted_at, :updated_at])
  end

  code_interface do
    define(:create, action: :create)
    define(:read, action: :read)
    define(:destroy, action: :destroy)
    define(:get_by_github_full_name, action: :read, get_by: [:github_full_name])
    define(:update, action: :update)
    define(:list_alphabetical, action: :alphabetical)
  end

  actions do
    create :create do
      description("Register a project linked to a GitHub repository.")
      accept([:name, :github_full_name, :default_branch, :settings])
    end

    read :read do
      description("Read projects, optionally fetching by GitHub full name.")
      primary?(true)
    end

    # GraphQL `projects` list action: stable alphabetical order with an id
    # tie-break, bounded by a validated `limit` (over-cap is an honest
    # validation error, never a silent clamp). Primary `:read` stays untouched
    # for every existing caller.
    read :alphabetical do
      description("List projects alphabetically for the GraphQL surface.")

      argument :limit, :integer do
        allow_nil?(false)
        default(50)
        constraints(min: 1, max: 200)
      end

      prepare(build(limit: arg(:limit), sort: [name: :asc, id: :asc]))
    end

    update :update do
      description("Update a project's name, default branch, or settings.")
      accept([:name, :default_branch, :settings])
    end

    destroy :destroy do
      description("Delete a project.")
      primary?(true)
    end

    # Additive undo seam for `Ash.Reactor` create-step rollback. The Reactor
    # undo path calls `Changeset.for_destroy(:reactor_undo, %{changeset: stored})`,
    # and the create-step builder verifier requires the undo action to take
    # exactly one `:changeset` argument — the default `:destroy` does not, so a
    # dedicated action is required. `public?(false)` keeps it off
    # code-interface / AshAdmin surfaces without affecting the internal undo
    # path (which authorizes as the saga's actor — `ReactorRunner` requires
    # and seeds one — under the `actor_present()` policy).
    destroy :reactor_undo do
      description("Undo action for Ash.Reactor create-step rollback.")
      public?(false)
      argument(:changeset, :term)
    end
  end

  # Project is deliberately global (no tenant attribute) — every project is
  # visible to every authenticated surface. The actor requirement is the
  # entire policy. Actor-less *writes* are hard-denied with
  # `Ash.Error.Forbidden`; actor-less *reads* run under the default
  # `access_type :filter` and so return `{:ok, []}` / `NotFound` instead
  # (pinned in `ProjectPolicyTest`). Production callers always have an
  # actor: the `:require_auth` LiveViews pass `current_actor`, and
  # `ReactorRunner` requires/seeds `:actor` for sagas.
  policies do
    policy always() do
      authorize_if(actor_present())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 255, trim?: true)
    end

    attribute :github_full_name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 3, max_length: 255, trim?: true)
    end

    attribute :default_branch, :string do
      allow_nil?(false)
      public?(true)
      default("main")
      constraints(min_length: 1, max_length: 255, trim?: true)
    end

    attribute :settings, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    # Explicitly public: timestamps default `public?: false`, and the GraphQL
    # `show_fields` allowlist can only expose fields that are public — a
    # deliberate shared Ash public-interface change (argus P1).
    create_timestamp(:inserted_at, public?: true)
    update_timestamp(:updated_at, public?: true)
  end

  identities do
    identity(:unique_github_full_name, [:github_full_name])
  end
end
