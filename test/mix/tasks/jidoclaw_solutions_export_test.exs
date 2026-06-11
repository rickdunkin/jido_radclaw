defmodule Mix.Tasks.Jidoclaw.SolutionsExportTest do
  use ExUnit.Case, async: false

  import JidoClaw.ExportTestHelper

  alias Ecto.Adapters.SQL.Sandbox
  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Solutions.Solution
  alias JidoClaw.Workspaces.Resolver

  @fixtures Path.expand("../../fixtures/exports/solutions", __DIR__)

  setup do
    pid = Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  describe "round-trip via Solution.import_legacy + export.solutions" do
    test "export of sanitized fixture is byte-deterministic across re-runs" do
      project_dir = unique_project_dir("solutions-sanitized")
      copy_fixture(Path.join(@fixtures, "sanitized"), project_dir)

      out_a = Path.join([project_dir, "solutions-export-1.json"])
      out_b = Path.join([project_dir, "solutions-export-2.json"])

      seed_solutions_from_fixture(project_dir)

      reenable!("jidoclaw.export.solutions")
      Mix.Task.run("jidoclaw.export.solutions", ["--project", project_dir, "--out", out_a])

      assert File.exists?(out_a)
      bytes_a = File.read!(out_a)

      reenable!("jidoclaw.export.solutions")
      Mix.Task.run("jidoclaw.export.solutions", ["--project", project_dir, "--out", out_b])

      bytes_b = File.read!(out_b)

      assert bytes_a == bytes_b,
             "solutions export is not byte-deterministic across re-runs"
    end

    test "with-redaction-manifest sidecar lists only positions inside [REDACTED:*] markers" do
      project_dir = unique_project_dir("solutions-secrets")
      copy_fixture(Path.join(@fixtures, "with_secrets"), project_dir)

      raw_fixture =
        File.read!(Path.join([project_dir, ".jido", "solutions.json"]))

      assert raw_fixture =~ ~r/sk-[A-Za-z0-9]+/, "fixture must contain a sample API key"
      assert raw_fixture =~ ~r/ghp_[A-Za-z0-9]+/, "fixture must contain a sample GH PAT"

      out_path = Path.join([project_dir, "solutions-export.json"])
      manifest_path = Path.join([project_dir, "solutions-export.manifest.json"])

      seed_solutions_from_fixture(project_dir)

      reenable!("jidoclaw.export.solutions")

      Mix.Task.run("jidoclaw.export.solutions", [
        "--project",
        project_dir,
        "--out",
        out_path,
        "--manifest",
        manifest_path
      ])

      payload =
        out_path
        |> File.read!()
        |> Jason.decode!()

      manifest =
        manifest_path
        |> File.read!()
        |> Jason.decode!()

      assert is_map(payload)
      assert is_list(manifest)

      # Each manifest entry's redactions list must align with
      # `[REDACTED*]` sentinels inside the corresponding solution's
      # post-import content. We don't assert the exact count — just
      # that every reported position genuinely lands on a redaction
      # marker, and that at least one solution has a redaction.
      total_reported =
        Enum.reduce(manifest, 0, fn entry, acc ->
          id = entry["id"]
          redactions = entry["redactions"]
          assert is_list(redactions)

          solution = Map.fetch!(payload, id)
          content = solution["solution_content"] || ""

          Enum.each(redactions, fn r ->
            pos = r["position"]
            label = r["label"]
            assert is_integer(pos)
            assert is_binary(label)

            # The export's manifest writer pulls `pos` from
            # `:binary.match/3` against the same content the export
            # serializes, so the slice at `pos` should start the
            # redaction label.
            chunk = binary_part(content, pos, byte_size(label))
            assert chunk == label
          end)

          acc + length(redactions)
        end)

      assert total_reported > 0,
             "expected at least one redaction across all solutions in the with-secrets fixture"

      # Belt-and-braces: the export'd content has no raw fixture
      # secrets — proves the action-time (`:import_legacy`
      # RedactSolutionContent) redaction fired.
      Enum.each(payload, fn {_id, sol} ->
        content = sol["solution_content"] || ""
        refute content =~ ~r/sk-[A-Za-z0-9]{20,}/
        refute content =~ ~r/ghp_[A-Za-z0-9]{36}/
      end)
    end
  end

  # Seed Postgres from a fixture's `.jido/solutions.json` via the
  # `:import_legacy` action — the seam the deleted v0.5.x migrator wrapped,
  # and where redaction (`RedactSolutionContent`) actually runs. Resolves the
  # same `("default", project_dir)` workspace the export task resolves. Uses
  # `import_legacy!` so a bad seed fails the test loudly.
  defp seed_solutions_from_fixture(project_dir) do
    {:ok, ws} = Resolver.ensure_workspace("default", project_dir)

    [project_dir, ".jido", "solutions.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.values()
    |> Enum.each(fn entry ->
      Solution.import_legacy!(
        %{
          id: Map.fetch!(entry, "id"),
          problem_signature: Map.fetch!(entry, "problem_signature"),
          solution_content: Map.fetch!(entry, "solution_content"),
          language: Map.fetch!(entry, "language"),
          framework: Map.get(entry, "framework"),
          runtime: Map.get(entry, "runtime"),
          agent_id: Map.get(entry, "agent_id"),
          tags: Map.get(entry, "tags", []),
          verification: Map.get(entry, "verification", %{}),
          trust_score: Map.fetch!(entry, "trust_score"),
          sharing: coerce_sharing(Map.fetch!(entry, "sharing")),
          workspace_id: ws.id,
          inserted_at: parse_dt!(Map.fetch!(entry, "inserted_at")),
          updated_at: parse_dt!(Map.fetch!(entry, "updated_at"))
        },
        tenant: ws.tenant_id,
        actor: Actor.system(ws.tenant_id)
      )
    end)

    :ok
  end

  # Whitelist only — an unknown sharing value in a fixture is a fixture
  # bug and should raise, never `String.to_atom/1` its way in.
  defp coerce_sharing("local"), do: :local
  defp coerce_sharing("shared"), do: :shared
  defp coerce_sharing("public"), do: :public

  defp parse_dt!(iso) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end
end
