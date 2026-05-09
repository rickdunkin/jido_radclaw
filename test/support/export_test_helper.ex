defmodule JidoClaw.ExportTestHelper do
  @moduledoc """
  Shared boilerplate for the v0.6 export Mix-task acceptance gates.

  Each test:

    * creates a per-test temp `project_dir` under `System.tmp_dir!()`,
      so concurrent tests cannot stomp on each other's `.jido/` dir.
    * copies the input fixture tree into that dir, optionally renaming
      a tenant-named subdirectory under `.jido/sessions/<tenant>/`.
    * registers an `on_exit` that removes the temp dir when the test
      finishes, win or lose.

  Every Mix.Task we exercise (`jidoclaw.migrate.*`, `jidoclaw.export.*`)
  has to be `Mix.Task.reenable/1`'d between successive runs in the same
  test — without that, the second invocation is a no-op and the
  idempotency assertion is meaningless.
  """

  @doc """
  Allocate a unique scratch project directory under tmp; register
  cleanup via `on_exit`.
  """
  @spec unique_project_dir(String.t()) :: String.t()
  def unique_project_dir(label) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "jidoclaw-export-test-#{label}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  Copy a fixture tree onto `project_dir`. Skips when the fixture
  directory is missing — useful when a test only needs an empty
  `.jido/` skeleton.
  """
  @spec copy_fixture(Path.t(), Path.t()) :: :ok
  def copy_fixture(fixture_dir, project_dir) do
    if File.exists?(fixture_dir) do
      File.cp_r!(fixture_dir, project_dir)
    end

    :ok
  end

  @doc """
  Rename the conversations-fixture's `.jido/sessions/<from>/` subdir
  to `<to>` so each test gets a unique tenant_id.
  """
  @spec rename_session_tenant(Path.t(), String.t(), String.t()) :: :ok
  def rename_session_tenant(project_dir, from_tenant, to_tenant) do
    src = Path.join([project_dir, ".jido", "sessions", from_tenant])

    if File.exists?(src) do
      dst = Path.join([project_dir, ".jido", "sessions", to_tenant])
      File.rename!(src, dst)
    end

    :ok
  end

  @doc """
  Re-enable the named Mix.Task so a subsequent `Mix.Task.run/2` actually
  executes. Mix tasks are one-shot by default — without this, the second
  call is silently skipped.
  """
  @spec reenable!(String.t()) :: :ok
  def reenable!(name) do
    Mix.Task.reenable(name)
    :ok
  end
end
