defmodule JidoClaw.Tools.OutputShaper.MixCompile do
  @moduledoc """
  `mix compile` output parser for `JidoClaw.Tools.OutputShaper`.

  Inverse filter: known progress noise (`Compiling N files (.ex)`,
  per-file `Compiling lib/foo.ex` lines, `Generated app app`) collapses
  into a counts header; everything unrecognized — warnings, errors,
  and any other output — is kept **verbatim**. Returns `:nomatch` when
  the text carries no compile markers at all (not recognizably compile
  output), so the shaper falls back to generic head+tail.
  """

  alias JidoClaw.Tools.OutputShaper.Parsed

  @compiling_batch ~r/^Compiling (\d+) files? \(\.\w+\)$/
  @compiling_file ~r/^Compiling \S+\.(?:ex|exs|erl|eex|leex|heex|yrl|xrl)$/
  @generated ~r/^Generated \w+ app$/
  @warning_line ~r/^\s*warning: /
  @error_line ~r/^\s*error: |^== Compilation error/

  @spec parse(binary()) :: {:ok, Parsed.t()} | :nomatch
  def parse(text) when is_binary(text) do
    lines = String.split(text, "\n")
    {noise, kept} = Enum.split_with(lines, &noise_line?/1)

    warnings = Enum.count(lines, &Regex.match?(@warning_line, &1))
    errors = Enum.count(lines, &Regex.match?(@error_line, &1))

    if noise == [] and warnings == 0 and errors == 0 do
      :nomatch
    else
      compose(text, noise, kept, warnings, errors)
    end
  end

  defp noise_line?(line) do
    Regex.match?(@compiling_batch, line) or
      Regex.match?(@compiling_file, line) or
      Regex.match?(@generated, line)
  end

  defp compose(text, noise, kept, warnings, errors) do
    files = files_compiled(noise)

    header =
      "mix compile — #{files} files compiled, #{warnings} warnings, #{errors} errors"

    detail =
      kept
      |> collapse_blank_runs()
      |> Enum.join("\n")
      |> String.trim()

    body =
      case detail do
        "" -> header
        detail -> header <> "\n\n" <> detail
      end

    summary = %{files_compiled: files, warnings: warnings, errors: errors}

    {:ok, %Parsed{body: body, summary: summary, compressed?: byte_size(body) < byte_size(text)}}
  end

  # The batch line ("Compiling 12 files (.ex)") reports the authoritative
  # total; per-file verbose lines enumerate the same files, so take the
  # larger of the two rather than summing both.
  defp files_compiled(noise) do
    {batch_total, per_file} =
      Enum.reduce(noise, {0, 0}, fn line, {batch, files} ->
        case Regex.run(@compiling_batch, line) do
          [_, n] ->
            {batch + String.to_integer(n), files}

          _ ->
            if Regex.match?(@compiling_file, line), do: {batch, files + 1}, else: {batch, files}
        end
      end)

    max(batch_total, per_file)
  end

  # Dropping noise lines leaves blank-line gaps; collapse runs of blank
  # lines so the kept text reads cleanly.
  defp collapse_blank_runs(lines) do
    lines
    |> Enum.chunk_by(&blank?/1)
    |> Enum.flat_map(fn [first | _] = chunk ->
      if blank?(first), do: [""], else: chunk
    end)
  end

  defp blank?(line), do: String.trim(line) == ""
end
