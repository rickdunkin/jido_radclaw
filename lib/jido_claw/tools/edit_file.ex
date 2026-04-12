defmodule JidoClaw.Tools.EditFile do
  use Jido.Action,
    name: "edit_file",
    description:
      "Edit a file by replacing an exact string match. The old_string must be unique in the file. Read the file first to get the exact text.",
    schema: [
      path: [type: :string, required: true, doc: "File path to edit"],
      old_string: [
        type: :string,
        required: true,
        doc: "Exact text to find (must be unique in file)"
      ],
      new_string: [type: :string, required: true, doc: "Replacement text"]
    ]

  @impl true
  def run(%{path: path, old_string: old_str, new_string: new_str}, _context) do
    case File.read(path) do
      {:ok, content} ->
        occurrences = count_occurrences(content, old_str)

        cond do
          occurrences == 0 ->
            {:error,
             "old_string not found in #{path}. Read the file first to get the exact text."}

          occurrences > 1 ->
            {:error,
             "old_string found #{occurrences} times in #{path}. Provide more surrounding context to make it unique."}

          true ->
            new_content = String.replace(content, old_str, new_str, global: false)
            File.write!(path, new_content)

            diff = build_diff(old_str, new_str)
            {:ok, %{path: path, diff: diff, status: "edited"}}
        end

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp build_diff(old_str, new_str) do
    old_lines = String.split(old_str, "\n") |> Enum.map(&"- #{&1}")
    new_lines = String.split(new_str, "\n") |> Enum.map(&"+ #{&1}")
    Enum.join(old_lines ++ new_lines, "\n")
  end
end
