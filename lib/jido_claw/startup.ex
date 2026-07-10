defmodule JidoClaw.Startup do
  @moduledoc """
  Project-local state + agent bootstrapping.

  Called from interactive/durable entry points (REPL, `JidoClaw.chat/3`,
  escript, mix task) so they converge on the same `.jido/` bootstrap and
  system-prompt injection path. The zero-tool stateless completion path skips
  the write-capable bootstrap and uses the read-only prompt fallback below.
  """

  alias JidoClaw.Agent.Prompt
  alias JidoClaw.Agent.SubagentPrompt
  alias JidoClaw.Reasoning.PipelineStore
  alias JidoClaw.Reasoning.StrategyStore

  require Logger

  # AR-5 doctrine injection kill switch. `enabled?: true` ships doctrine to every
  # spawn/skill sub-agent; `false` restores legacy no-doctrine worker behavior.
  @doctrine_defaults [enabled?: true]

  @doc """
  Ensure project-level `.jido/` files exist and reconcile the system prompt
  with the bundled default.

  Returns `{:ok, prompt_sync: result}` so callers (e.g., the CLI REPL) can
  print a one-line notice when the `.default` sidecar was just written.
  """
  @spec ensure_project_state(String.t()) ::
          {:ok, [prompt_sync: Prompt.sync_result()]}
          | {:error, term()}
  def ensure_project_state(project_dir) when is_binary(project_dir) do
    with :ok <- safe_bootstrap(:jido_md, fn -> JidoClaw.JidoMd.ensure(project_dir) end),
         :ok <- safe_bootstrap(:prompt_ensure, fn -> Prompt.ensure(project_dir) end),
         :ok <- safe_bootstrap(:skills, fn -> JidoClaw.Skills.ensure_defaults(project_dir) end),
         :ok <- safe_bootstrap(:strategies, fn -> ensure_strategies_dir(project_dir) end),
         :ok <- safe_bootstrap(:pipelines, fn -> ensure_pipelines_dir(project_dir) end),
         {:ok, result} <- Prompt.sync(project_dir) do
      {:ok, prompt_sync: result}
    end
  end

  # Application.start fires before ensure_project_state/1, so StrategyStore's
  # initial load may see an empty or nonexistent `.jido/strategies/` dir. After
  # ensuring the directory exists, reload if the store is already supervised.
  # The whereis guard keeps bare callers (e.g. tests calling ensure_project_state/1
  # without starting the app) from crashing.
  defp ensure_strategies_dir(project_dir) do
    File.mkdir_p!(Path.join([project_dir, ".jido", "strategies"]))

    case Process.whereis(StrategyStore) do
      nil -> :ok
      _pid -> StrategyStore.reload()
    end
  end

  defp ensure_pipelines_dir(project_dir) do
    File.mkdir_p!(Path.join([project_dir, ".jido", "pipelines"]))

    case Process.whereis(PipelineStore) do
      nil -> :ok
      _pid -> PipelineStore.reload()
    end
  end

  # Bang-op bootstrap steps (JidoMd, Prompt.ensure, Skills) raise File.Error on
  # IO failure. Convert raises to {:error, {step, reason}} so `ensure_project_state/1`
  # callers (REPL warn path, `chat/3` error-return path) see a uniform contract.
  defp safe_bootstrap(step, fun) do
    fun.()
    :ok
  rescue
    e in File.Error ->
      {:error, {step, %{reason: e.reason, path: e.path, action: e.action}}}

    # Boot-path catch-all: a bang-op bootstrap step (JidoMd/Prompt/Skills)
    # raising anything other than File.Error must still surface as a
    # uniform `{:error, {step, reason}}` to every entry point.
    # reach:disable-next-line bare_rescue
    e ->
      {:error, {step, Exception.message(e)}}
  end

  @doc """
  Inject the dynamic system prompt onto an agent pid.

  When a Session row is supplied and carries a persisted
  `metadata["prompt_snapshot"]`, that frozen string is injected
  verbatim — the prompt cache stays warm because the bytes are
  byte-stable across turns. Otherwise (and for legacy 2-arity
  callers) the prompt is rebuilt from disk via `Prompt.build/1`.

  Emits a `[:jido_claw, :agent, :prompt_injected]` telemetry event
  on success so tests and observers can assert injection happened
  without depending on an agent-side get-prompt API.
  """
  @spec inject_system_prompt(pid(), String.t()) :: :ok | {:error, term()}
  def inject_system_prompt(pid, project_dir), do: inject_system_prompt(pid, project_dir, nil)

  @spec inject_system_prompt(pid(), String.t(), JidoClaw.Conversations.Session.t() | nil) ::
          :ok | {:error, term()}
  def inject_system_prompt(pid, project_dir, session)
      when is_pid(pid) and is_binary(project_dir) do
    system_prompt = resolve_prompt(session, project_dir)
    do_inject(pid, system_prompt, project_dir, source_of(session), %{})
  end

  @doc """
  Inject the project prompt plus the capability contract for a stateless
  OpenAI-compatible completion.

  The agent module has no tools, and this retained system block keeps its prose
  honest about that structural boundary even when the project prompt describes
  the full interactive coding agent.
  """
  @spec inject_stateless_completion_prompt(
          pid(),
          String.t(),
          JidoClaw.Conversations.Session.t() | nil
        ) :: :ok | {:error, term()}
  def inject_stateless_completion_prompt(pid, project_dir, session)
      when is_pid(pid) and is_binary(project_dir) do
    system_prompt =
      resolve_prompt(session, project_dir) <>
        """


        ## Stateless completion capability boundary

        Answer the supplied ordered conversation directly. This request has no tools and cannot
        launch background workflows. Never claim to have changed files, run commands, called a
        tool, or started work. You may explain or propose code, but all output is prose returned
        synchronously in this response.
        """

    do_inject(pid, system_prompt, project_dir, source_of(session), %{stateless_completion: true})
  end

  @doc """
  Inject a handoff-routed worker's system prompt: the resolved base prompt
  PLUS an additive handoff-context block (message + reason + summary).

  This is deliberately separate from `inject_system_prompt/3` — it does NOT
  replace the base prompt with the handoff context, it appends to it, so the
  routed worker carries BOTH its base instructions AND its assignment
  context. Because the result lands in the agent's *system prompt*, the
  compaction `RequestTransformer` keeps it across every compaction (system
  rows are never dropped), giving the worker an always-retained handoff
  context independent of the per-turn preamble (consumed once) and the
  durable `:system` row (which only feeds the summarized source).

  `handoff_context` is a map with optional `:message`, `:reason`,
  `:summary`, and `:from_template` keys.
  """
  @spec inject_handoff_prompt(
          pid(),
          String.t(),
          JidoClaw.Conversations.Session.t() | nil,
          map()
        ) :: :ok | {:error, term()}
  def inject_handoff_prompt(pid, project_dir, session, handoff_context)
      when is_pid(pid) and is_binary(project_dir) and is_map(handoff_context) do
    base = resolve_prompt(session, project_dir)
    combined = base <> "\n\n" <> handoff_block(handoff_context)
    do_inject(pid, combined, project_dir, source_of(session), %{handoff: true})
  end

  @doc """
  Inject the AR-5 doctrine system prompt onto a freshly-spawned sub-agent pid — the
  first system prompt spawn/skill workers receive. Gated by
  `config :jido_claw, :doctrine, enabled?:` (disabled → no-op `:ok`). Best-effort: any
  failure logs and returns `:ok`, never blocking the spawn. Reuses `do_inject/5`
  (emits `[:jido_claw, :agent, :prompt_injected]`, source `:doctrine`).

  `catalog_stage_name` (AR-6) is the composer stage the worker runs as — set ONLY by the
  wave-builder path, `nil` for a direct spawn / follow-up / non-composer skill step. It
  steers persona resolution inside `SubagentPrompt.build/3` and rides the telemetry as
  `metadata.stage`. The `:doctrine` flag remains the master gate (off → no injection at
  all); `:psychology` only toggles the `## PSYCHOLOGY` section within an injected prompt.
  """
  @spec inject_subagent_prompt(pid(), String.t(), map(), String.t() | nil) :: :ok
  def inject_subagent_prompt(pid, template_name, tool_context, catalog_stage_name \\ nil)
      when is_pid(pid) and is_binary(template_name) do
    if doctrine_enabled?() do
      project_dir = Map.get(tool_context, :project_dir) || File.cwd!()
      prompt = SubagentPrompt.build(template_name, tool_context, catalog_stage_name)

      # do_inject/5 returns :ok | {:error, reason} — log the error tuple too, not
      # just raises/exits.
      meta = %{template: template_name, stage: catalog_stage_name}

      case do_inject(pid, prompt, project_dir, :doctrine, meta) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Doctrine] set_system_prompt failed (#{template_name}): #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning("[Doctrine] subagent prompt injection failed: #{Exception.message(e)}")
      :ok
  catch
    # dead/slow pid — never block the spawn
    :exit, _ -> :ok
  end

  @doc """
  The gated subagent system-prompt STRING for an executor surface that cannot
  receive an injected prompt (the vendor-executor argv — executor-seam PR-2
  P1a): the same `SubagentPrompt.build/3` contract in-process workers get,
  behind the same `:doctrine` master gate as `inject_subagent_prompt/4`.
  Returns `nil` when the gate is off (the vendor prompt then starts at the
  task — byte-consistent with the in-process doctrine-off behavior) or when
  the build fails (best-effort, never raises — the existing posture).
  """
  @spec subagent_prompt(String.t(), map(), String.t() | nil) :: String.t() | nil
  def subagent_prompt(template_name, tool_context, catalog_stage_name \\ nil)
      when is_binary(template_name) do
    if doctrine_enabled?() do
      SubagentPrompt.build(template_name, tool_context, catalog_stage_name)
    end
  rescue
    # reach:disable-next-line bare_rescue
    e ->
      Logger.warning(
        "[Doctrine] subagent prompt build failed (#{template_name}): #{Exception.message(e)}"
      )

      nil
  end

  defp doctrine_enabled? do
    :jido_claw
    |> Application.get_env(:doctrine, [])
    |> Keyword.get(:enabled?, @doctrine_defaults[:enabled?])
  end

  defp do_inject(pid, prompt, project_dir, source, extra_metadata) do
    case Jido.AI.set_system_prompt(pid, prompt) do
      {:ok, _} ->
        :telemetry.execute(
          [:jido_claw, :agent, :prompt_injected],
          %{bytes: byte_size(prompt)},
          Map.merge(%{pid: pid, project_dir: project_dir, source: source}, extra_metadata)
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handoff_block(handoff_context) do
    message =
      handoff_context
      |> Map.get(:message)
      |> present_or("not provided")

    reason =
      handoff_context
      |> Map.get(:reason)
      |> present_or("not provided")

    summary =
      handoff_context
      |> Map.get(:summary)
      |> present_or("not provided")

    from =
      handoff_context
      |> Map.get(:from_template)
      |> present_or("main")

    preamble = """
    [HANDOFF CONTEXT — you have been assigned this conversation.
    Handing-off agent: #{from}
    Reason: #{reason}
    Summary: #{summary}
    Message: #{message}
    Treat this as standing context for the remainder of the conversation.]
    """

    String.trim_trailing(preamble)
  end

  defp present_or(value, _default) when is_binary(value) and value != "", do: value
  defp present_or(_value, default), do: default

  @doc """
  Resolve the system prompt for a session: the persisted
  `metadata["prompt_snapshot"]` verbatim when present, else a live
  `Prompt.build/1` from disk.

  Public so `JidoClaw.Conversations.ContextRestore` shares the exact byte
  source with `inject_system_prompt/3` — a restored context must carry the
  same system-prompt bytes the injection path uses, or the prompt-cache
  prefix breaks on resume (CC2-2).
  """
  @spec resolve_prompt(JidoClaw.Conversations.Session.t() | map() | nil, String.t()) ::
          String.t()
  def resolve_prompt(%{metadata: %{"prompt_snapshot" => snap}}, _project_dir)
      when is_binary(snap) and snap != "" do
    snap
  end

  def resolve_prompt(_session, project_dir), do: Prompt.build(project_dir)

  defp source_of(%{metadata: %{"prompt_snapshot" => snap}}) when is_binary(snap) and snap != "",
    do: :snapshot

  defp source_of(_), do: :live

  @doc """
  Parse `project_dir` from argv (the first non-flag argument that resolves to
  an existing directory). Used by escript and mix-task entry points before
  starting the app so `Application.get_env(:jido_claw, :project_dir)` is set
  to the correct value from the very first child spec.
  """
  @spec resolve_project_dir_from_argv([String.t()]) :: String.t()
  def resolve_project_dir_from_argv(args) when is_list(args) do
    case Enum.find(args, fn arg -> is_binary(arg) and not String.starts_with?(arg, "--") end) do
      nil ->
        File.cwd!()

      candidate ->
        expanded = Path.expand(candidate)
        if File.dir?(expanded), do: expanded, else: File.cwd!()
    end
  end
end
