defmodule JidoClaw.Doctrine do
  @moduledoc """
  Central doctrine registry (AR-5): shared rules injected into spawned sub-agents'
  system prompts (spawn-agent + skill-step). Slices are authored-once priv-file text,
  gated per template by `@template_slices`. Workers cite "your DOCTRINE block" instead
  of duplicating rules.
  """

  # Priv-file-backed slices (consistent with system_prompt.md). Each carries its own
  # @external_resource so a recompile tracks edits to the .md files. The path uses
  # Path.join([__DIR__, "..", ...]) — never Path.expand (ExSlop.PathExpandPriv bans it).
  @base_priv Path.join([__DIR__, "..", "..", "priv", "defaults", "doctrine", "base.md"])
  @artifacts_priv Path.join([__DIR__, "..", "..", "priv", "defaults", "doctrine", "artifacts.md"])
  @reviewer_min_priv Path.join([
                       __DIR__,
                       "..",
                       "..",
                       "priv",
                       "defaults",
                       "doctrine",
                       "reviewer_min.md"
                     ])
  @reviewer_contract_priv Path.join([
                            __DIR__,
                            "..",
                            "..",
                            "priv",
                            "defaults",
                            "doctrine",
                            "reviewer_contract.md"
                          ])
  @system_verify_priv Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "priv",
                        "defaults",
                        "doctrine",
                        "system_verify.md"
                      ])
  @fixer_contract_priv Path.join([
                         __DIR__,
                         "..",
                         "..",
                         "priv",
                         "defaults",
                         "doctrine",
                         "fixer_contract.md"
                       ])
  @emit_signals_priv Path.join([
                       __DIR__,
                       "..",
                       "..",
                       "priv",
                       "defaults",
                       "doctrine",
                       "emit_signals.md"
                     ])
  @confidence_tagging_priv Path.join([
                             __DIR__,
                             "..",
                             "..",
                             "priv",
                             "defaults",
                             "doctrine",
                             "confidence_tagging.md"
                           ])
  @tie_break_priv Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "priv",
                    "defaults",
                    "doctrine",
                    "tie_break.md"
                  ])
  @challenger_contract_priv Path.join([
                              __DIR__,
                              "..",
                              "..",
                              "priv",
                              "defaults",
                              "doctrine",
                              "challenger_contract.md"
                            ])
  @code_doctrine_priv Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "priv",
                        "defaults",
                        "doctrine",
                        "code_doctrine.md"
                      ])

  @external_resource @base_priv
  @external_resource @artifacts_priv
  @external_resource @reviewer_min_priv
  @external_resource @reviewer_contract_priv
  @external_resource @system_verify_priv
  @external_resource @fixer_contract_priv
  @external_resource @emit_signals_priv
  @external_resource @confidence_tagging_priv
  @external_resource @tie_break_priv
  @external_resource @challenger_contract_priv
  @external_resource @code_doctrine_priv

  @slices %{
    base: String.trim(File.read!(@base_priv)),
    artifacts: String.trim(File.read!(@artifacts_priv)),
    reviewer_min: String.trim(File.read!(@reviewer_min_priv)),
    reviewer_contract: String.trim(File.read!(@reviewer_contract_priv)),
    system_verify: String.trim(File.read!(@system_verify_priv)),
    fixer_contract: String.trim(File.read!(@fixer_contract_priv)),
    emit_signals: String.trim(File.read!(@emit_signals_priv)),
    confidence_tagging: String.trim(File.read!(@confidence_tagging_priv)),
    tie_break: String.trim(File.read!(@tie_break_priv)),
    challenger_contract: String.trim(File.read!(@challenger_contract_priv)),
    code_doctrine: String.trim(File.read!(@code_doctrine_priv))
  }

  # Single-sourced in code (no config-driven slice list — a config typo can never
  # empty doctrine; mirrors ToolApproval.default_require/0). The producing workers
  # get :artifacts. The read-only judges ALL get :reviewer_min (field-agnostic
  # judging discipline — concrete-consequence bar, anti-double-flag). The three
  # that share `OutputSchema.reviewer_verdict/0` (`reviewer`, `sketch_reviewer`,
  # `system_verifier`) ALSO get :reviewer_contract (the structured-verdict shape +
  # confidence tagging). `verifier` does NOT — it judges with a different schema
  # (`pass`/`fail` + confidence + reasoning), so the field-shape contract must not
  # be injected into it.
  #
  # AR-7: the standalone :confidence_tagging slice (inline per-claim
  # `[likely]`/`[unsure]` tagging in prose + the source-URL rule) reaches the 10
  # NON-reviewer templates. The reviewer family (`reviewer`, `sketch_reviewer`,
  # `system_verifier`) is EXCLUDED — `:reviewer_contract` already carries the
  # equivalent per-finding `confidence` tag, so adding it there would duplicate the
  # contract (and trip the content-overlap smell). The tag is structurally enforced
  # only on `researcher` findings (a required Zoi enum) and the reviewer family's
  # findings (AR-3); for the other non-reviewer workers it is a prompt-enforced
  # convention on their prose output (`summary`/`notes`/`reasoning`).
  # Item 4 (AR-9 unit 2): the `:code_doctrine` slice ("Code craft" — match
  # what's there, no drive-by refactors, handle error paths, no dead weight,
  # leave it verifiable) reaches the three templates that WRITE application
  # code: `coder` (implementer + test-author both ride it), `fixer`, and
  # `refactorer`. Deliberately excluded: `sketch_build`/`sketch_build_exec`
  # (throwaway tracer-bullets — craft fights their speed purpose),
  # `system_executor` (machine/config changes, not application code), and
  # `docs_writer`/`researcher`/`plan_drafter`/`plan_challenger`/`plan_arbiter`
  # (write no code).
  @template_slices %{
    # AR-4: `coder` (backs both `implementer` + `test-author`) and `researcher`
    # (the `planner`) now self-report via a `signals` field, so they ALSO get the
    # `:emit_signals` slice — the prose half of `coder_result/0`'s / the researcher
    # schema's new `signals` list (which completion + domain signals to emit per
    # role: `code-written` / `tests-ready` for the coder, `plan-ready` for the
    # planner, `scope-shift` when scope grows). The composer loop-guarantees the
    # baseline `code-written` / `plan-ready` (`enforce_completion_signals/2`), but
    # `tests-ready` / `scope-shift` are self-reported only — so the steering matters.
    "coder" => [:base, :artifacts, :code_doctrine, :emit_signals, :confidence_tagging],
    # AR-4: the self-heal fixer is a producing worker (`:artifacts`, like `coder`)
    # PLUS the new `:fixer_contract` slice — the prose half of `fixer_result/0`:
    # resolve the open findings, then self-report the touched domains (the
    # `signals` the loop derives the re-review set from). Required by the drift
    # guard (`doctrine_test.exs`, `template_names() == Templates.names()`).
    "fixer" => [:base, :artifacts, :code_doctrine, :fixer_contract, :confidence_tagging],
    "refactorer" => [:base, :artifacts, :code_doctrine, :confidence_tagging],
    "docs_writer" => [:base, :artifacts, :confidence_tagging],
    "researcher" => [:base, :artifacts, :emit_signals, :confidence_tagging],
    "test_runner" => [:base, :artifacts, :confidence_tagging],
    "reviewer" => [:base, :reviewer_min, :reviewer_contract],
    "verifier" => [:base, :reviewer_min, :confidence_tagging],
    "sketch_build" => [:base, :artifacts, :confidence_tagging],
    "sketch_reviewer" => [:base, :reviewer_min, :reviewer_contract],
    # AR-8b-2 F2: a producing worker like `sketch_build` — reuses the existing
    # `:artifacts` slice (no new priv file). Required: the drift guard
    # (`doctrine_test.exs`, `template_names() == names()`) fails without it.
    "sketch_build_exec" => [:base, :artifacts, :confidence_tagging],
    # AR-8c: the system-path workers. The executor is a producer (`:artifacts`,
    # like `coder`); the verifier is a read-only judge (`:reviewer_min` +
    # `:reviewer_contract`, since it shares `reviewer_verdict/0`) PLUS the new
    # `:system_verify` slice that defines what "verified" means on the real
    # machine (idempotent re-check / state assertion / exit code; cite the
    # evidence). Both required by the drift guard (`template_names() == names()`).
    "system_executor" => [:base, :artifacts, :confidence_tagging],
    "system_verifier" => [:base, :reviewer_min, :reviewer_contract, :system_verify],
    # AR-9: the plan-wave workers. The drafter is a producing worker — but with
    # NO `:emit_signals` (deviation c): that slice instructs emitting
    # `plan-ready` when a plan is drafted, and a lens stage declares only
    # `scope-shift`, so under strict emit checking the stale instruction would
    # route-fail the wave. The challenger gets its critique-only contract; the
    # arbiter gets the tie-break ladder. All three required by the drift guard
    # (`template_names() == Templates.names()`).
    "plan_drafter" => [:base, :artifacts, :confidence_tagging],
    "plan_challenger" => [:base, :artifacts, :challenger_contract, :confidence_tagging],
    "plan_arbiter" => [:base, :artifacts, :tie_break, :confidence_tagging]
  }

  @doc "Return one doctrine slice's text, or `\"\"` for an unknown key."
  @spec slice(atom()) :: String.t()
  def slice(key) when is_atom(key), do: Map.get(@slices, key, "")

  @doc """
  Return the doctrine text for a template — its slices joined with a blank line,
  or `""` for an unmapped template (including `"main"`, which uses `Prompt`, so
  doctrine never double-applies).
  """
  @spec for_template(String.t()) :: String.t()
  def for_template(template_name) when is_binary(template_name) do
    @template_slices
    |> Map.get(template_name, [])
    |> Enum.map_join("\n\n", &slice/1)
  end

  @doc "List all known doctrine slice keys."
  @spec list() :: [atom()]
  def list, do: Map.keys(@slices)

  @doc "List all template names mapped to doctrine — public surface for the drift test."
  @spec template_names() :: [String.t()]
  def template_names, do: Map.keys(@template_slices)
end
