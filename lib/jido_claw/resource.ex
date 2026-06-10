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
    * write actions (`:create`, `:update`, `:destroy`) require the actor's
      tenant to match the row's tenant via
      `JidoClaw.Authorization.Checks.ActorTenantMatches`
    * read actions require `tenant_id == ^actor(:tenant_id)`

  The bypass must live inside this single `policies` block, *before* the
  regular policies: Ash's policy solver only lets a bypass skip policies
  that come after it, so a bypass declared in a second `policies` block
  (appended after these) would be ineffective.

  Resources with non-standard policy shapes
  (`global_lookup.ex`, `request_correlation.ex`, `reputation_import.ex`)
  keep their hand-written `use Ash.Resource` + `policies do` block.
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

        policy action_type([:create, :update, :destroy]) do
          authorize_if(JidoClaw.Authorization.Checks.ActorTenantMatches)
        end

        policy action_type(:read) do
          authorize_if(expr(unquote(tenant_id_field) == ^actor(:tenant_id)))
        end
      end
    end
  end
end
