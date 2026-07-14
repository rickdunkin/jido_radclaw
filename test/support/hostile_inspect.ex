defmodule JidoClaw.TestSupport.HostileInspect do
  @moduledoc """
  Hostile `Inspect` fixtures for the PD1-2 totality/boundary tests.

  Compiled in `test/support` so the impls participate in protocol
  consolidation (`consolidate_protocols` is on in the test env — a
  `defimpl` inside a test file would never dispatch). Three escape kinds
  (raise / throw / exit — throw and exit escape a bare `rescue`) plus one
  impl that SUCCEEDS while returning invalid UTF-8 bytes.
  """

  defmodule Raising do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:x]
  end

  defimpl Inspect, for: Raising do
    @spec inspect(Raising.t(), Inspect.Opts.t()) :: no_return()
    def inspect(_struct, _opts), do: raise("hostile inspect raise")
  end

  defmodule Throwing do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:x]
  end

  defimpl Inspect, for: Throwing do
    @spec inspect(Throwing.t(), Inspect.Opts.t()) :: no_return()
    def inspect(_struct, _opts), do: throw(:hostile_inspect_throw)
  end

  defmodule Exiting do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:x]
  end

  defimpl Inspect, for: Exiting do
    @spec inspect(Exiting.t(), Inspect.Opts.t()) :: no_return()
    def inspect(_struct, _opts), do: exit(:hostile_inspect_exit)
  end

  defmodule InvalidBytes do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:x]
  end

  defimpl Inspect, for: InvalidBytes do
    @spec inspect(InvalidBytes.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
    def inspect(_struct, _opts), do: Inspect.Algebra.string(<<255, 254>>)
  end

  defmodule Counting do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:ref]
  end

  defimpl Inspect, for: Counting do
    # Counts dispatches via the struct's :atomics ref and returns constant
    # valid text — the boundary's single-render pin needs a COUNTER (text
    # equality alone would also pass under a second render).
    @spec inspect(Counting.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
    def inspect(%Counting{ref: ref}, _opts) do
      :atomics.add(ref, 1, 1)
      Inspect.Algebra.string("#HostileInspect.Counting<rendered>")
    end
  end
end
