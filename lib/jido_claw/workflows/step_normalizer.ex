defmodule JidoClaw.Workflows.StepNormalizer do
  @moduledoc """
  Normalize the keys of every step map in a workflow step list to a
  canonical atom-keyed shape.

  Workflow step maps reach the runtime from two boundaries:

    * `JidoClaw.Skills.parse_skill_file/1` — YamlElixir-decoded payloads
      that arrive with string keys exclusively.
    * Tests that build `%JidoClaw.Skills{steps: [%{"name" => ...}]}`
      structs by hand and invoke a workflow driver directly.

  Both flow into `JidoClaw.Skills.Compiler.compile/1` and
  `JidoClaw.Skills.Steps.IterativeStep.extract_roles/1`. Normalizing at
  every public entry (plus the YAML loader) makes downstream readers see
  atoms exclusively.

  ## Canonical keys

  Normalization is **shallow** (top-level step keys only) and is
  driven by an in-module allowlist. The seven canonical keys are:

    * `:name`
    * `:template`
    * `:task`
    * `:role`
    * `:depends_on`
    * `:produces`
    * `:consumes`

  The literal `@canonical_keys` map in this module ensures these
  atoms are interned at compile time of `StepNormalizer` itself, so
  normalization does not depend on whether downstream workflow
  modules have been loaded yet.

  Unknown keys (atom or string) are **dropped silently** — the
  allowlist is the canonical step shape. Normalization is idempotent:
  calling twice in a row is a no-op.
  """

  @canonical_keys %{
    "name" => :name,
    "template" => :template,
    "task" => :task,
    "role" => :role,
    "depends_on" => :depends_on,
    "produces" => :produces,
    "consumes" => :consumes
  }

  @canonical_atoms Map.values(@canonical_keys)

  @doc """
  Normalize a list of step maps to the canonical atom-keyed shape.
  Returns `[]` for `nil` or non-list inputs so callers don't have to
  special-case the empty state.
  """
  @spec normalize(nil | [map] | term) :: [map]
  def normalize(nil), do: []

  def normalize(steps) when is_list(steps) do
    Enum.map(steps, &normalize_step/1)
  end

  def normalize(_), do: []

  defp normalize_step(step) when is_map(step) and not is_struct(step) do
    Enum.reduce(step, %{}, fn
      {k, v}, acc when is_atom(k) ->
        if k in @canonical_atoms, do: Map.put(acc, k, v), else: acc

      {k, v}, acc when is_binary(k) ->
        case Map.fetch(@canonical_keys, k) do
          {:ok, atom_key} -> Map.put(acc, atom_key, v)
          :error -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp normalize_step(other), do: other
end
