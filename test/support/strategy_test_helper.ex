defmodule JidoClaw.Reasoning.StrategyTestHelper do
  @moduledoc """
  Shared helpers for tests that need to register transient user strategy
  aliases or pipelines against the supervised `StrategyStore` /
  `PipelineStore`.

  ## `async: false` invariant

  Both stores are named singletons started in the app supervision tree.
  Every helper in this module mutates their state (write a YAML file,
  reload, run the caller's body, delete the file, reload again). Tests
  that `import` this module MUST declare `use ExUnit.Case, async: false`
  — parallel cases racing on the same named process would see each
  other's aliases and produce flakes.
  """

  @doc """
  Writes `yaml` into `.jido/strategies/` under the configured project
  directory, reloads the supervised `StrategyStore`, invokes `fun.()`,
  and cleans up the file + reloads again on exit (including when `fun`
  raises).

  The YAML filename is unique per invocation, so nesting calls in the
  same test is safe.
  """
  def with_user_strategy(yaml, fun) when is_binary(yaml) and is_function(fun, 0) do
    with_user_yaml(
      "strategies",
      "strategy_test_helper_alias_",
      JidoClaw.Reasoning.StrategyStore,
      yaml,
      fun
    )
  end

  @doc """
  Writes `yaml` into `.jido/pipelines/` under the configured project
  directory, reloads the supervised `PipelineStore`, invokes `fun.()`,
  and cleans up the file + reloads again on exit.

  Mirror of `with_user_strategy/2` for pipeline fixtures.
  """
  def with_user_pipeline(yaml, fun) when is_binary(yaml) and is_function(fun, 0) do
    with_user_yaml(
      "pipelines",
      "pipeline_test_helper_",
      JidoClaw.Reasoning.PipelineStore,
      yaml,
      fun
    )
  end

  defp with_user_yaml(subdir, filename_prefix, store, yaml, fun) do
    project_dir = Application.get_env(:jido_claw, :project_dir, File.cwd!())
    dir = Path.join([project_dir, ".jido", subdir])
    File.mkdir_p!(dir)

    path =
      Path.join(dir, "#{filename_prefix}#{System.unique_integer([:positive])}.yaml")

    File.write!(path, yaml)

    try do
      store.reload()
      fun.()
    after
      File.rm(path)
      store.reload()
    end
  end
end
