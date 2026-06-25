defmodule JidoClaw.Agent.Workers.SketchWorker do
  @moduledoc false
  # AR-8b-2 F2 (2.1): single-sources the two sketch builders, which differ by
  # EXACTLY one tool (`RunCommand`, plus its mandatory `FetchOutput` pair). A
  # near-identical second worker module would drift AND trip the ExSlop clone
  # check; the obvious dedup `tools: sketch_tools() ++ [RunCommand]` won't compile
  # — `use Jido.AI.Agent` `Enum.map`s the `tools:` AST and matches ONLY literal
  # module aliases / bare atoms (`agent.ex`), so a function-call AST raises.
  #
  # This macro builds a LITERAL list of fully-qualified tool-module atoms at
  # macro-expansion time and `unquote`s it, so each element is `is_atom/1` and
  # `Jido.AI.Agent` accepts it. The shared `output:` map (builder shape — NO
  # `signals` field, so the stage publishes nothing and converges trivially) and
  # its `retries`/`on_validation_error` (read by `Jido.AI.Output` from the output
  # attrs, so they live INSIDE the `output:` map, not as top-level opts) live once
  # here. `OutputSchema` is referenced fully-qualified — the `output:` AST is
  # eval'd in the CALLER's context, so an FQN avoids relying on an injected alias.
  #
  # `sketch_reviewer` (different tools, `reviewer_verdict/0` schema) is NOT a
  # clone of the builders and stays as-is.

  @file_tools [
    JidoClaw.Tools.ReadFile,
    JidoClaw.Tools.WriteFile,
    JidoClaw.Tools.ListDirectory,
    JidoClaw.Tools.SearchCode,
    JidoClaw.Tools.ReadRealFile,
    JidoClaw.Tools.SearchRealCode,
    JidoClaw.Tools.ListRealDirectory
  ]

  # `FetchOutput` MUST ride with `RunCommand` (Finding 5): `run_command`'s shaper
  # ref-stores oversized output and hands back a fetch ref; without `FetchOutput`
  # the exec worker is blind to large test/build output. It is read-only +
  # tenant-scoped (`tenant_id` is always-forwarded, so it survives
  # `forward_context: {:only, [:forge_session_key]}`).
  @exec_tools [JidoClaw.Tools.RunCommand, JidoClaw.Tools.FetchOutput]

  @doc """
  `use JidoClaw.Agent.Workers.SketchWorker, name:, description:, exec?:,
  tool_timeout_ms:` — emit a sketch builder. `exec?: true` adds the exec pair
  (`RunCommand` + `FetchOutput`); `exec?: false` (default) is the file-only
  builder. `tool_timeout_ms` defaults to `30_000` (the file-builder value); the
  exec worker needs a larger one (the bridge reserves a ~5.5s cushion off the
  outer deadline, so the effective in-container budget ≈ `tool_timeout_ms −
  5_500`). `sandbox`/`forward_context` are TEMPLATE properties (Part 2.3), not set
  here.
  """
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    exec? = Keyword.get(opts, :exec?, false)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)

    tool_list = if exec?, do: @file_tools ++ @exec_tools, else: @file_tools

    quote do
      use JidoClaw.Agent.Defaults,
        name: unquote(name),
        description: unquote(description),
        tools: unquote(tool_list),
        model: :fast,
        max_iterations: 15,
        streaming: false,
        tool_timeout_ms: unquote(tool_timeout_ms),
        compaction: [mode: :auto],
        output: %{
          schema:
            Zoi.object(%{
              status: Zoi.enum([:completed, :partial, :blocked]),
              summary: Zoi.string(),
              files_changed: Zoi.array(Zoi.string()),
              notes: Zoi.optional(Zoi.string()),
              # Fully-qualified on purpose: the `output:` AST is evaluated in the
              # CALLER's context, so an injected alias is fragile here.
              # credo:disable-for-next-line Credo.Check.Design.AliasUsage
              artifacts: JidoClaw.Agent.Workers.OutputSchema.artifacts()
            }),
          retries: 1,
          on_validation_error: :repair
        }
    end
  end
end
