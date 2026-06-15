defmodule JidoClaw.Orchestration.Replay.DefinitionResolver do
  @moduledoc """
  Fresh, never-cached re-resolution of a `WorkflowRun`'s definition — the
  shared gate behind both `JidoClaw.Orchestration.Replay.replay/2` (which folds
  it via `with`, short-circuiting on the first failure) and
  `JidoClaw.Orchestration.Replay.Diagnostics.diagnose/2` (which calls it to
  report `definition.status` without short-circuiting). Extracted from
  `Replay` so the replay gate and the diagnostic projection can never drift
  in how they recompute the current fingerprint.

  Two kinds, two resolution paths:

    * **skill** — re-loaded from **disk** via `Skills.load_skill/2` (matched on
      the skill's `name:` field, never a filename built from the run name) using
      `config["project_dir"]` recorded at launch, then compiled. The boot-time
      `Skills.get/2` cache is deliberately bypassed: it would mask exactly the
      on-disk YAML edit the hash gate exists to catch. The resolved map carries
      the freshly re-resolved `skill.deadline` so a deadline-only edit (excluded
      from the fingerprint) rides to launch.
    * **module** — a `config["reactor"]` identity accepted only under the
      `JidoClaw.Orchestration.Reactors.` prefix (the atom-creation fence; note
      the identity is `inspect(module)` — no `Elixir.` prefix) and resolved to a
      loaded reactor module via `String.to_existing_atom/1`.

  The `{:ok, %{kind, reactor, hash} | %{kind, reactor, hash, deadline}}` map is
  the shared contract — module resolution omits `:deadline` (a module replay
  preserves the original run's policy; see `Replay.replay/2`).

  This module performs **definition resolution only** — it never scans the
  event log (the irreversible-executed gate lives in
  `JidoClaw.Orchestration.Replay.Safety`).
  """

  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler

  # Atom-creation fence for module-kind runs (GateResume precedent): a config
  # identity must name a reactor in our own namespace before
  # `String.to_existing_atom/1` runs. No `Elixir.` prefix — the identity is
  # `inspect(module)`.
  @allowed_module_prefix "JidoClaw.Orchestration.Reactors."

  @type resolved :: %{
          :kind => String.t(),
          :reactor => module() | struct(),
          :hash => String.t(),
          optional(:deadline) => term()
        }

  @doc """
  The run's definition kind from `config["definition_kind"]`. `config` is
  string-keyed jsonb on read; runs created before Phase 4 (or outside
  `ReactorRunner`) carry no kind and are simply not replayable.
  """
  @spec definition_kind(WorkflowRun.t()) ::
          {:ok, String.t()} | {:error, {:not_replayable, :no_definition_kind}}
  def definition_kind(%WorkflowRun{config: config}) when is_map(config) do
    case Map.get(config, "definition_kind") do
      kind when kind in ["skill", "module"] -> {:ok, kind}
      _other -> {:error, {:not_replayable, :no_definition_kind}}
    end
  end

  def definition_kind(_run), do: {:error, {:not_replayable, :no_definition_kind}}

  @doc """
  Re-resolve the definition of `original` for the already-determined `kind`,
  computing the **current** fingerprint fresh from disk (skills) or BEAM md5
  (modules). Returns the shared `t:resolved/0` contract, or
  `{:error, {:not_replayable, reason}}` on a resolution failure.
  """
  @spec resolve(String.t(), WorkflowRun.t()) ::
          {:ok, resolved()} | {:error, {:not_replayable, term()}}
  def resolve("skill", original) do
    name = original.config["reactor"]

    with {:ok, skill} <- lookup_skill(name, skill_project_dir(original)),
         {:ok, reactor} <- compile_skill(skill) do
      {:ok,
       %{
         kind: "skill",
         reactor: reactor,
         hash: DefinitionFingerprint.for_skill(skill),
         # The freshly re-resolved run-level deadline rides to launch — see
         # Replay.replay_deadline/2 for the skill/module source asymmetry.
         deadline: skill.deadline
       }}
    end
  end

  def resolve("module", original) do
    identity = original.config["reactor"]

    with :ok <- check_allowed_module(identity),
         {:ok, module} <- resolve_module(identity) do
      {:ok, %{kind: "module", reactor: module, hash: DefinitionFingerprint.for_module(module)}}
    end
  end

  # The fresh-disk lookup (`Skills.load_skill/2`), NOT the cached `Skills.get/2`
  # — comparing the stored hash against the boot-time cache would defeat the
  # gate whenever the YAML changed on disk after boot.
  defp lookup_skill(name, project_dir) do
    case Skills.load_skill(name, project_dir) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:not_replayable, :skill_unavailable}}
      {:error, {:duplicate_skill_name, _name} = dup} -> {:error, {:not_replayable, dup}}
    end
  end

  # Recorded at launch by `ReactorRunner.run_config/3` when the caller's scope
  # carried one; absent (e.g. a cron run launched from the app root) falls
  # back to the current working directory, mirroring the launch-path default.
  defp skill_project_dir(%WorkflowRun{config: config}) do
    case Map.get(config, "project_dir") do
      dir when is_binary(dir) -> dir
      _missing -> File.cwd!()
    end
  end

  defp compile_skill(skill) do
    case Compiler.compile(skill) do
      {:ok, reactor} -> {:ok, reactor}
      {:error, reason} -> {:error, {:not_replayable, {:compile_failed, reason}}}
    end
  end

  defp check_allowed_module(identity) when is_binary(identity) do
    if String.starts_with?(identity, @allowed_module_prefix) do
      :ok
    else
      {:error, {:not_replayable, {:disallowed_module, identity}}}
    end
  end

  defp check_allowed_module(identity),
    do: {:error, {:not_replayable, {:disallowed_module, identity}}}

  # `String.to_existing_atom/1` (never `to_atom/1`) on the prefix-fenced
  # identity: to have created this run the module must have been loaded, so
  # its atom exists; if not, the module is gone from this VM and the run
  # cannot be replayed anyway.
  defp resolve_module(identity) do
    module = String.to_existing_atom("Elixir." <> identity)

    if Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Reactor) do
      {:ok, module}
    else
      {:error, {:not_replayable, :module_unavailable}}
    end
  rescue
    ArgumentError -> {:error, {:not_replayable, :module_unavailable}}
  end
end
