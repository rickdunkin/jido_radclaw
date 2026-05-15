defmodule JidoClaw.Style.BelongsToAllowNilTest do
  @moduledoc """
  Regression: every `belongs_to` declaration under `lib/jido_claw/` must
  declare `allow_nil?` explicitly, either as a keyword-list option or as a
  child call inside a `do`-block.

  `AshCredo.Check.Readability.BelongsToMissingAllowNil` only scans modules
  that `use Ash.Resource` directly, so `use JidoClaw.Resource` wrapper
  resources are invisible to it. This test closes that scope gap.
  """

  use ExUnit.Case, async: true

  test "every belongs_to declares allow_nil? explicitly" do
    violations =
      "lib/jido_claw/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&scan_file/1)

    assert violations == [], format(violations)
  end

  defp scan_file(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)
    {_, found} = Macro.prewalk(ast, [], &collect/2)

    found
    |> Enum.reject(&has_allow_nil?/1)
    |> Enum.map(fn {name, line, _args} -> {path, line, name} end)
  end

  defp collect({:belongs_to, meta, [name | _] = args} = node, acc) when is_atom(name) do
    {node, [{name, Keyword.get(meta, :line, 0), args} | acc]}
  end

  defp collect(node, acc), do: {node, acc}

  defp has_allow_nil?({_name, _line, [_, _, opts]}) when is_list(opts) do
    case Keyword.fetch(opts, :do) do
      {:ok, body} -> body_has_allow_nil?(body)
      :error -> Keyword.has_key?(opts, :allow_nil?)
    end
  end

  defp has_allow_nil?(_), do: false

  defp body_has_allow_nil?({:__block__, _, stmts}), do: Enum.any?(stmts, &allow_nil_call?/1)
  defp body_has_allow_nil?(stmt), do: allow_nil_call?(stmt)

  defp allow_nil_call?({:allow_nil?, _, _}), do: true
  defp allow_nil_call?(_), do: false

  defp format(violations) do
    """
    Found belongs_to declarations without an explicit allow_nil?:

    #{Enum.map_join(violations, "\n", fn {path, line, name} -> "  #{path}:#{line} — :#{name}" end)}

    Add `allow_nil?: true` or `allow_nil?: false` (keyword form) or
    `allow_nil?(true)`/`allow_nil?(false)` (do-block form) to each.
    """
  end
end
