defmodule Mix.Tasks.Jidoclaw.SystemPrompt.Check do
  @moduledoc """
  Checks the bundled system prompt against the registered platform truth:

  - the `.jido/system_prompt.md` copy byte-equals `priv/defaults/system_prompt.md`
    (the AGENTS.md manual-copy rule, enforced — the content checks below run once
    on the default copy and cover the `.jido` one transitively);
  - the Tool Catalog heading count and `**tool**` entries match the registered
    tool set;
  - the swarm template table and the handoff `to_template` enumeration each
    set-equal `JidoClaw.Agent.Templates.spawnable_names/0` (one check per
    enumeration surface — a shared floor check would pass with one surface stale);
  - no stale storage claims (`memory.json` — live memory is Postgres-backed).

  Every marker fails closed: an absent or unparseable marker line/section is a
  problem, never a silent pass.
  """

  use Mix.Task

  alias JidoClaw.Agent.Templates

  @shortdoc "Checks system_prompt.md drift (tools, templates, copies, storage claims)"

  @default_prompt Path.join(["priv", "defaults", "system_prompt.md"])
  @jido_prompt Path.join([".jido", "system_prompt.md"])

  @impl Mix.Task
  def run(_args) do
    tools = registered_tool_names()
    spawnable = Templates.spawnable_names()

    problems = check_sync([]) ++ check_prompt(@default_prompt, tools, spawnable)

    case problems do
      [] ->
        Mix.shell().info(
          "System prompt in sync (#{length(tools)} tools; both copies byte-identical)."
        )

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)
        Mix.raise("system prompt drift detected")
    end
  end

  defp registered_tool_names do
    JidoClaw.Agent.tool_modules()
    |> Enum.map(& &1.name())
    |> Enum.sort()
  end

  # The AGENTS.md manual-copy rule: `.jido/system_prompt.md` is created from the
  # default during setup and synced by hand afterward. Byte-equality lets the
  # content checks run once on the default while covering both files.
  defp check_sync(problems) do
    case {File.read(@default_prompt), File.read(@jido_prompt)} do
      {{:ok, same}, {:ok, same}} ->
        problems

      {{:ok, _}, {:ok, _}} ->
        [
          "#{@jido_prompt}: differs from #{@default_prompt} — copy the updated default over it (AGENTS.md manual-sync rule)"
          | problems
        ]

      {{:error, reason}, _} ->
        ["#{@default_prompt}: cannot read: #{inspect(reason)}" | problems]

      {_, {:error, reason}} ->
        ["#{@jido_prompt}: cannot read: #{inspect(reason)}" | problems]
    end
  end

  defp check_prompt(path, tools, spawnable) do
    case File.read(path) do
      {:ok, content} ->
        []
        |> check_tool_count(path, content, tools)
        |> check_tool_entries(path, content, tools)
        |> check_template_table(path, content, spawnable)
        |> check_handoff_targets(path, content, spawnable)
        |> check_no_stale_storage_claims(path, content)

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

  # Guards the swarm template table: backticked first-cell names (continuation
  # rows have no backticked first cell) must set-equal the spawnable set.
  defp check_template_table(problems, path, content, spawnable) do
    case section_after(content, "Agent templates and their exact tool access:") do
      {:ok, section} ->
        documented =
          ~r/^\| `([a-z0-9_]+)`/m
          |> Regex.scan(section, capture: :all_but_first)
          |> List.flatten()
          |> Enum.sort()

        compare_names(problems, path, "swarm template table", documented, spawnable)

      :error ->
        [
          "#{path}: missing the 'Agent templates and their exact tool access:' table section"
          | problems
        ]
    end
  end

  # Guards the handoff params line: the slash-separated names inside
  # `` `to_template` (one of …) `` must set-equal the spawnable set.
  defp check_handoff_targets(problems, path, content, spawnable) do
    case Regex.run(~r/`to_template` \(one of ([a-z0-9_\/]+)\)/, content) do
      [_match, names] ->
        documented = Enum.sort(String.split(names, "/"))
        compare_names(problems, path, "handoff to_template targets", documented, spawnable)

      nil ->
        ["#{path}: missing the handoff `to_template` (one of …) enumeration" | problems]
    end
  end

  # `memory.json` is the legacy v0.5 file — live memory is Postgres-backed
  # (`remember` → `JidoClaw.Memory.remember_from_model/2` → `Memory.Fact`).
  # Any mention in the prompt teaches the model a false storage claim.
  defp check_no_stale_storage_claims(problems, path, content) do
    if String.contains?(content, "memory.json") do
      [
        "#{path}: mentions memory.json — live memory is Postgres-backed; the legacy file is v0.5"
        | problems
      ]
    else
      problems
    end
  end

  # The lines from just after `marker` up to the next `**`/`###`-opened line —
  # the enumeration's own section, so a name elsewhere in the file can't
  # satisfy this surface's check.
  defp section_after(content, marker) do
    case String.split(content, marker, parts: 2) do
      [_before, rest] ->
        section =
          rest
          |> String.split("\n")
          |> Enum.take_while(&(not String.starts_with?(&1, ["**", "###"])))
          |> Enum.join("\n")

        {:ok, section}

      _ ->
        :error
    end
  end

  defp compare_names(problems, path, label, documented, expected) do
    missing = expected -- documented
    extra = documented -- expected

    problems
    |> maybe_report(path, "#{label} missing", missing)
    |> maybe_report(path, "#{label} lists unknown names", extra)
  end

  defp maybe_report(problems, _path, _label, []), do: problems

  defp maybe_report(problems, path, label, names) do
    ["#{path}: #{label}: #{Enum.join(names, ", ")}" | problems]
  end
end
