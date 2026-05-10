defmodule Mix.Tasks.Jidoclaw.ConversationsExportTest do
  use ExUnit.Case, async: false

  import JidoClaw.ExportTestHelper

  alias JidoClaw.Conversations.Session
  alias JidoClaw.Workspaces.Resolver, as: WorkspaceResolver

  @fixtures Path.expand("../../fixtures/exports/conversations", __DIR__)

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "round-trip via migrate.conversations + export.conversations" do
    test "export of sanitized fixture is byte-deterministic across re-runs" do
      tenant_id = "export-test-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("convo-sanitized")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)
      rename_session_tenant(project_dir, "__tenant__", tenant_id)

      out_a =
        Path.join([project_dir, ".jido", "sessions", tenant_id, "api_sample.jsonl.exported"])

      out_b = Path.join([project_dir, "convo-export-2.jsonl.exported"])

      reenable!("jidoclaw.migrate.conversations")
      Mix.Task.run("jidoclaw.migrate.conversations", ["--project", project_dir])

      reenable!("jidoclaw.export.conversations")

      Mix.Task.run("jidoclaw.export.conversations", [
        "--tenant",
        tenant_id,
        "--workspace",
        project_dir,
        "--kind",
        "api",
        "--session",
        "sample",
        "--out",
        out_a
      ])

      assert File.exists?(out_a)
      bytes_a = File.read!(out_a)

      reenable!("jidoclaw.migrate.conversations")
      Mix.Task.run("jidoclaw.migrate.conversations", ["--project", project_dir])

      reenable!("jidoclaw.export.conversations")

      Mix.Task.run("jidoclaw.export.conversations", [
        "--tenant",
        tenant_id,
        "--workspace",
        project_dir,
        "--kind",
        "api",
        "--session",
        "sample",
        "--out",
        out_b
      ])

      bytes_b = File.read!(out_b)

      assert bytes_a == bytes_b,
             "conversations export is not byte-deterministic across re-runs"
    end

    test "with-redaction-manifest reports redaction sites in user/assistant content" do
      tenant_id = "export-test-secret-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("convo-secrets")
      copy_fixture(Path.join(@fixtures, "with_secrets"), project_dir)
      rename_session_tenant(project_dir, "__tenant__", tenant_id)

      raw_fixture =
        File.read!(Path.join([project_dir, ".jido", "sessions", tenant_id, "api_secret.jsonl"]))

      # The conversations migrate path imports content as-is — no
      # storage-time redaction (unlike Memory/Solutions). The fixture
      # is pre-scrubbed with `[REDACTED…]` markers so the export's
      # redaction-manifest writer has something to scan and report.
      assert raw_fixture =~ "[REDACTED:API_KEY]",
             "fixture must contain a [REDACTED…] marker for the export manifest scanner"

      out_path = Path.join([project_dir, "convo-export.jsonl.exported"])

      reenable!("jidoclaw.migrate.conversations")
      Mix.Task.run("jidoclaw.migrate.conversations", ["--project", project_dir])

      reenable!("jidoclaw.export.conversations")

      Mix.Task.run("jidoclaw.export.conversations", [
        "--tenant",
        tenant_id,
        "--workspace",
        project_dir,
        "--kind",
        "api",
        "--session",
        "secret",
        "--out",
        out_path,
        "--with-redaction-manifest"
      ])

      assert File.exists?(out_path)
      manifest_path = out_path <> ".redaction-manifest.json"
      assert File.exists?(manifest_path)

      manifest = manifest_path |> File.read!() |> Jason.decode!()
      redactions = manifest["redactions"] || []

      # The migrate task redacts user/assistant content at the
      # storage boundary, so the fixture's raw `sk-...` key lands
      # in Postgres as `[REDACTED:API_KEY]`. The export's redaction
      # manifest scans for `[REDACTED…]` markers and reports their
      # positions; we expect at least one site.
      assert length(redactions) > 0,
             "expected at least one redaction site in the with-secrets fixture's export"

      # Each manifest entry must point at the start of a `[REDACTED…]`
      # marker in the corresponding row's content. Recover the line
      # for the entry's sequence and verify the reported position.
      lines =
        out_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      # The exported JSONL keeps user/assistant rows in sequence
      # order; rebuild that by mapping sequence -> content via the
      # raw DB sequence ordering. We don't have direct access to
      # `sequence` here without re-reading from Postgres, but the
      # manifest's `position` is computed against the same content
      # the JSONL line carries — so we can match by content prefix.
      Enum.each(redactions, fn r ->
        pos = r["position"]
        assert is_integer(pos)
        # Find the line whose content has a redaction marker at the
        # reported position; at least one must.
        assert Enum.any?(lines, fn line ->
                 content = line["content"] || ""

                 byte_size(content) > pos and
                   String.starts_with?(
                     binary_part(content, pos, byte_size(content) - pos),
                     "[REDACTED"
                   )
               end),
               "no exported line carries a [REDACTED…] marker at position #{pos}"
      end)

      # The export'd JSONL must NOT contain the raw fixture secret.
      Enum.each(lines, fn line ->
        content = line["content"] || ""
        refute content =~ ~r/sk-[A-Za-z0-9]{20,}/
      end)
    end

    test "--session-uuid resolves a tenant-scoped session without --tenant" do
      tenant_id = "export-test-uuid-#{System.unique_integer([:positive])}"
      project_dir = unique_project_dir("convo-uuid")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)
      rename_session_tenant(project_dir, "__tenant__", tenant_id)

      reenable!("jidoclaw.migrate.conversations")
      Mix.Task.run("jidoclaw.migrate.conversations", ["--project", project_dir])

      {:ok, workspace} = WorkspaceResolver.ensure_workspace(tenant_id, project_dir)
      {:ok, session} = Session.by_external(workspace.id, :api, "sample", tenant: tenant_id)

      out_path = Path.join([project_dir, "convo-export-by-uuid.jsonl.exported"])

      reenable!("jidoclaw.export.conversations")

      Mix.Task.run("jidoclaw.export.conversations", [
        "--session-uuid",
        session.id,
        "--out",
        out_path
      ])

      assert File.exists?(out_path)
    end
  end
end
