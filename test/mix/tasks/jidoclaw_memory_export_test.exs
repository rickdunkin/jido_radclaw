defmodule Mix.Tasks.Jidoclaw.MemoryExportTest do
  # `async: false` — Mix.Task state is process-global; ApplicationEnv
  # writes (e.g. the migrate task's `app.start`) leak between tests.
  use ExUnit.Case, async: false

  import JidoClaw.ExportTestHelper

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Repo
  alias JidoClaw.Security.Redaction.Patterns

  @fixtures Path.expand("../../fixtures/exports/memory", __DIR__)

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "round-trip via migrate.memory + export.memory" do
    test "export of sanitized fixture is byte-deterministic across re-runs" do
      project_dir = unique_project_dir("memory-sanitized")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)

      out_path = Path.join([project_dir, "memory-export-1.json"])
      out_path_b = Path.join([project_dir, "memory-export-2.json"])

      first_log =
        ExUnit.CaptureIO.capture_io(fn ->
          reenable!("jidoclaw.migrate.memory")
          Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir])
        end)

      # First migrate: every entry is a fresh insert.
      assert first_log =~ ~r/facts inserted: 3/
      assert first_log =~ ~r/facts skipped \(already present\): 0/

      reenable!("jidoclaw.export.memory")
      Mix.Task.run("jidoclaw.export.memory", ["--project", project_dir, "--out", out_path])

      assert File.exists?(out_path)
      bytes_a = File.read!(out_path)

      # Pin the actual DB row count after the first migrate so the
      # idempotency claim has teeth.
      row_count_after_first = memory_facts_count()
      assert row_count_after_first > 0

      # Re-run migrate to assert idempotency: `import_hash` dedup means
      # the second pass MUST NOT add any new rows.
      second_log =
        ExUnit.CaptureIO.capture_io(fn ->
          reenable!("jidoclaw.migrate.memory")
          Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir])
        end)

      # Second migrate: every entry is skipped via the import_hash
      # pre-check, NOT counted as an insert. The reported numbers
      # back the row-count assertion below.
      assert second_log =~ ~r/facts inserted: 0/
      assert second_log =~ ~r/facts skipped \(already present\): 3/

      assert memory_facts_count() == row_count_after_first,
             "second migrate inserted new memory_fact rows; import_hash dedup is broken"

      reenable!("jidoclaw.export.memory")
      Mix.Task.run("jidoclaw.export.memory", ["--project", project_dir, "--out", out_path_b])

      bytes_b = File.read!(out_path_b)

      assert bytes_a == bytes_b,
             "memory export is not byte-deterministic across re-runs"
    end

    test "with-redaction-delta export agrees with Patterns.redact_with_count/1 on post-migrate content" do
      project_dir = unique_project_dir("memory-secrets")
      copy_fixture(Path.join(@fixtures, "with_secrets"), project_dir)

      out_path = Path.join([project_dir, "memory-export.json"])

      # Sanity-check the fixture itself: the raw bytes contain secrets
      # that the redaction patterns would scrub. If a future fixture
      # update accidentally removes the sample secrets, this assertion
      # makes the test fail loudly rather than passing on a no-op.
      raw_fixture =
        File.read!(Path.join([project_dir, ".jido", "memory.json"]))

      assert raw_fixture =~ ~r/sk-[A-Za-z0-9]+/, "fixture must contain a sample API key"
      assert raw_fixture =~ ~r/ghp_[A-Za-z0-9]+/, "fixture must contain a sample GH PAT"

      reenable!("jidoclaw.migrate.memory")
      Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir])

      reenable!("jidoclaw.export.memory")

      Mix.Task.run("jidoclaw.export.memory", [
        "--project",
        project_dir,
        "--out",
        out_path,
        "--with-redaction-delta"
      ])

      payload = out_path |> File.read!() |> Jason.decode!()

      facts = payload["facts"]
      assert [_ | _] = facts

      # Each row's `redactions_applied` must agree with re-running
      # `Patterns.redact_with_count/1` over the same post-migrate
      # content. Migrate redacts at the storage boundary, so this
      # count will typically be 0 — confirming convergence between
      # the export task and the pattern matcher.
      Enum.each(facts, fn fact ->
        content = fact["content"] || ""
        {_, count} = Patterns.redact_with_count(content)
        assert fact["redactions_applied"] == count
      end)

      # The post-migrate content must NOT carry the raw secret strings
      # from the fixture — proves the migrate-time redaction fired.
      Enum.each(facts, fn fact ->
        content = fact["content"] || ""
        refute content =~ ~r/sk-[A-Za-z0-9]{20,}/
        refute content =~ ~r/ghp_[A-Za-z0-9]{36}/
      end)
    end
  end

  describe "jidoclaw.migrate.memory --dry-run" do
    test "does not create a workspace and reports projected (not actual) inserts" do
      project_dir = unique_project_dir("memory-dryrun-fresh")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)

      ws_count_before = workspaces_count()
      facts_count_before = memory_facts_count()

      log =
        ExUnit.CaptureIO.capture_io(fn ->
          reenable!("jidoclaw.migrate.memory")
          Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir, "--dry-run"])
        end)

      # No side effects: workspace count and fact count are unchanged.
      assert workspaces_count() == ws_count_before,
             "dry-run created a workspace; it must not"

      assert memory_facts_count() == facts_count_before,
             "dry-run inserted memory_facts; it must not"

      # Output uses "would" phrasing so an operator can distinguish a
      # dry run from a real one.
      assert log =~ "would be created"
      assert log =~ ~r/facts would insert: 3/
      assert log =~ ~r/facts would skip \(already present\): 0/
    end

    test "with an existing workspace, dry-run predicts skip vs insert without writing" do
      project_dir = unique_project_dir("memory-dryrun-existing")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)

      # Run a real migrate so the workspace and 3 facts exist.
      reenable!("jidoclaw.migrate.memory")
      Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir])

      ws_count_before = workspaces_count()
      facts_count_before = memory_facts_count()
      assert facts_count_before > 0

      log =
        ExUnit.CaptureIO.capture_io(fn ->
          reenable!("jidoclaw.migrate.memory")
          Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir, "--dry-run"])
        end)

      assert workspaces_count() == ws_count_before
      assert memory_facts_count() == facts_count_before

      # All three entries already imported → would skip, none inserted.
      assert log =~ ~r/facts would insert: 0/
      assert log =~ ~r/facts would skip \(already present\): 3/
    end

    test "dry-run with a relative --project resolves to the workspace stored absolutely" do
      # `Resolver.ensure_workspace/3` stores `Path.expand(project_dir)`
      # — always absolute. A subsequent dry-run with a relative
      # `--project` (e.g. `--project foo` from foo's parent dir) must
      # resolve to the same absolute path so the lookup hits the
      # existing workspace and predicts skips, not "would be created".
      raw_project_dir = unique_project_dir("memory-dryrun-relpath")
      copy_fixture(Path.join(@fixtures, "sanitized"), raw_project_dir)

      # Canonicalize the project path so a platform-level symlink
      # (e.g. macOS `/var` → `/private/var` under `System.tmp_dir!()`)
      # doesn't desync the real migrate's stored `Path.expand` value
      # from the dry-run's `Path.expand` after `File.cd!/1` rewrites
      # cwd through the symlink. `Path.expand/1` itself does not
      # follow symlinks; cd-and-cwd does. We pin `project_dir` to the
      # canonical form so both code paths land on the same absolute
      # string.
      project_dir = canonicalize(raw_project_dir)

      # Real migrate with the canonicalized absolute path first.
      reenable!("jidoclaw.migrate.memory")
      Mix.Task.run("jidoclaw.migrate.memory", ["--project", project_dir])

      ws_count_before = workspaces_count()
      facts_count_before = memory_facts_count()
      assert facts_count_before > 0

      parent = Path.dirname(project_dir)
      relative = Path.relative_to(project_dir, parent)
      prev_cwd = File.cwd!()

      log =
        try do
          File.cd!(parent)

          ExUnit.CaptureIO.capture_io(fn ->
            reenable!("jidoclaw.migrate.memory")
            Mix.Task.run("jidoclaw.migrate.memory", ["--project", relative, "--dry-run"])
          end)
        after
          File.cd!(prev_cwd)
        end

      # No side effects, no spurious "would be created", and the
      # predicted skip count comes from the absolute-path lookup.
      assert workspaces_count() == ws_count_before
      assert memory_facts_count() == facts_count_before

      refute log =~ "would be created",
             "dry-run failed to find the workspace it would have created via the absolute path; relative-vs-absolute path mismatch"

      assert log =~ ~r/facts would insert: 0/
      assert log =~ ~r/facts would skip \(already present\): 3/

      # The "Migrating .jido/memory.json from …" line should report
      # the absolute, expanded path — operators expect a concrete
      # location.
      assert log =~ "Migrating .jido/memory.json from #{project_dir}"
    end
  end

  # Resolve any platform-level symlinks in `path` by cd'ing into it
  # and reading back `File.cwd!/0`. Used by the relative-path dry-run
  # test on macOS, where `System.tmp_dir!()` returns a `/var/...` form
  # that canonicalizes to `/private/var/...` after `File.cd!/1`.
  defp canonicalize(path) do
    prev = File.cwd!()
    File.cd!(path)
    canon = File.cwd!()
    File.cd!(prev)
    canon
  end

  defp workspaces_count do
    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Repo.query("SELECT COUNT(*) FROM workspaces", [])

    count
  end

  defp memory_facts_count do
    {:ok, %Postgrex.Result{rows: [[count]]}} =
      Repo.query("SELECT COUNT(*) FROM memory_facts", [])

    count
  end
end
