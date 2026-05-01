defmodule Mix.Tasks.Jidoclaw.Export.Solutions do
  @moduledoc """
  Round-trip export task — emits the legacy `.jido/solutions.json`
  shape from the v0.6.1 Postgres-backed Solutions corpus.

  Used by:

    * The §1.8 round-trip sanitized fixture: load → migrate → export
      should yield byte-equivalent output (modulo redaction).
    * Operators who want to back up a workspace's solutions in the
      legacy format.

  ## Usage

      mix jidoclaw.export.solutions [--project DIR] [--out PATH]
                                    [--manifest PATH]

  Default `DIR` is the current working directory; default `PATH` is
  `DIR/.jido/solutions.json.exported`.

  When `--manifest PATH` is given, also writes a sidecar JSON file
  listing redaction sites — `[{position, pattern_category, original_len}]`
  for each scrubbed substring. The §1.8 redaction-delta fixture
  reads the manifest to assert `[REDACTED:*]` lands at exactly the
  manifest positions.
  """

  @shortdoc "Export Solutions corpus to legacy .jido/solutions.json shape"

  use Mix.Task

  alias JidoClaw.Repo
  alias JidoClaw.Workspaces.Resolver

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [project: :string, out: :string, manifest: :string]
      )

    project_dir = Keyword.get(opts, :project) || File.cwd!()

    out_path =
      Keyword.get(opts, :out) || Path.join([project_dir, ".jido", "solutions.json.exported"])

    manifest_path = Keyword.get(opts, :manifest)

    Mix.Task.run("app.start")

    {:ok, workspace} = Resolver.ensure_workspace("default", project_dir)

    rows = fetch_solutions(workspace)
    Mix.shell().info("Exporting #{length(rows)} solutions to #{out_path}")

    payload =
      rows
      |> Enum.map(fn row ->
        {row[:id], to_legacy_shape(row)}
      end)
      |> Enum.into(%{})

    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, Jason.encode!(payload, pretty: true))

    if manifest_path do
      manifest = Enum.map(rows, &redaction_manifest/1)
      File.mkdir_p!(Path.dirname(manifest_path))
      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
      Mix.shell().info("Manifest written to #{manifest_path}")
    end

    :ok
  end

  defp fetch_solutions(workspace) do
    {:ok, %Postgrex.Result{columns: cols, rows: rows}} =
      Repo.query(
        """
        SELECT id, problem_signature, solution_content, language, framework, runtime,
               agent_id, tags, verification, trust_score, sharing,
               inserted_at, updated_at, deleted_at
          FROM solutions
         WHERE workspace_id = $1 AND tenant_id = $2 AND deleted_at IS NULL
         ORDER BY inserted_at ASC
        """,
        [Ecto.UUID.dump!(workspace.id), workspace.tenant_id]
      )

    Enum.map(rows, fn row ->
      cols
      |> Enum.zip(row)
      |> Enum.into(%{})
      |> Map.new(fn
        {"id", v} when is_binary(v) ->
          {:id, format_id(v)}

        {k, v} ->
          {String.to_atom(k), v}
      end)
    end)
  end

  defp format_id(<<a::binary-size(16)>>) do
    Ecto.UUID.cast!(a)
  end

  defp format_id(other), do: other

  defp to_legacy_shape(row) do
    %{
      "id" => row[:id],
      "problem_signature" => row[:problem_signature],
      "solution_content" => row[:solution_content],
      "language" => row[:language],
      "framework" => row[:framework],
      "runtime" => row[:runtime],
      "agent_id" => row[:agent_id],
      "tags" => row[:tags] || [],
      "verification" => row[:verification] || %{},
      "trust_score" => row[:trust_score] || 0.0,
      "sharing" => to_string(row[:sharing] || "local"),
      "inserted_at" => format_dt(row[:inserted_at]),
      "updated_at" => format_dt(row[:updated_at])
    }
  end

  defp format_dt(nil), do: nil

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_dt(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp format_dt(other) when is_binary(other), do: other
  defp format_dt(_), do: nil

  defp redaction_manifest(row) do
    content = row[:solution_content] || ""

    matches =
      ~w([REDACTED:ANTHROPIC_KEY] [REDACTED:API_KEY] [REDACTED:JIDOCLAW_KEY] [REDACTED:GITHUB_PAT] [REDACTED] [REDACTED:JWT] [REDACTED:AWS_KEY] [REDACTED:SECRET])
      |> Enum.flat_map(fn label ->
        find_all(content, label, 0, [])
      end)

    %{
      "id" => row[:id],
      "redactions" =>
        Enum.map(matches, fn {pos, label} -> %{"position" => pos, "label" => label} end)
    }
  end

  defp find_all(text, label, start, acc) do
    case :binary.match(text, label, scope: {start, byte_size(text) - start}) do
      :nomatch ->
        Enum.reverse(acc)

      {pos, len} ->
        find_all(text, label, pos + len, [{pos, label} | acc])
    end
  end
end
