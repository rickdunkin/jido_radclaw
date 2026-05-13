defmodule JidoClaw.NoClone do
  @moduledoc """
  Mixin that suppresses the "@no_clone was set but never used" warning for
  modules that use the ExDNA `@no_clone true` annotation to opt out of
  duplicate detection. Place `use JidoClaw.NoClone` inside the module
  that owns the annotated function, then write the annotations as:

      @impl true
      @no_clone true
      def change(...)

  Order matters: `@no_clone true` must be the LAST attribute before the
  `def`/`defp` so ExDNA's annotator pattern-matches the immediately-next
  node. `@impl true` (if present) goes above it.

  Scope: `use JidoClaw.NoClone` only registers the attribute in the
  module it's invoked in — NOT in nested defmodules. For Ash change
  modules nested inside a resource (e.g. `Fact.Changes.ValidateCrossTenant`),
  add `use JidoClaw.NoClone` inside the nested defmodule, not the parent.

  ExDNA's annotator (deps/ex_dna/lib/ex_dna/ast/annotator.ex) strips both
  the attribute and the following def/defp from the AST before hashing.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :no_clone, accumulate: true, persist: false)
    end
  end
end
