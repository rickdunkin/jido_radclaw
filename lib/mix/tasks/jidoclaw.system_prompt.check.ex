defmodule Mix.Tasks.Jidoclaw.SystemPrompt.Check do
  @moduledoc """
  Checks that the bundled system prompt documents the registered agent tools.
  """

  use Mix.Task

  @shortdoc "Checks system_prompt.md tool catalog drift"

  @default_prompt Path.join(["priv", "defaults", "system_prompt.md"])

  @impl Mix.Task
  def run(_args) do
    tools = registered_tool_names()

    case check_prompt(@default_prompt, tools) do
      [] ->
        Mix.shell().info("System prompt tool catalog is in sync (#{length(tools)} tools).")

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)
        Mix.raise("system prompt tool catalog drift detected")
    end
  end

  defp registered_tool_names do
    JidoClaw.Agent.tool_modules()
    |> Enum.map(& &1.name())
    |> Enum.sort()
  end

  defp check_prompt(path, tools) do
    case File.read(path) do
      {:ok, content} ->
        []
        |> check_tool_count(path, content, tools)
        |> check_tool_entries(path, content, tools)

      {:error, reason} ->
        ["#{path}: cannot read system prompt: #{inspect(reason)}"]
    end
  end

  defp check_tool_count(problems, path, content, tools) do
    case Regex.run(~r/^## Tool Catalog \((\d+) tools\)$/m, content) do
      [_match, count] ->
        expected = length(tools)
        actual = String.to_integer(count)

        if actual == expected do
          problems
        else
          ["#{path}: tool catalog count is #{actual}, expected #{expected}" | problems]
        end

      nil ->
        ["#{path}: missing Tool Catalog count heading" | problems]
    end
  end

  defp check_tool_entries(problems, path, content, tools) do
    documented =
      ~r/^\*\*([a-z0-9_]+)\*\*/m
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    missing = tools -- documented
    extra = documented -- tools

    problems
    |> maybe_report(path, "missing registered tools", missing)
    |> maybe_report(path, "documents unregistered tools", extra)
  end

  defp maybe_report(problems, _path, _label, []), do: problems

  defp maybe_report(problems, path, label, names) do
    ["#{path}: #{label}: #{Enum.join(names, ", ")}" | problems]
  end
end
