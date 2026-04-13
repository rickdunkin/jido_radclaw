defmodule JidoClaw.MemoryTest do
  use ExUnit.Case

  # Not async: Memory registers as JidoClaw.Memory (named), and the ETS tables
  # it uses are global named tables. Isolation is enforced through sequential
  # execution and explicit ETS cleanup between tests.

  # ETS table names created by Jido.Memory.Store.ETS with base :jido_claw_memory
  @ets_tables [
    :jido_claw_memory_records,
    :jido_claw_memory_ns_time,
    :jido_claw_memory_ns_class_time,
    :jido_claw_memory_ns_tag
  ]

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_memory_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # JidoClaw.Memory is started by the Application supervision tree.
    # Stop it via the supervisor (prevents immediate restart), start a test-scoped
    # instance pointing at tmp_dir, and restore the app child on exit.
    app_sup = Process.whereis(JidoClaw.Supervisor)

    if app_sup && Process.alive?(app_sup) do
      Supervisor.terminate_child(app_sup, JidoClaw.Memory)
    else
      if pid = Process.whereis(JidoClaw.Memory), do: Process.exit(pid, :kill)
    end

    # Wipe ETS tables before starting the test instance. The app-managed Memory
    # may have loaded project memories during a prior on_exit restart, and those
    # rows survive process termination when the tables aren't process-owned.
    clear_ets_tables(@ets_tables)

    {:ok, mem_pid} =
      GenServer.start_link(JidoClaw.Memory, [project_dir: tmp_dir], name: JidoClaw.Memory)

    on_exit(fn ->
      clear_ets_tables(@ets_tables)

      if Process.alive?(mem_pid), do: GenServer.stop(mem_pid, :normal, 5000)

      # Restore the app-managed Memory child
      if app_sup && Process.alive?(app_sup) do
        Supervisor.restart_child(app_sup, JidoClaw.Memory)
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mem_pid: mem_pid}
  end

  # ---------------------------------------------------------------------------
  # remember/3 + recall/2 — basic store-and-retrieve
  # ---------------------------------------------------------------------------

  describe "remember/3" do
    test "stores a memory that can be recalled by key" do
      assert :ok = JidoClaw.Memory.remember("elixir_pattern", "Use GenServer for state", "fact")

      results = JidoClaw.Memory.recall("elixir_pattern")

      assert length(results) == 1
      [entry] = results
      assert entry.key == "elixir_pattern"
      assert entry.content == "Use GenServer for state"
    end

    test "stores a memory that can be recalled by content substring" do
      assert :ok =
               JidoClaw.Memory.remember(
                 "otp_tip",
                 "supervisors restart crashed children",
                 "pattern"
               )

      results = JidoClaw.Memory.recall("supervisors")

      assert Enum.any?(results, fn e -> e.key == "otp_tip" end)
    end

    test "stores a memory that can be recalled by type/kind" do
      assert :ok = JidoClaw.Memory.remember("arch_decision", "Use Phoenix for HTTP", "decision")

      results = JidoClaw.Memory.recall("decision")

      assert Enum.any?(results, fn e -> e.key == "arch_decision" end)
    end

    test "returns :ok regardless of type" do
      assert :ok = JidoClaw.Memory.remember("k1", "content", "fact")
      assert :ok = JidoClaw.Memory.remember("k2", "content", "pattern")
      assert :ok = JidoClaw.Memory.remember("k3", "content", "decision")
      assert :ok = JidoClaw.Memory.remember("k4", "content", "preference")
    end

    test "uses 'fact' as the default type when type argument is omitted" do
      assert :ok = JidoClaw.Memory.remember("default_type_key", "some content")

      results = JidoClaw.Memory.recall("default_type_key")
      assert length(results) == 1
      [entry] = results
      assert entry.type == "fact"
    end
  end

  # ---------------------------------------------------------------------------
  # Upsert behaviour
  # ---------------------------------------------------------------------------

  describe "upsert behaviour" do
    test "re-remembering an existing key updates the content" do
      JidoClaw.Memory.remember("my_key", "original content", "fact")
      JidoClaw.Memory.remember("my_key", "updated content", "fact")

      results = JidoClaw.Memory.recall("my_key")

      # Only one entry — not a duplicate
      assert length(results) == 1
      [entry] = results
      assert entry.content == "updated content"
    end

    test "upserted entry preserves the key but allows type change" do
      JidoClaw.Memory.remember("versioned_key", "first", "fact")
      JidoClaw.Memory.remember("versioned_key", "second", "decision")

      results = JidoClaw.Memory.recall("versioned_key")
      assert length(results) == 1
      [entry] = results
      assert entry.key == "versioned_key"
      assert entry.content == "second"
      assert entry.type == "decision"
    end
  end

  # ---------------------------------------------------------------------------
  # recall/2
  # ---------------------------------------------------------------------------

  describe "recall/2" do
    test "returns empty list when no memories match the query" do
      JidoClaw.Memory.remember("irrelevant_key", "some content", "fact")

      assert [] = JidoClaw.Memory.recall("zzz_no_match_xyz")
    end

    test "returns empty list when store is empty" do
      assert [] = JidoClaw.Memory.recall("anything")
    end

    test "search is case-insensitive for content" do
      JidoClaw.Memory.remember("ci_content", "Elixir Rocks", "fact")

      assert [_] = JidoClaw.Memory.recall("elixir rocks")
      assert [_] = JidoClaw.Memory.recall("ELIXIR ROCKS")
      assert [_] = JidoClaw.Memory.recall("Elixir Rocks")
    end

    test "search is case-insensitive for key" do
      JidoClaw.Memory.remember("MySpecialKey", "content", "fact")

      assert [_] = JidoClaw.Memory.recall("myspecialkey")
      assert [_] = JidoClaw.Memory.recall("MYSPECIALKEY")
    end

    test "respects the :limit option" do
      for i <- 1..5 do
        JidoClaw.Memory.remember("limit_key_#{i}", "shared pattern content #{i}", "fact")
      end

      results = JidoClaw.Memory.recall("pattern", limit: 3)
      assert length(results) == 3
    end

    test "returns all matches when limit exceeds result count" do
      JidoClaw.Memory.remember("alpha", "rare_token_xyz content", "fact")
      JidoClaw.Memory.remember("beta", "rare_token_xyz content too", "fact")

      results = JidoClaw.Memory.recall("rare_token_xyz", limit: 100)
      assert length(results) == 2
    end

    test "result entries include all expected fields" do
      JidoClaw.Memory.remember("field_check", "content here", "preference")

      [entry] = JidoClaw.Memory.recall("field_check")

      assert Map.has_key?(entry, :key)
      assert Map.has_key?(entry, :content)
      assert Map.has_key?(entry, :type)
      assert Map.has_key?(entry, :created_at)
      assert Map.has_key?(entry, :updated_at)
    end
  end

  # ---------------------------------------------------------------------------
  # forget/1
  # ---------------------------------------------------------------------------

  describe "forget/1" do
    test "removes a memory so it no longer appears in recall" do
      JidoClaw.Memory.remember("to_forget", "delete me", "fact")

      assert [_] = JidoClaw.Memory.recall("to_forget")
      assert :ok = JidoClaw.Memory.forget("to_forget")
      assert [] = JidoClaw.Memory.recall("to_forget")
    end

    test "returns :ok when the key does not exist" do
      assert :ok = JidoClaw.Memory.forget("nonexistent_key_abc")
    end

    test "only removes the specified key, leaving others intact" do
      JidoClaw.Memory.remember("keep_this", "stays around", "fact")
      JidoClaw.Memory.remember("remove_this", "goes away", "fact")

      JidoClaw.Memory.forget("remove_this")

      assert [] = JidoClaw.Memory.recall("remove_this")
      assert [_] = JidoClaw.Memory.recall("keep_this")
    end
  end

  # ---------------------------------------------------------------------------
  # list_recent/1
  # ---------------------------------------------------------------------------

  describe "list_recent/1" do
    test "returns N most recently written memories" do
      for i <- 1..5 do
        JidoClaw.Memory.remember("recent_#{i}", "content #{i}", "fact")
        # Small sleep ensures distinct millisecond timestamps for ordering
        Process.sleep(2)
      end

      results = JidoClaw.Memory.list_recent(3)
      assert length(results) == 3
    end

    test "returns all memories when limit exceeds store size" do
      JidoClaw.Memory.remember("r1", "alpha", "fact")
      JidoClaw.Memory.remember("r2", "beta", "fact")

      results = JidoClaw.Memory.list_recent(10)
      assert length(results) == 2
    end

    test "returns empty list when store is empty" do
      assert [] = JidoClaw.Memory.list_recent(5)
    end

    test "most recently added entry appears first" do
      JidoClaw.Memory.remember("older_entry", "first inserted", "fact")
      Process.sleep(2)
      JidoClaw.Memory.remember("newer_entry", "second inserted", "fact")

      [first | _] = JidoClaw.Memory.list_recent(2)
      assert first.key == "newer_entry"
    end
  end

  # ---------------------------------------------------------------------------
  # all/0
  # ---------------------------------------------------------------------------

  describe "all/0" do
    test "returns all memories when store has entries" do
      JidoClaw.Memory.remember("a1", "first", "fact")
      JidoClaw.Memory.remember("a2", "second", "pattern")
      JidoClaw.Memory.remember("a3", "third", "decision")

      results = JidoClaw.Memory.all()
      keys = Enum.map(results, & &1.key)

      assert "a1" in keys
      assert "a2" in keys
      assert "a3" in keys
    end

    test "returns empty list when store is empty" do
      assert [] = JidoClaw.Memory.all()
    end

    test "results are sorted by recency descending" do
      JidoClaw.Memory.remember("oldest", "content", "fact")
      Process.sleep(2)
      JidoClaw.Memory.remember("middle", "content", "fact")
      Process.sleep(2)
      JidoClaw.Memory.remember("newest", "content", "fact")

      [first, second, third] = JidoClaw.Memory.all()
      assert first.key == "newest"
      assert second.key == "middle"
      assert third.key == "oldest"
    end
  end

  # ---------------------------------------------------------------------------
  # JSON disk persistence
  # ---------------------------------------------------------------------------

  describe "JSON disk persistence" do
    test "memory.json is created after remember/3", %{tmp_dir: tmp_dir} do
      # remember/3 is a synchronous GenServer.call — file is written before we check
      JidoClaw.Memory.remember("persisted_key", "persisted content", "fact")

      path = Path.join(tmp_dir, ".jido/memory.json")
      assert File.exists?(path), "Expected #{path} to exist after remember/3"
    end

    test "memory.json contains the stored memory entry", %{tmp_dir: tmp_dir} do
      JidoClaw.Memory.remember("json_key", "json content value", "preference")

      path = Path.join(tmp_dir, ".jido/memory.json")
      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      assert Map.has_key?(decoded, "json_key")
      assert decoded["json_key"]["content"] == "json content value"
    end

    test "memory.json is updated (key removed) after forget/1", %{tmp_dir: tmp_dir} do
      JidoClaw.Memory.remember("delete_me", "to be removed", "fact")
      JidoClaw.Memory.forget("delete_me")

      path = Path.join(tmp_dir, ".jido/memory.json")
      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      refute Map.has_key?(decoded, "delete_me")
    end

    test "memories are reloaded from disk when GenServer restarts", %{
      tmp_dir: tmp_dir,
      mem_pid: mem_pid
    } do
      JidoClaw.Memory.remember("boot_key", "survived restart", "fact")

      # Stop the test-scoped Memory process
      GenServer.stop(mem_pid, :normal, 5000)

      # Wipe ETS so the in-memory store is empty
      Enum.each(@ets_tables, fn table ->
        if :ets.whereis(table) != :undefined do
          :ets.delete_all_objects(table)
        end
      end)

      # Restart Memory against the same directory — it should reload the JSON.
      # Use GenServer.start_link directly (app sup is still holding the terminated child).
      {:ok, _new_pid} =
        GenServer.start_link(JidoClaw.Memory, [project_dir: tmp_dir], name: JidoClaw.Memory)

      results = JidoClaw.Memory.recall("boot_key")
      assert Enum.any?(results, fn e -> e.key == "boot_key" end)
    end
  end

  # ---------------------------------------------------------------------------
  # Graceful degradation when GenServer is not running
  # ---------------------------------------------------------------------------

  describe "graceful handling when GenServer is not running" do
    test "remember/3 returns :ok when process is absent", %{mem_pid: mem_pid} do
      GenServer.stop(mem_pid, :normal, 5000)
      assert :ok = JidoClaw.Memory.remember("key", "content", "fact")
    end

    test "recall/2 returns [] when process is absent", %{mem_pid: mem_pid} do
      GenServer.stop(mem_pid, :normal, 5000)
      assert [] = JidoClaw.Memory.recall("anything")
    end

    test "forget/1 returns :ok when process is absent", %{mem_pid: mem_pid} do
      GenServer.stop(mem_pid, :normal, 5000)
      assert :ok = JidoClaw.Memory.forget("key")
    end

    test "list_recent/1 returns [] when process is absent", %{mem_pid: mem_pid} do
      GenServer.stop(mem_pid, :normal, 5000)
      assert [] = JidoClaw.Memory.list_recent(5)
    end

    test "all/0 returns [] when process is absent", %{mem_pid: mem_pid} do
      GenServer.stop(mem_pid, :normal, 5000)
      assert [] = JidoClaw.Memory.all()
    end
  end

  defp clear_ets_tables(tables) do
    Enum.each(tables, fn table ->
      try do
        if :ets.whereis(table) != :undefined do
          :ets.delete_all_objects(table)
        end
      catch
        :error, :badarg -> :ok
      end
    end)
  end
end
