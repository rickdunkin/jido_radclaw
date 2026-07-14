defmodule JidoClaw.CLI.RunCommandBootEnvTest do
  @moduledoc """
  THE regression for the escript `run` path's pre-boot env: under the
  escript's `app: nil` NOTHING is loaded when `RunCommand.boot/2` runs, and
  Mix's generated escript main has already applied the embedded config with
  `persistent: true` — so the boot's later `Application.load` (inside
  `ensure_all_started/1`) re-applies spec/persistent entries OVER plain
  pre-load puts and clobbers the config-defined `:mode`/`:model_aliases`
  pair (the one-shot binary booted Phoenix and used config-default models).
  Faithful to that unloaded-app state requires a SUBPROCESS VM — this test
  VM has both apps loaded, which is exactly why run_command_test's no-op
  boot stub could never expose the bug.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Security.Redaction.Env

  # Escript-faithful seeds first, then the helper under test, then the load
  # `ensure_all_started/1` would perform (a no-op after the fix, because
  # prime_boot_env already loaded both specs), then all four primed values
  # in a stable line-per-value format.
  @script ~S"""
  seed = fn app, key, value ->
    Application.put_env(app, key, value, persistent: true)
  end

  # Config-faithful seeds — what Mix's generated escript main does with the
  # embedded config before main/1 (config.exs defines mode: :both and the
  # model-alias catalog): the pair the old put-before-load boot lost.
  seed.(:jido_claw, :mode, :both)
  seed.(:jido_ai, :model_aliases, %{fast: "config-model", capable: "config-model"})

  # Adversarial seeds — this subprocess runs the TEST build, whose config
  # already sets skip_discord: true, so without a false seed the load alone
  # would satisfy the assertion even if prime_boot_env stopped setting it;
  # same for project_dir, absent from config today but not guaranteed so.
  seed.(:jido_claw, :skip_discord, false)
  seed.(:jido_claw, :project_dir, "/adversarial")

  :ok = JidoClaw.CLI.RunCommand.prime_boot_env("/primed/dir", "primed-model")

  for app <- [:jido_claw, :jido_ai] do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
    end
  end

  aliases = Application.get_env(:jido_ai, :model_aliases, %{})
  IO.puts("mode=#{inspect(Application.get_env(:jido_claw, :mode))}")
  IO.puts("project_dir=#{inspect(Application.get_env(:jido_claw, :project_dir))}")
  IO.puts("fast=#{inspect(aliases[:fast])} capable=#{inspect(aliases[:capable])}")
  IO.puts("skip_discord=#{inspect(Application.get_env(:jido_claw, :skip_discord))}")
  """

  test "prime_boot_env survives the boot-time Application.load under app: nil" do
    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    # One -pa per path — elixir does not accept a list after a single flag.
    args = Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", @script]

    {output, status} =
      System.cmd("elixir", args, stderr_to_stdout: true, env: Env.scrubbed_cmd_env())

    assert status == 0, "boot-env subprocess failed:\n#{output}"

    # The config-defined pair — the observed production clobber: red with a
    # put-before-load prime, green with load-then-put.
    assert output =~ "mode=:cli"
    assert output =~ ~s(fast="primed-model" capable="primed-model")

    # The adversarially seeded pair — proves ONLY the post-load override can
    # produce the primed values (a config default, present in the test build
    # for skip_discord, can never false-green these).
    assert output =~ ~s(project_dir="/primed/dir")
    assert output =~ "skip_discord=true"
  end
end
