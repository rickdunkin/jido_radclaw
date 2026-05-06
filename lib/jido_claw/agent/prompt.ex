defmodule JidoClaw.Agent.Prompt do
  @moduledoc """
  Builds the system prompt for the JIDOCLAW AI coding agent.

  The base prompt lives in `.jido/system_prompt.md` (user-editable). If the file
  doesn't exist, it's created from the bundled default on first boot. Dynamic
  sections (environment, memories, JIDO.md) are appended at runtime.

  ## Auto-sync

  When the bundled default changes, `sync/1` either overwrites the user file
  (when the user hadn't modified it) or offers the new default via the
  `.jido/system_prompt.md.default` sidecar so the user can review and opt in
  via `/upgrade-prompt`. The stamp tracking what the user has acknowledged
  lives in `.jido/.system_prompt.sync` so it never pollutes the prompt that
  gets sent to the LLM.
  """

  require Logger

  # Embed the default system prompt at compile time so the escript/binary is self-contained
  @priv_prompt Path.join([__DIR__, "..", "..", "..", "priv", "defaults", "system_prompt.md"])
  @external_resource @priv_prompt
  @default_system_prompt File.read!(@priv_prompt)
  @default_system_prompt_sha :crypto.hash(:sha256, @default_system_prompt)
                             |> Base.encode16(case: :lower)

  @sync_filename ".system_prompt.sync"
  @default_marker_filename "system_prompt.md.default"

  # ---------------------------------------------------------------------------
  # System prompt file management
  # ---------------------------------------------------------------------------

  @doc """
  Ensure `.jido/system_prompt.md` exists. Writes the default if missing.
  Does NOT overwrite an existing file — user customizations are preserved.

  When creating the file for the first time, also writes the sync stamp so
  `sync/1` recognizes the fresh install as on the latest default.
  """
  @spec ensure(String.t()) :: :ok
  def ensure(project_dir) do
    path = system_prompt_path(project_dir)
    dir = Path.dirname(path)

    unless File.exists?(path) do
      File.mkdir_p!(dir)
      File.write!(path, @default_system_prompt)

      write_sync(
        sync_stamp_path(project_dir),
        @default_system_prompt_sha,
        @default_system_prompt_sha
      )
    end

    :ok
  end

  @doc "Returns the path to the system prompt file for a project."
  def system_prompt_path(project_dir) do
    Path.join([project_dir, ".jido", "system_prompt.md"])
  end

  @doc "Returns the SHA-256 of the bundled default system prompt."
  @spec current_default_sha() :: String.t()
  def current_default_sha, do: @default_system_prompt_sha

  @doc """
  Reconcile the on-disk `.jido/system_prompt.md` with the bundled default.

  Return values:
    * `{:ok, :noop}` — nothing to do (current, or sidecar already offered).
    * `{:ok, :overwritten}` — body was unmodified against an older default and has
      been replaced with the latest bundled default.
    * `{:ok, :stamp_only}` — user has edits and is already on the latest default;
      the sync stamp was refreshed with the new body SHA.
    * `{:ok, :sidecar_written}` — user has edits and the bundled default has moved
      since last acknowledged; the new default was written to
      `.jido/system_prompt.md.default` for review.
    * `{:error, reason}` — unexpected IO failure.
  """
  @spec sync(String.t()) ::
          {:ok, :noop | :overwritten | :sidecar_written | :stamp_only} | {:error, term()}
  def sync(project_dir) do
    __sync_with__(project_dir, @default_system_prompt, @default_system_prompt_sha)
  end

  @doc false
  # Injectable entry point so tests can simulate a changed bundled default
  # without recompiling the module.
  @spec __sync_with__(String.t(), binary(), String.t()) ::
          {:ok, :noop | :overwritten | :sidecar_written | :stamp_only} | {:error, term()}
  def __sync_with__(project_dir, default_bytes, default_sha) do
    sys_path = system_prompt_path(project_dir)
    stamp_path = sync_stamp_path(project_dir)
    default_sidecar = default_sidecar_path(project_dir)

    case File.read(sys_path) do
      {:ok, body} ->
        body_sha = sha(body)
        sidecar = load_sync(stamp_path)
        default_sidecar_matches? = default_sidecar_matches?(default_sidecar, default_sha)

        dispatch_sync(%{
          project_dir: project_dir,
          sys_path: sys_path,
          stamp_path: stamp_path,
          default_sidecar_path: default_sidecar,
          default_bytes: default_bytes,
          default_sha: default_sha,
          body_sha: body_sha,
          sidecar: sidecar,
          default_sidecar_matches?: default_sidecar_matches?
        })

      {:error, :enoent} ->
        {:ok, :noop}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in File.Error -> {:error, e}
  end

  @doc """
  Promote `.jido/system_prompt.md.default` into place.

  Backs up the existing `.jido/system_prompt.md` to `.system_prompt.md.bak`,
  renames the sidecar into place, and refreshes the sync stamp.

  Returns `{:error, :no_sidecar}` when no `.default` sidecar exists.
  """
  @spec upgrade(String.t()) ::
          {:ok, %{from: String.t(), to: String.t(), backup: String.t()}}
          | {:error, :no_sidecar | term()}
  def upgrade(project_dir) do
    sys_path = system_prompt_path(project_dir)
    default_sidecar = default_sidecar_path(project_dir)
    stamp_path = sync_stamp_path(project_dir)

    with true <- File.exists?(default_sidecar) || {:error, :no_sidecar},
         backup_path = sys_path <> ".bak",
         :ok <- maybe_rename(sys_path, backup_path),
         :ok <- File.rename(default_sidecar, sys_path),
         {:ok, new_body} <- File.read(sys_path),
         :ok <- write_sync(stamp_path, sha(new_body), sha(new_body)) do
      {:ok, %{from: default_sidecar, to: sys_path, backup: backup_path}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Sync dispatch — decision table
  # ---------------------------------------------------------------------------

  # Sidecar missing (pre-0.4 user or first install after ensure/1).
  defp dispatch_sync(%{sidecar: nil} = ctx) do
    cond do
      ctx.body_sha == ctx.default_sha ->
        # Fresh install or user sits on the latest bundled default.
        write_sync(ctx.stamp_path, ctx.default_sha, ctx.body_sha)
        {:ok, :noop}

      true ->
        # User has diverged from the bundled default — offer the new one.
        atomic_write(ctx.default_sidecar_path, ctx.default_bytes)
        write_sync(ctx.stamp_path, ctx.default_sha, ctx.body_sha)
        emit_sidecar_signal(ctx.project_dir)
        {:ok, :sidecar_written}
    end
  end

  # Sidecar present — classify the cases using three signals:
  #   * body_unchanged_since_stamp? — user hasn't edited since the last stamp.
  #   * stored_default_current?     — stamp tracks the bundled default we ship today.
  #   * body_matches_stored_default? — the on-disk body actually equals the stamped
  #     default; distinguishes a vanilla install (safe to overwrite) from a user
  #     who stamped their customizations.
  defp dispatch_sync(%{sidecar: %{default_sha: stored_default, body_sha: stored_body}} = ctx) do
    body_unchanged_since_stamp? = ctx.body_sha == stored_body
    stored_default_current? = stored_default == ctx.default_sha
    body_matches_stored_default? = ctx.body_sha == stored_default

    cond do
      stored_default_current? and body_unchanged_since_stamp? ->
        {:ok, :noop}

      not stored_default_current? and body_unchanged_since_stamp? and
          body_matches_stored_default? ->
        atomic_write(ctx.sys_path, ctx.default_bytes)
        write_sync(ctx.stamp_path, ctx.default_sha, ctx.default_sha)
        File.rm(ctx.default_sidecar_path)
        Logger.info("[JidoClaw] Upgraded .jido/system_prompt.md to the latest bundled default")
        {:ok, :overwritten}

      not body_unchanged_since_stamp? and stored_default_current? ->
        write_sync(ctx.stamp_path, ctx.default_sha, ctx.body_sha)
        {:ok, :stamp_only}

      true ->
        if ctx.default_sidecar_matches? do
          {:ok, :noop}
        else
          atomic_write(ctx.default_sidecar_path, ctx.default_bytes)
          emit_sidecar_signal(ctx.project_dir)
          {:ok, :sidecar_written}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic section builders
  # ---------------------------------------------------------------------------

  # Snapshot variant — skips fields that change between turns/sessions
  # (active agent count, current git branch) so the prompt cache stays
  # warm across the whole session lifetime.
  defp environment_section_snapshot(cwd, project_type, skills) do
    skills_list =
      case skills do
        [] -> "  None loaded (place YAML files in .jido/skills/)"
        list -> Enum.map_join(list, "\n", fn s -> "  - #{s.name}: #{s.description}" end)
      end

    """
    ## Environment

    - Working directory: #{cwd}
    - Project type:      #{project_type}

    ### Loaded Skills
    #{skills_list}
    """
  end

  defp blocks_section([]), do: ""

  defp blocks_section(blocks) do
    entries =
      Enum.map_join(blocks, "\n\n", fn block ->
        header =
          case block.description do
            nil -> "### #{block.label}"
            "" -> "### #{block.label}"
            desc -> "### #{block.label} — #{desc}"
          end

        header <> "\n" <> block.value
      end)

    """

    ## Memory Blocks (curated context)
    #{entries}
    """
  end

  defp jido_md_section(nil), do: ""

  defp jido_md_section(content) do
    """

    ## Project Instructions (from JIDO.md)
    #{content}
    """
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build the full system prompt for the JIDOCLAW agent.

  Reads the base prompt from `.jido/system_prompt.md` (or falls back to the
  compiled default), then appends dynamic sections: environment, memories,
  and JIDO.md content. Called once per session start.

  This is a thin wrapper over `build_snapshot/2` with no scope —
  callers without a resolved scope (e.g. early-boot tests) skip the
  Block-tier render but still get the rest of the dynamic prompt.
  """
  @spec build(String.t()) :: String.t()
  def build(project_dir), do: build_snapshot(project_dir, nil)

  @doc """
  Build a frozen snapshot of the system prompt.

  Drops fields that change between turns or sessions (active-agent
  count, current git branch) so the prompt cache stays warm across
  the entire session lifetime. The Block tier is rendered for the
  supplied scope when one is provided; a `nil` scope renders no
  Block tier.

  Persisted onto `Conversations.Session.metadata["prompt_snapshot"]`
  by the resolver at session-create time and injected verbatim on
  every turn for that session.
  """
  @spec build_snapshot(String.t(), JidoClaw.Memory.Scope.scope_record() | nil) :: String.t()
  def build_snapshot(project_dir, scope) do
    base_prompt = load_base_prompt(project_dir)

    cwd = project_dir
    project_type = detect_type(cwd)
    skills = load_skills(cwd)
    blocks = render_block_tier(scope)
    jido_md = load_jido_md(cwd)

    base_prompt <>
      "\n" <>
      environment_section_snapshot(cwd, project_type, skills) <>
      blocks_section(blocks) <>
      jido_md_section(jido_md)
  end

  defp render_block_tier(nil), do: []

  defp render_block_tier(scope) do
    JidoClaw.Memory.list_blocks_for_scope_chain(scope)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ---------------------------------------------------------------------------
  # Private helpers — sync sidecar IO
  # ---------------------------------------------------------------------------

  defp sync_stamp_path(project_dir) do
    Path.join([project_dir, ".jido", @sync_filename])
  end

  defp default_sidecar_path(project_dir) do
    Path.join([project_dir, ".jido", @default_marker_filename])
  end

  defp sha(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp load_sync(path) do
    case File.read(path) do
      {:ok, content} -> parse_sync(content)
      {:error, _} -> nil
    end
  end

  defp parse_sync(content) do
    map =
      content
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        trimmed = String.trim(line)

        case String.split(trimmed, ":", parts: 2) do
          [key, value] ->
            k = String.trim(key)
            v = String.trim(value)

            cond do
              String.starts_with?(k, "#") -> acc
              k == "default_sha" and v != "" -> Map.put(acc, :default_sha, v)
              k == "body_sha" and v != "" -> Map.put(acc, :body_sha, v)
              true -> acc
            end

          _ ->
            acc
        end
      end)

    if Map.has_key?(map, :default_sha) and Map.has_key?(map, :body_sha), do: map, else: nil
  end

  defp write_sync(path, default_sha, body_sha) do
    content = """
    # Managed by JidoClaw. Do not edit.
    default_sha: #{default_sha}
    body_sha: #{body_sha}
    """

    atomic_write(path, content)
  end

  defp default_sidecar_matches?(path, default_sha) do
    case File.read(path) do
      {:ok, content} -> sha(content) == default_sha
      {:error, _} -> false
    end
  end

  defp atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    temp = path <> ".tmp.#{System.unique_integer([:positive])}"
    File.write!(temp, content)
    File.rename!(temp, path)
    :ok
  end

  defp maybe_rename(src, dest) do
    if File.exists?(src) do
      File.rename(src, dest)
    else
      :ok
    end
  end

  defp emit_sidecar_signal(project_dir) do
    try do
      JidoClaw.SignalBus.emit("jido_claw.agent.prompt_sidecar_available", %{
        project_dir: project_dir
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — prompt building
  # ---------------------------------------------------------------------------

  defp load_base_prompt(project_dir) do
    path = system_prompt_path(project_dir)

    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> @default_system_prompt
    end
  end

  defp load_skills(_project_dir) do
    JidoClaw.Skills.all()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_jido_md(cwd) do
    path = Path.join([cwd, ".jido", "JIDO.md"])

    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp detect_type(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "Elixir/OTP"
      File.exists?(Path.join(dir, "package.json")) -> "JavaScript/TypeScript"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "Rust"
      File.exists?(Path.join(dir, "go.mod")) -> "Go"
      File.exists?(Path.join(dir, "pyproject.toml")) -> "Python"
      true -> "Unknown"
    end
  end
end
