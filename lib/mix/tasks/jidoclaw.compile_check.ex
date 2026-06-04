defmodule Mix.Tasks.Jidoclaw.CompileCheck do
  @shortdoc "Strict compile gate that tolerates an explicit allowlist of known warnings"
  @moduledoc """
  Like `mix compile --warnings-as-errors`, but tolerates an explicit, documented
  allowlist of known warnings so the `precommit` / CI gate is not permanently red
  on Elixir 1.20+ (whose set-theoretic type checker flags upstream-generated and
  intentional-scaffolding code we cannot cleanly fix).

  Force-recompiles the app's Elixir sources — `--return-errors` only surfaces
  diagnostics for files compiled *this* run, so a force is required to re-check
  unchanged files — then fails on any error, or any warning not in `@allowlist`.

  Wire it into `precommit` in place of `compile --warnings-as-errors`.

  ## Maintaining the allowlist

  Each entry is `{path_suffix, :file | message_substring}`: a diagnostic is
  tolerated when its file ends with `path_suffix` and either the entry is `:file`
  (tolerate any warning in that file — only safe for modules whose body is
  entirely macro-generated) or its message contains `message_substring`. Keep
  this list short, justify every entry, and re-check it on every dep bump /
  Elixir upgrade. See AGENTS.md "Known limitations".
  """
  use Mix.Task

  @allowlist [
    # Upstream / unfixable: the `Anubis.Server` macro (anubis_mcp 1.6.1, latest)
    # generates a `child_spec/1` whose clauses Elixir 1.20 flags. Both modules
    # are pure `use Jido.MCP.Server` declarations with no hand-written code, so a
    # file-wide tolerance cannot mask a real warning of ours. Drop when anubis
    # ships a 1.20-clean macro.
    {"lib/jido_claw/core/mcp_server.ex", :file},
    {"lib/jido_claw/memory/consolidator/mcp_server.ex", :file},
    # Intentional scaffolding: PullRequestCoordinator's stub helpers always
    # return {:ok, _}, so its retry `else` branches read as dead until those
    # helpers do real, fallible work. Matched narrowly by message so other
    # warnings in this file are still caught. See the NOTE in that module.
    {"lib/jido_claw/github/agents/pull_request_coordinator.ex", "will never match"}
  ]

  @impl true
  def run(_args) do
    # Clean the app build, then recompile its Elixir sources fresh. A clean
    # recompile (rather than `--force`) surfaces ALL warnings, not just those
    # from changed files, AND runs before protocol consolidation — so it avoids
    # the spurious "protocol already consolidated" warnings that a `--force`
    # recompile triggers in :test/:prod (where consolidation is enabled). Deps
    # are left intact (`clean` only cleans this project).
    Mix.Task.rerun("clean", [])

    {_status, diagnostics} =
      Mix.Task.rerun("compile.elixir", ["--return-errors"])

    {tolerated, blocking} = Enum.split_with(diagnostics, &allowed?/1)

    for d <- tolerated do
      Mix.shell().info("[compile_check] tolerated #{relative(d.file)}: #{first_line(d.message)}")
    end

    if blocking == [] do
      Mix.shell().info("[compile_check] OK — #{length(tolerated)} tolerated, 0 blocking")
      :ok
    else
      for d <- blocking do
        Mix.shell().error(
          "[compile_check] #{d.severity} #{relative(d.file)}:#{line(d.position)}: #{first_line(d.message)}"
        )
      end

      Mix.raise(
        "compile_check failed: #{length(blocking)} non-allowlisted diagnostic(s). " <>
          "Fix them, or — only if genuinely unavoidable — add to @allowlist in " <>
          "lib/mix/tasks/jidoclaw.compile_check.ex."
      )
    end
  end

  defp allowed?(%{severity: :warning, file: file, message: message}) when is_binary(file) do
    msg = to_string(message)

    Enum.any?(@allowlist, fn
      {suffix, :file} -> String.ends_with?(file, suffix)
      {suffix, substr} -> String.ends_with?(file, suffix) and String.contains?(msg, substr)
    end)
  end

  defp allowed?(_), do: false

  defp relative(file) when is_binary(file), do: Path.relative_to_cwd(file)
  defp relative(other), do: inspect(other)

  defp line({l, _col}), do: l
  defp line(l) when is_integer(l), do: l
  defp line(_), do: 0

  defp first_line(message), do: message |> to_string() |> String.split("\n", parts: 2) |> hd()
end
