defmodule JidoClaw.Agent.PromptSections do
  @moduledoc "Shared dynamic prompt-section renderers for the main- and sub-agent assemblers."

  alias JidoClaw.Memory.Block

  @doc """
  Render the `## Memory Blocks` section for a list of resolved Block-tier
  rows. Returns `""` for an empty list so callers can concatenate
  unconditionally.
  """
  @spec blocks_section([Block.t()]) :: String.t()
  def blocks_section([]), do: ""

  def blocks_section(blocks) do
    entries =
      Enum.map_join(blocks, "\n\n", fn block ->
        header =
          case block.description do
            nil -> "### #{block.label}"
            "" -> "### #{block.label}"
            desc -> "### #{block.label} — #{desc}"
          end

        header <> "\n" <> block.value
      end)

    """

    ## Memory Blocks (curated context)
    #{entries}
    """
  end

  @doc """
  Render the `## Project Instructions (from JIDO.md)` section. Returns `""`
  for `nil` (no JIDO.md present).
  """
  @spec jido_md_section(String.t() | nil) :: String.t()
  def jido_md_section(nil), do: ""

  def jido_md_section(content) do
    """

    ## Project Instructions (from JIDO.md)
    #{content}
    """
  end

  @doc "Read `<project_dir>/.jido/JIDO.md`, returning its content or `nil` when absent."
  @spec load_jido_md(String.t()) :: String.t() | nil
  def load_jido_md(cwd) do
    path = Path.join([cwd, ".jido", "JIDO.md"])

    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end
end
