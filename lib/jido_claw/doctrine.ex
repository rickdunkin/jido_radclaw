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

  @external_resource @base_priv
  @external_resource @artifacts_priv
  @external_resource @reviewer_min_priv
  @external_resource @reviewer_contract_priv
  @external_resource @system_verify_priv
  @external_resource @fixer_contract_priv
  @external_resource @emit_signals_priv

  @slices %{
    base: String.trim(File.read!(@base_priv)),
    artifacts: String.trim(File.read!(@artifacts_priv)),
    reviewer_min: String.trim(File.read!(@reviewer_min_priv)),
    reviewer_contract: String.trim(File.read!(@reviewer_contract_priv)),
    system_verify: String.trim(File.read!(@system_verify_priv)),
    fixer_contract: String.trim(File.read!(@fixer_contract_priv)),
    emit_signals: String.trim(File.read!(@emit_signals_priv))
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
  @template_slices %{
    # AR-4: `coder` (backs both `implementer` + `test-author`) and `researcher`
    # (the `planner`) now self-report via a `signals` field, so they ALSO get the
    # `:emit_signals` slice — the prose half of `coder_result/0`'s / the researcher
    # schema's new `signals` list (which completion + domain signals to emit per
    # role: `code-written` / `tests-ready` for the coder, `plan-ready` for the
    # planner, `scope-shift` when scope grows). The composer loop-guarantees the
    # baseline `code-written` / `plan-ready` (`enforce_completion_signals/2`), but
    # `tests-ready` / `scope-shift` are self-reported only — so the steering matters.
    "coder" => [:base, :artifacts, :emit_signals],
    # AR-4: the self-heal fixer is a producing worker (`:artifacts`, like `coder`)
    # PLUS the new `:fixer_contract` slice — the prose half of `fixer_result/0`:
    # resolve the open findings, then self-report the touched domains (the
    # `signals` the loop derives the re-review set from). Required by the drift
    # guard (`doctrine_test.exs`, `template_names() == Templates.names()`).
    "fixer" => [:base, :artifacts, :fixer_contract],
    "refactorer" => [:base, :artifacts],
    "docs_writer" => [:base, :artifacts],
    "researcher" => [:base, :artifacts, :emit_signals],
    "test_runner" => [:base, :artifacts],
    "reviewer" => [:base, :reviewer_min, :reviewer_contract],
    "verifier" => [:base, :reviewer_min],
    "sketch_build" => [:base, :artifacts],
    "sketch_reviewer" => [:base, :reviewer_min, :reviewer_contract],
    # AR-8b-2 F2: a producing worker like `sketch_build` — reuses the existing
    # `:artifacts` slice (no new priv file). Required: the drift guard
    # (`doctrine_test.exs`, `template_names() == names()`) fails without it.
    "sketch_build_exec" => [:base, :artifacts],
    # AR-8c: the system-path workers. The executor is a producer (`:artifacts`,
    # like `coder`); the verifier is a read-only judge (`:reviewer_min` +
    # `:reviewer_contract`, since it shares `reviewer_verdict/0`) PLUS the new
    # `:system_verify` slice that defines what "verified" means on the real
    # machine (idempotent re-check / state assertion / exit code; cite the
    # evidence). Both required by the drift guard (`template_names() == names()`).
    "system_executor" => [:base, :artifacts],
    "system_verifier" => [:base, :reviewer_min, :reviewer_contract, :system_verify]
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
