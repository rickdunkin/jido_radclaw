defmodule JidoClaw.Core.ZoiAnyJsonSchema do
  @moduledoc """
  Protocol extension (NOT a module patch — no BEAM relocation, no
  `DependencyPatches` entry): zoi 0.18.4 ships no `Zoi.JSONSchema.Encoder`
  impl for `Zoi.Types.Any`, so any schema carrying `Zoi.any()` raises when
  `ReqLLM.Schema.zoi_to_json_with_metadata/1` encodes worker output schemas
  for structured-output requests (in-process AND the vendor deposit path).

  The OB1-3 `evidence` field is deliberately `Zoi.optional(Zoi.any())` —
  schema-PERMISSIVE, so a doctrine-prompted advisory block can never
  manufacture a validation failure (`docs/exploration/ouroboros/PORT-OB1-3.md`)
  — which makes this encoder load-bearing. `%{}` is the canonical JSON-Schema
  "accept anything" (the `true` schema); prescriptive shape guidance lives in
  the doctrine slice, not here. `Zoi.json()` is NOT a substitute: its
  recursive `Zoi.lazy` self-reference makes the lazy encoder loop forever.

  Remove when zoi ships its own `Zoi.Types.Any` encoder impl — the duplicate
  defimpl will surface as a compile warning at the dep bump.
  """
end

defimpl Zoi.JSONSchema.Encoder, for: Zoi.Types.Any do
  # The protocol's own spec shape (`Zoi.Types.Any` defines no `t/0`).
  @spec encode(Zoi.Type.t()) :: map()
  def encode(_schema), do: %{}
end
