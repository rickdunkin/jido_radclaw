defmodule JidoClaw.Test.ReplayFixtures do
  @moduledoc false

  # Shared fixtures for the replay / diagnostics suites: the on-disk skill
  # fixture, its launch path (fresh-disk load → compile → run through the
  # envelope), and the corruption-sim forged-row builder. Extracted as PUBLIC
  # functions from the private `defp`s in `replay_test.exs` so the diagnostics
  # suite can reuse them. Not an `ExUnit.Case`, so temp-dir cleanup calls
  # `ExUnit.Callbacks.on_exit/1` fully qualified.

  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler

  @fixture_name "replay_fixture"

  @fixture_yaml """
  name: replay_fixture
  description: replay fixture skill
  steps:
    - name: alpha
      template: researcher
      task: "do alpha"
    - name: beta
      template: docs_writer
      task: "do beta"
      depends_on: [alpha]
  synthesis: done
  """

  @doc "The fixture skill's `name:` field (what `Skills.load_skill/2` matches on)."
  @spec fixture_name() :: String.t()
  def fixture_name, do: @fixture_name

  @doc "The raw fixture YAML — a string so disk-edit tests can `String.replace/3` it."
  @spec fixture_yaml() :: String.t()
  def fixture_yaml, do: @fixture_yaml

  @doc "A module-kind `config` map (GatedTestReactor) for forged terminal runs."
  @spec module_config() :: map()
  def module_config,
    do: %{reactor: "JidoClaw.Orchestration.Reactors.GatedTestReactor", definition_kind: "module"}

  @doc "Create a throwaway project dir with a `.jido/skills/` tree; auto-removed on exit."
  @spec tmp_project_dir!() :: String.t()
  def tmp_project_dir! do
    dir = Path.join(System.tmp_dir!(), "replay_fix_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, ".jido", "skills"]))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Write `yaml` (default the fixture) to `dir`'s skill file."
  @spec write_fixture!(String.t(), String.t()) :: :ok
  def write_fixture!(dir, yaml \\ @fixture_yaml) do
    File.write!(Path.join([dir, ".jido", "skills", "fixture.yaml"]), yaml)
  end

  @doc """
  Swap the `Replay.EventReader` seam to one that always fails, so a test can
  exercise the irreversible-read-failure refusal/diagnostics paths without Mox
  (the run row still reads fine — only the events read fails, the realistic
  partial fault). Restores the prior value (usually absent) on exit.
  """
  @spec put_failing_event_reader!() :: :ok
  def put_failing_event_reader! do
    put_event_reader!(fn _run_id, _opts -> {:error, :simulated} end)
  end

  @doc """
  Swap the `Replay.EventReader` seam to one that reports each `(run_id, opts)`
  call to `test_pid` as `{:reader_opts, run_id, opts}` and then fails — so a
  test can assert the exact read CONTRACT (e.g. the O-M1 bounded `query:`
  filter) without launching anything (the `{:error, _}` return makes replay
  refuse deterministically). Restores the prior value on exit.
  """
  @spec put_capturing_event_reader!(pid()) :: :ok
  def put_capturing_event_reader!(test_pid) do
    put_event_reader!(fn run_id, opts ->
      send(test_pid, {:reader_opts, run_id, opts})
      {:error, :injected}
    end)
  end

  defp put_event_reader!(reader) do
    prior = Application.fetch_env(:jido_claw, :replay_event_reader)
    Application.put_env(:jido_claw, :replay_event_reader, reader)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:jido_claw, :replay_event_reader, value)
        :error -> Application.delete_env(:jido_claw, :replay_event_reader)
      end
    end)

    :ok
  end

  @doc """
  Launch the fixture exactly the way production skill callers do (fresh-disk
  load, compile, run with the skill hash + run-level deadline + project_dir
  scope), returning the resulting run whether it completed, failed, or paused.
  """
  @spec launch_fixture!(String.t(), map(), map(), map()) :: WorkflowRun.t()
  def launch_fixture!(
        dir,
        %{tenant: tenant, actor: actor},
        context_overrides \\ %{},
        inputs \\ %{extra_context: "initial"}
      ) do
    {:ok, skill} = Skills.load_skill(@fixture_name, dir)
    {:ok, reactor} = Compiler.compile(skill)

    context = Map.merge(%{project_dir: dir}, context_overrides)

    result =
      ReactorRunner.run(reactor, inputs,
        tenant: tenant,
        actor: actor,
        name: skill.name,
        async?: true,
        definition_hash: DefinitionFingerprint.for_skill(skill),
        deadline: skill.deadline,
        context: context
      )

    # A run that launched then failed still produced a run row (the uniform
    # envelope) — return it so failure-path diagnostics tests can read it.
    case result do
      {:ok, _value, run} -> run
      {:error, _reason, %WorkflowRun{} = run} -> run
    end
  end

  @doc """
  Forge a terminal run from `attrs`: create it, then force `:completed` via the
  private projection action (the `human_gates_test` corruption-sim precedent),
  bypassing the event log. Used to exercise refusal/diagnostic taxonomy on rows
  the normal launch path can't easily produce.
  """
  @spec forge_terminal_run!(map(), map()) :: WorkflowRun.t()
  def forge_terminal_run!(attrs, %{tenant: tenant, actor: actor}) do
    {:ok, run} = WorkflowRun.create(attrs, tenant: tenant, actor: actor)

    {:ok, completed} =
      run
      |> Ash.Changeset.for_update(:set_status, %{status: :completed},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update()

    completed
  end
end
