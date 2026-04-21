defmodule JidoClaw.Shell.Commands.JidoTest do
  # async: false — the command touches globally-named processes
  # (JidoClaw.AgentTracker, JidoClaw.Memory, JidoClaw.Solutions.Store,
  # JidoClaw.Stats, JidoClaw.Forge.Resources.Session).
  use ExUnit.Case, async: false

  alias JidoClaw.Shell.Commands.Jido, as: Command
  alias JidoClaw.Solutions.Store, as: SolutionsStore

  @ets_table :jido_claw_solutions

  # Re-use the application-owned Solutions.Store rather than tearing it
  # down and standing up our own. A Store restart triggers a disk reload
  # from `.jido/solutions.json` at the project root, which can
  # re-surface whatever rows a prior test persisted there — flaking
  # sibling tests that assumed an empty store. Non-destructive ETS
  # cleanup only, same pattern as
  # test/jido_claw/solutions/matcher_test.exs:15-27.
  setup do
    case GenServer.whereis(SolutionsStore) do
      nil ->
        {:ok, _} = start_supervised({SolutionsStore, [project_dir: System.tmp_dir!()]})

      _pid ->
        :ok
    end

    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete_all_objects(@ets_table)
    end

    on_exit(fn ->
      if :ets.whereis(@ets_table) != :undefined do
        :ets.delete_all_objects(@ets_table)
      end
    end)

    :ok
  end

  defp collecting_emit do
    agent = Agent.start_link(fn -> [] end)
    {:ok, pid} = agent

    emit = fn {:output, chunk} ->
      Agent.update(pid, &[chunk | &1])
      :ok
    end

    read = fn ->
      pid |> Agent.get(& &1) |> Enum.reverse() |> IO.iodata_to_binary()
    end

    {emit, read}
  end

  describe "run/3 — ok outcomes" do
    test "empty args prints usage and returns {:ok, nil}" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} = Command.run(nil, %{args: []}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ "status"
      assert output =~ "memory search"
      assert output =~ "solutions find"
    end

    test "help prints usage and returns {:ok, nil}" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} = Command.run(nil, %{args: ["help"]}, emit)
      assert read.() =~ "Usage: jido"
    end

    test "status renders header and returns {:ok, nil}" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} = Command.run(nil, %{args: ["status"]}, emit)

      output = read.()
      assert output =~ "JidoClaw Status"
      assert output =~ "agents"
      assert output =~ "uptime"
    end

    test "memory search <q> invokes recall and returns {:ok, nil}" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} = Command.run(nil, %{args: ["memory", "search", "ping"]}, emit)
      assert read.() =~ "Memory search: ping"
    end

    test "memory search joins multiple words into the query" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} =
               Command.run(nil, %{args: ["memory", "search", "multi", "word", "query"]}, emit)

      assert read.() =~ "Memory search: multi word query"
    end

    test "solutions find <fp> returns {:ok, nil} for a missing signature" do
      {emit, read} = collecting_emit()

      assert {:ok, nil} =
               Command.run(nil, %{args: ["solutions", "find", "no-such-fingerprint"]}, emit)

      assert read.() =~ "No solution with that signature."
    end

    # Deliberately omitted: a "hit" case for `solutions find <fp>`.
    # Seeding the Store would either persist to the project-root
    # `.jido/solutions.json` (leaking state into sibling tests that
    # reload the Store from disk) or require a full terminate/restart
    # dance that exercises the same fragile seam. The hit-path
    # formatting is covered in
    # `JidoClaw.CLI.PresentersTest.solution_lines/1`; the integration
    # with `SolutionsStore.find_by_signature/1` is covered by the
    # not-found variant above and the end-to-end shell integration
    # test.
  end

  describe "run/3 — error outcomes" do
    test "memory search with no query emits usage + error line and returns validation error" do
      {emit, read} = collecting_emit()

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Command.run(nil, %{args: ["memory", "search"]}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ "error: query is required"
    end

    test "solutions find with no fingerprint returns validation error" do
      {emit, read} = collecting_emit()

      assert {:error, %Jido.Shell.Error{code: {:validation, :invalid_args}}} =
               Command.run(nil, %{args: ["solutions", "find"]}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ "error: fingerprint is required"
    end

    test "unknown sub-command returns shell unknown_command error with usage" do
      {emit, read} = collecting_emit()

      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}} = err} =
               Command.run(nil, %{args: ["bogus"]}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ ~s(error: unknown sub-command "bogus")
      assert err.context.name == "jido bogus"
    end

    test "trailing args on a fixed-arity sub-command are treated as unknown sub-command" do
      # `jido status foo` — `foo` falls through the status head to the
      # catch-all unknown branch by matching `%{args: [sub | _]}` with
      # sub="status" — actually, wait: the catch-all matches on first
      # element. `status foo` has first = "status" which matches the
      # `["status"]` head exactly. So `jido status foo` wouldn't dispatch
      # there. The spec says it must be treated as unknown — verify.
      #
      # Actually re-reading: the plan says "jido status foo" should fall
      # through to emit_unknown. That requires the status head to match
      # ONLY `["status"]`, which it does. `["status", "foo"]` hits the
      # catch-all with sub = "status". That's a bit awkward semantically
      # — the error says "unknown sub-command 'status'". Test the actual
      # observable behavior: exit 1 with a usage+error emission.
      {emit, read} = collecting_emit()

      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}} =
               Command.run(nil, %{args: ["status", "foo"]}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ "unknown sub-command"
    end

    test "extra args on solutions find are treated as unknown sub-command" do
      {emit, read} = collecting_emit()

      assert {:error, %Jido.Shell.Error{code: {:shell, :unknown_command}}} =
               Command.run(nil, %{args: ["solutions", "find", "abc", "def"]}, emit)

      output = read.()
      assert output =~ "Usage: jido"
      assert output =~ "unknown sub-command"
    end
  end

  describe "behaviour callbacks" do
    test "name/0 is `jido`" do
      assert Command.name() == "jido"
    end

    test "summary/0 is a non-empty string" do
      assert is_binary(Command.summary())
      assert Command.summary() != ""
    end

    test "schema/0 accepts an args array" do
      schema = Command.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{args: []})
      assert {:ok, %{args: ["status"]}} = Zoi.parse(schema, %{args: ["status"]})
    end
  end
end
