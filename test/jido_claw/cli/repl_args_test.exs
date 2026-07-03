defmodule JidoClaw.CLI.ReplArgsTest do
  @moduledoc """
  Pins the strict REPL flag contract (review P2): a bad flag, a valueless
  or empty/blank `--resume` (`--resume`, `--resume=`, `--resume ""`), or a
  `--resume/--continue` conflict is a `{:usage, _}` return (the entry files
  map it to exit 2) instead of silently booting a fresh session, while
  valid argv keeps today's positional-dir semantics.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.CLI.ReplArgs

  setup do
    tmp = Path.join(System.tmp_dir!(), "repl-args-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "zero args resolve to cwd with no resume flags" do
    assert {:ok, %{project_dir: dir, resume: nil, continue: false}} = ReplArgs.parse([])
    assert dir == File.cwd!()
  end

  test "a positional directory becomes the project dir", ctx do
    assert {:ok, %{project_dir: dir, resume: nil, continue: false}} = ReplArgs.parse([ctx.tmp])
    assert dir == Path.expand(ctx.tmp)
  end

  test "--resume <uuid> parses the uuid" do
    uuid = Ecto.UUID.generate()

    assert {:ok, %{resume: ^uuid, continue: false}} = ReplArgs.parse(["--resume", uuid])
  end

  test "--resume <uuid> <dir> takes the dir from positionals, never the uuid", ctx do
    uuid = Ecto.UUID.generate()

    assert {:ok, %{project_dir: dir, resume: ^uuid}} =
             ReplArgs.parse(["--resume", uuid, ctx.tmp])

    assert dir == Path.expand(ctx.tmp)
  end

  test "--continue parses to continue: true" do
    assert {:ok, %{resume: nil, continue: true}} = ReplArgs.parse(["--continue"])
  end

  test "an unknown flag is a usage error naming it" do
    assert {:usage, message} = ReplArgs.parse(["--bogus"])
    assert message =~ "invalid option(s)"
    assert message =~ "--bogus"
  end

  test "--resume without a value is a usage error naming --resume" do
    assert {:usage, message} = ReplArgs.parse(["--resume"])
    assert message =~ "invalid option(s)"
    assert message =~ "--resume"
  end

  test "--resume= (explicit empty value) is a usage error naming --resume" do
    assert {:usage, message} = ReplArgs.parse(["--resume="])
    assert message =~ "--resume"
    assert message =~ "requires a session uuid"
  end

  test "--resume with an empty-string value is a usage error" do
    assert {:usage, message} = ReplArgs.parse(["--resume", ""])
    assert message =~ "requires a session uuid"
  end

  test "--resume with a whitespace-only value is a usage error" do
    assert {:usage, message} = ReplArgs.parse(["--resume", "  "])
    assert message =~ "requires a session uuid"
  end

  test "--resume= --continue reports the blank value, not just the conflict" do
    assert {:usage, message} = ReplArgs.parse(["--resume=", "--continue"])
    assert message =~ "requires a session uuid"
  end

  test "--resume and --continue together are mutually exclusive" do
    assert {:usage, message} = ReplArgs.parse(["--resume", Ecto.UUID.generate(), "--continue"])
    assert message =~ "mutually exclusive"
  end
end
