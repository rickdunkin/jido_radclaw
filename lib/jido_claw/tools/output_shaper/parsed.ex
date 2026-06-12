defmodule JidoClaw.Tools.OutputShaper.Parsed do
  @moduledoc """
  Shared result contract for the OutputShaper format parsers
  (`MixTest`, `MixCompile`, `GitDiff`).

  * `body` — the compact, ref-free shaped text (the shaper appends the
    `fetch_output` footer after storage resolves).
  * `summary` — lean parsed structure stored alongside the full output
    (drives the previous-run delta); `nil` when the format has none.
  * `compressed?` — whether `body` is actually smaller than the input.
    `false` tells the shaper the output is all-signal: the original
    passes through when it fits the inline cap (`OutputLimit`), but
    above it the shaper stores a ref and bounds the body anyway —
    ref-less backstop truncation would be the worse cut.
  """

  @enforce_keys [:body, :compressed?]
  defstruct [:body, :summary, :compressed?]

  @type t :: %__MODULE__{
          body: String.t(),
          summary: map() | nil,
          compressed?: boolean()
        }
end
