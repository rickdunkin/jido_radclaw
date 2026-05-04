defmodule Mix.Tasks.Jidoclaw.Export.Conversations do
  @moduledoc """
  Round-trip exporter for `Conversations.Message` rows.

  Replays a session's persisted history back into the legacy
  `.jido/sessions/<tenant>/<external_id>.jsonl.exported` shape so
  v0.5.x tools (and the §2.7 round-trip acceptance fixture) can
  consume v0.6 data.

  ## Usage

      mix jidoclaw.export.conversations \\
        --tenant TENANT \\
        [--workspace DIR] \\
        [--kind KIND] \\
        [--session EXTERNAL_ID | --session-uuid UUID] \\
        [--out PATH] \\
        [--with-redaction-manifest]

  When `--session-uuid` is given the resolution path is skipped and
  the export reads `Conversations.Message.for_session/1` directly.
  Otherwise the task does a **read-only** lookup:

    * `--workspace DIR` (default cwd) → `Workspaces.Resolver.ensure_workspace`
      (idempotent — workspace ensure is fine to perform).
    * `--kind` (required when `--session` is given) →
      `Conversations.Session.by_external/4`. Read action — does NOT
      create the row. If the session doesn't exist the task exits
      with a clear error rather than silently inserting an empty row.

  ## Sidecars

  Two sidecar files are emitted alongside the main JSONL:

    * `<file>.export-manifest.json` — lists rows dropped from the main
      output by `(sequence, role)`. Includes every `:tool_call`,
      `:tool_result`, `:reasoning` row in the session.
    * `<file>.redaction-manifest.json` (`--with-redaction-manifest`) —
      lists `:user`/`:assistant` rows whose content contains the
      literal string `"[REDACTED"`, with `(sequence, position,
      pattern_category)` triples.
  """

  @shortdoc "Export Postgres-backed conversations to legacy JSONL"

  use Mix.Task

  alias JidoClaw.Conversations.{Message, Session}
  alias JidoClaw.Workspaces.Resolver, as: WorkspaceResolver

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          tenant: :string,
          workspace: :string,
          kind: :string,
          session: :string,
          session_uuid: :string,
          out: :string,
          with_redaction_manifest: :boolean
        ]
      )

    Mix.Task.run("app.start")

    with {:ok, session, output_path} <- resolve_session(opts) do
      do_export(session, output_path, opts)
    end
  end

  defp resolve_session(opts) do
    case Keyword.get(opts, :session_uuid) do
      uuid when is_binary(uuid) ->
        case Ash.get(Session, uuid, domain: JidoClaw.Conversations) do
          {:ok, session} ->
            output_path = output_path(opts, session)
            {:ok, session, output_path}

          _ ->
            Mix.shell().error("session UUID not found: #{uuid}")
            :error
        end

      _ ->
        resolve_session_by_external(opts)
    end
  end

  defp resolve_session_by_external(opts) do
    tenant = Keyword.get(opts, :tenant) || raise "missing --tenant"
    external = Keyword.get(opts, :session) || raise "missing --session or --session-uuid"
    kind_str = Keyword.get(opts, :kind) || raise "missing --kind (required with --session)"
    kind = String.to_existing_atom(kind_str)
    workspace_dir = Keyword.get(opts, :workspace) || File.cwd!()

    with {:ok, workspace} <- WorkspaceResolver.ensure_workspace(tenant, workspace_dir),
         {:ok, session} <- Session.by_external(tenant, workspace.id, kind, external) do
      output_path = output_path(opts, session)
      {:ok, session, output_path}
    else
      {:error, reason} ->
        Mix.shell().error("session not found: #{inspect(reason)}")
        :error
    end
  end

  defp output_path(opts, session) do
    case Keyword.get(opts, :out) do
      path when is_binary(path) ->
        path

      _ ->
        Path.join([
          File.cwd!(),
          ".jido",
          "sessions",
          session.tenant_id,
          "#{session.external_id}.jsonl.exported"
        ])
    end
  end

  defp do_export(session, output_path, opts) do
    case Message.for_session(session.id) do
      {:ok, rows} ->
        File.mkdir_p!(Path.dirname(output_path))
        write_jsonl(output_path, rows)
        write_manifest(output_path, rows)

        if Keyword.get(opts, :with_redaction_manifest, false) do
          write_redaction_manifest(output_path, rows)
        end

        Mix.shell().info(
          "Exported #{length(rows)} rows (#{user_assistant_count(rows)} user/assistant) to #{output_path}"
        )

        :ok

      {:error, reason} ->
        Mix.shell().error("read failed: #{inspect(reason)}")
        :error
    end
  end

  defp write_jsonl(path, rows) do
    rows
    |> Enum.filter(&(&1.role in [:user, :assistant]))
    |> Enum.map(fn row ->
      Jason.encode!(%{
        role: Atom.to_string(row.role),
        content: row.content,
        timestamp: DateTime.to_unix(row.inserted_at, :millisecond)
      })
    end)
    |> Enum.intersperse("\n")
    |> Kernel.++(["\n"])
    |> then(&File.write!(path, &1))
  end

  defp write_manifest(path, rows) do
    dropped =
      rows
      |> Enum.filter(&(&1.role in [:tool_call, :tool_result, :reasoning, :system]))
      |> Enum.map(fn row -> %{sequence: row.sequence, role: Atom.to_string(row.role)} end)

    manifest = %{
      total_rows: length(rows),
      exported_user_assistant: user_assistant_count(rows),
      dropped: dropped
    }

    File.write!(path <> ".export-manifest.json", Jason.encode!(manifest, pretty: true))
  end

  defp write_redaction_manifest(path, rows) do
    redactions =
      rows
      |> Enum.filter(&(&1.role in [:user, :assistant]))
      |> Enum.flat_map(fn row -> redactions_in(row) end)

    File.write!(
      path <> ".redaction-manifest.json",
      Jason.encode!(%{redactions: redactions}, pretty: true)
    )
  end

  defp redactions_in(%{content: nil}), do: []

  defp redactions_in(%{content: content, sequence: seq}) when is_binary(content) do
    Regex.scan(~r/\[REDACTED([^\]]*)\]/, content, return: :index)
    |> Enum.map(fn [{pos, _}, {_, _}] ->
      %{
        sequence: seq,
        position: pos,
        # Extract the pattern category if present, e.g. "[REDACTED:openai_key]"
        pattern_category: extract_category(content, pos)
      }
    end)
  end

  defp redactions_in(_), do: []

  defp extract_category(content, pos) do
    # The redactor uses placeholders like "[REDACTED]" or "[REDACTED:type]";
    # extract anything after the colon when present.
    chunk = String.slice(content, pos, 80)

    case Regex.run(~r/\[REDACTED:(\w+)\]/, chunk) do
      [_, cat] -> cat
      _ -> "generic"
    end
  end

  defp user_assistant_count(rows) do
    Enum.count(rows, &(&1.role in [:user, :assistant]))
  end
end
