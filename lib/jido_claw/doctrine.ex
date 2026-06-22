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

  @external_resource @base_priv
  @external_resource @artifacts_priv
  @external_resource @reviewer_min_priv

  @slices %{
    base: String.trim(File.read!(@base_priv)),
    artifacts: String.trim(File.read!(@artifacts_priv)),
    reviewer_min: String.trim(File.read!(@reviewer_min_priv))
  }

  # Single-sourced in code (no config-driven slice list — a config typo can never
  # empty doctrine; mirrors ToolApproval.default_require/0). The 5 producing workers
  # get :artifacts; the two read-only judges get the :reviewer_min placeholder.
  @template_slices %{
    "coder" => [:base, :artifacts],
    "refactorer" => [:base, :artifacts],
    "docs_writer" => [:base, :artifacts],
    "researcher" => [:base, :artifacts],
    "test_runner" => [:base, :artifacts],
    "reviewer" => [:base, :reviewer_min],
    "verifier" => [:base, :reviewer_min]
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
