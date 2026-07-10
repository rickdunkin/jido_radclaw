defmodule JidoClaw.Resource do
  @moduledoc """
  Base wrapper for tenant-scoped Ash resources in JidoClaw.

  Replaces the 13-line `policies do ... end` block that every
  tenant-scoped resource was repeating verbatim with a single
  `use JidoClaw.Resource, domain: ...` invocation.

  ## Options

    * `:domain` (required) — the Ash domain module this resource belongs to.
    * `:primary_read_warning?` — passed through to `Ash.Resource`. Defaults
      to `true` to match Ash's own default.
    * `:global_actions` — extra action names (atoms) merged into the
      authorization bypass alongside `:by_id_global`. Use for deliberate
      cross-tenant actions (typically `multitenancy(:bypass)` reads used by
      system-level scanners). Defaults to `[]`.

  ## Generated policy block

  The macro emits the standard JidoClaw tenant-scoped policy:

    * `:by_id_global` (plus any `:global_actions`) bypasses authorization
      (cross-tenant lookups/scans)
    * tenant-bound system actors bypass the activity requirement, but still
      have to match the action tenant; this is the explicit lifecycle path
      used to finish already-running work while suspension tears down the
      ordinary tenant runtime
    * ordinary reads and writes require the actor's durable tenant row to be
      active
    * write actions (`:create`, `:update`, `:destroy`) also require the actor's
      tenant to match the row's tenant via
      `JidoClaw.Authorization.Checks.ActorTenantMatches`
    * read actions require `tenant_id == ^actor(:tenant_id)`

  The bypass must live inside this single `policies` block, *before* the
  regular policies: Ash's policy solver only lets a bypass skip policies
  that come after it, so a bypass declared in a second `policies` block
  (appended after these) would be ineffective.

  Note the `:by_id_global` bypass is inert on a resource that defines no
  action of that name (`bypass action(...)` simply matches nothing), so
  resources without a global read may still adopt the macro
  (`WorkflowEvent`, `WorkflowStep`, `AgentCaseEvent` do).

  Resources that genuinely can't take the macro keep a hand-written
  `use Ash.Resource`, each for a structural reason:

    * `audit/resources/event.ex` — append-only audit log: create-only policy
      surface (no update/destroy path at all).
    * `orchestration/composer_artifact.ex` — carries an extra generic
      `:action` policy the macro block doesn't emit.
    * `orchestration/workflow_run.ex` — declares the `AshCloak` extension;
      the macro doesn't forward `extensions:`.
    * `conversations/resources/request_correlation.ex` — non-standard policy
      shape (actor-less internal plumbing, explicit `authorize?: false`
      callsites).
    * `trace/resources/trace_run.ex` / `trace_event.ex` — deliberately
      `global?(true)` with nullable tenant attribution and NO policy
      authorizer; structurally outside the tenant macro.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    primary_read_warning? = Keyword.get(opts, :primary_read_warning?, true)

    global_actions =
      opts
      |> Keyword.get(:global_actions, [])
      |> List.wrap()

    unless Enum.all?(global_actions, &is_atom/1) do
      raise ArgumentError,
            ":global_actions must be a list of action-name atoms, got: " <>
              inspect(global_actions)
    end

    bypass_actions = Enum.uniq([:by_id_global | global_actions])

    tenant_id_field = Macro.var(:tenant_id, nil)
    tenant_row_id = Macro.var(:id, nil)
    tenant_status = Macro.var(:status, nil)

    quote do
      use Ash.Resource,
        otp_app: :jido_claw,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        primary_read_warning?: unquote(primary_read_warning?)

      policies do
        bypass action(unquote(Macro.escape(bypass_actions))) do
          authorize_if(always())
        end

        bypass actor_attribute_equals(:kind, :system) do
          authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
        end

        policy action_type([:create, :update, :destroy]) do
          forbid_unless(JidoClaw.Authorization.Checks.ActorTenantActive)
          authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
        end

        policy action_type(:read) do
          authorize_if(
            expr(
              unquote(tenant_id_field) == ^actor(:tenant_id) and
                exists(
                  JidoClaw.Tenants.Tenant,
                  unquote(tenant_row_id) == parent(unquote(tenant_id_field)) and
                    unquote(tenant_status) == :active
                )
            )
          )
        end
      end
    end
  end
end
