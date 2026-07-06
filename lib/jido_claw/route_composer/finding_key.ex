defmodule JidoClaw.RouteComposer.FindingKey do
  @moduledoc """
  Cross-wave finding identity (camus C1-5): a versioned canonical term over a
  finding's normalized location FILE and normalized TITLE, hashed through
  `JidoClaw.Core.CanonicalHash.sha256_term/1` — never a rendered string
  (`Solutions.Fingerprint.signature` is the named anti-pattern).

  The term is `{:v1, normalized_file, normalized_title}`:

    * **file** (from the finding's `location`) — whitespace collapsed, a
      leading `./` stripped, a trailing `:line`/`:line:col` suffix dropped
      (line numbers move under a fix; the finding does not), and **never
      downcased** — file paths are identity on case-sensitive filesystems
      (a deliberate deviation from camus, which downcases both halves).
    * **title** — downcased, whitespace collapsed, trimmed (prose casing is
      not identity).

  A finding with a blank/missing `title` or `location` is **un-keyable**
  (`key/1` → nil) and is thereby excluded from stall detection — the
  camus-verbatim fail-safe: never guess an identity, never stall-match on a
  fabricated one. Keys tolerate atom- and string-keyed findings (the
  live-Zoi vs JSONB round-trip split, the `projection.ex:19` precedent).
  """

  alias JidoClaw.Core.CanonicalHash

  @doc """
  The finding's hex identity key, or nil when the finding is un-keyable
  (missing/blank `title` or `location`, or not a map).
  """
  @spec key(term()) :: String.t() | nil
  def key(finding) when is_map(finding) do
    title = normalized_title(field(finding, :title))
    file = normalized_file(field(finding, :location))

    if is_binary(title) and is_binary(file) do
      CanonicalHash.sha256_term({:v1, file, title})
    end
  end

  def key(_finding), do: nil

  @doc "Whether `key/1` yields an identity for this finding."
  @spec keyable?(term()) :: boolean()
  def keyable?(finding), do: is_binary(key(finding))

  # Atom key wins (live Zoi output), else the string key (JSONB round-trip).
  defp field(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  # Title half: downcase + collapse + trim; blank ⇒ un-keyable.
  defp normalized_title(title) when is_binary(title) do
    case collapse(String.downcase(title)) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_title(_title), do: nil

  # File half: collapse, strip a leading `./`, drop a trailing `:line[:col]`.
  # NO downcase — see the moduledoc deviation note. Blank ⇒ un-keyable.
  defp normalized_file(location) when is_binary(location) do
    normalized =
      location
      |> collapse()
      |> strip_dot_slash()
      |> strip_line_suffix()

    case normalized do
      "" -> nil
      file -> file
    end
  end

  defp normalized_file(_location), do: nil

  defp collapse(string) do
    string
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp strip_dot_slash("./" <> rest), do: rest
  defp strip_dot_slash(other), do: other

  defp strip_line_suffix(string), do: String.replace(string, ~r/:\d+(:\d+)?$/, "")
end
