defmodule JidoClaw.Triage.Schema do
  @moduledoc """
  The structured-output contract for AR-8 triage — the `Zoi` schema passed to
  `Jido.AI.generate_object/3`.

  Enum members use **explicit string↔atom mappings** (the `reviewer.ex:28` form),
  so the validated object is atom-safe by construction and the wire values match
  the early-signal vocabulary the catalog's `triage` stage publishes
  (`needs-tests`, `auth-surface`, …). `JidoClaw.Triage.Verdict.from_map/1`
  re-normalizes regardless, so atom/string drift from the provider can't break it.

  Only `path` is required (Zoi objects require every field by default); the
  advisory fields are `Zoi.optional/1` so a legitimate `talk` verdict that omits
  `est_size`/`intent`/`signals` still validates instead of being rejected.
  """

  @doc "The triage structured-output schema (a `Zoi` object)."
  @spec zoi() :: Zoi.schema()
  def zoi do
    Zoi.object(%{
      "path" => Zoi.enum(talk: "talk", sketch: "sketch", code: "code", system: "system"),
      "signals" =>
        Zoi.optional(
          Zoi.array(
            Zoi.enum(
              ambiguous: "ambiguous",
              bug: "bug",
              novel_domain: "novel-domain",
              multi_file: "multi-file",
              auth_surface: "auth-surface",
              secrets: "secrets",
              perms_change: "perms-change",
              destructive_op: "destructive-op",
              irreversible: "irreversible",
              needs_tests: "needs-tests",
              significant_build: "significant-build",
              scope_shift: "scope-shift",
              # AR-8b-2 F2: a `sketch` whose tracer-bullet must be *run*, not just
              # written. The front door reads `:must_execute in verdict.signals` to
              # decide whether to attempt the Docker exec launch (§2.4).
              must_execute: "must-execute"
            )
          )
        ),
      "est_size" =>
        Zoi.optional(Zoi.enum(xs: "XS", s: "S", m: "M", l: "L", xl: "XL", xxl: "XXL")),
      "intent" => Zoi.optional(Zoi.string()),
      "intent_confirmed" => Zoi.optional(Zoi.boolean()),
      # AR-9: the multi-plan arming judgment — true ONLY on a significant build
      # whose design space is wide (see the prompt section). The front door
      # enforces the conjunction with `significant-build` in code.
      "multi_plan" => Zoi.optional(Zoi.boolean()),
      "reasons" => Zoi.optional(Zoi.map(Zoi.string(), Zoi.string()))
    })
  end
end
