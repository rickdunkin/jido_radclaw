defmodule JidoClaw.Startup do
  @moduledoc """
  Project-local state + agent bootstrapping.

  Called from every entry point (REPL, `JidoClaw.chat/3`, escript, mix task)
  so all entry points converge on the same `.jido/` bootstrap and system-prompt
  injection path.
  """

  require Logger

  alias JidoClaw.Agent.Prompt

  @typedoc "Result of the sync branch inside the `:ok` tuple from `ensure_project_state/1`."
  @type sync_result :: :noop | :overwritten | :sidecar_written | :stamp_only

  @doc """
  Ensure project-level `.jido/` files exist and reconcile the system prompt
  with the bundled default.

  Returns `{:ok, prompt_sync: result}` so callers (e.g., the CLI REPL) can
  print a one-line notice when the `.default` sidecar was just written.
  """
  @spec ensure_project_state(String.t()) ::
          {:ok, [prompt_sync: Prompt.sync_result() | sync_result()]}
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

    case Process.whereis(JidoClaw.Reasoning.StrategyStore) do
      nil -> :ok
      _pid -> JidoClaw.Reasoning.StrategyStore.reload()
    end
  end

  defp ensure_pipelines_dir(project_dir) do
    File.mkdir_p!(Path.join([project_dir, ".jido", "pipelines"]))

    case Process.whereis(JidoClaw.Reasoning.PipelineStore) do
      nil -> :ok
      _pid -> JidoClaw.Reasoning.PipelineStore.reload()
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

    e ->
      {:error, {step, Exception.message(e)}}
  end

  @doc """
  Inject the dynamic system prompt onto an agent pid.

  Emits a `[:jido_claw, :agent, :prompt_injected]` telemetry event on success
  so tests and observers can assert injection happened without depending on
  an agent-side get-prompt API.
  """
  @spec inject_system_prompt(pid(), String.t()) :: :ok | {:error, term()}
  def inject_system_prompt(pid, project_dir) when is_pid(pid) and is_binary(project_dir) do
    system_prompt = Prompt.build(project_dir)

    case Jido.AI.set_system_prompt(pid, system_prompt) do
      {:ok, _} ->
        :telemetry.execute(
          [:jido_claw, :agent, :prompt_injected],
          %{bytes: byte_size(system_prompt)},
          %{pid: pid, project_dir: project_dir}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse `project_dir` from argv (the first non-flag argument that resolves to
  an existing directory). Used by escript and mix-task entry points before
  starting the app so `Application.get_env(:jido_claw, :project_dir)` is set
  to the correct value from the very first child spec.
  """
  @spec resolve_project_dir_from_argv([String.t()]) :: String.t()
  def resolve_project_dir_from_argv(args) when is_list(args) do
    args
    |> Enum.find(fn arg -> is_binary(arg) and not String.starts_with?(arg, "--") end)
    |> case do
      nil ->
        File.cwd!()

      candidate ->
        expanded = Path.expand(candidate)
        if File.dir?(expanded), do: expanded, else: File.cwd!()
    end
  end
end
