defmodule JidoClaw.Orchestration.Verify.Evidence.Assertions do
  @moduledoc """
  Slice 2 of the evidence floor (OB1-3): verify extracted spec assertions
  against the actual project tree — bounded regex scans, no LLM. Port of
  ouroboros's `SpecVerifier` — semantics map
  `docs/exploration/ouroboros/PORT-OB1-3.md` (`Q00/ouroboros @ e905a41c`,
  MIT, © 2025 Q00).

  The conservative-override rule, verbatim (verifier.py:101-134): T1/T2
  assertions verify by bounded scan; T3/T4 are skipped; **every**
  can't-verify branch — no file hint, no matching files, invalid or
  over-long regex, a timed-out scan — returns `verified: true` (trust the
  agent). The ONLY false branch is a compiled pattern absent across scanned
  files that existed (`:contradicted`). Deliberate residual: a matched file
  that is unreadable or over the size cap still counts as scanned — its
  read contributes no match, so if nothing else matches the assertion
  contradicts. Source-faithful (verifier.py skips the read but keeps the
  file in the scanned count); pinned in the evidence-floor residuals
  (`docs/system/evidence-floor.md`).

  Ported bounds (verifier.py:25-27): #{50 * 1024} bytes/file, 100
  files/hint, 200-char pattern. House deltas (PORT map): the noise-dir set
  is Elixir's (`_build`, `deps`, `.git`, `node_modules`), a hint-less
  assertion is trusted rather than scanning a default glob (bounded fold
  cost), and each assertion's scan runs under a bounded `Task` timeout
  (sign-off decision 8 — ReDoS belt-and-suspenders over the length cap).
  Traversal hints (`..`) and paths escaping the realpath'd project root are
  filtered — can't verify ⇒ trust, never a scan outside the tree.

  T2 additionally accepts a case-insensitive basename match before content
  search (verifier.py:186-199) — "the file exists" is structural support.

  Pure over the injected `:scanner` seam (find + read); the default scanner
  is the real filesystem.
  """

  @max_file_size 50 * 1024
  @max_files_per_hint 100
  @max_pattern_length 200
  @scan_timeout_ms 2_000
  @noise_dirs ["_build", "deps", ".git", "node_modules"]

  @type result :: %{
          ac_id: String.t(),
          assertion: String.t(),
          tier: String.t(),
          verified: boolean(),
          reason: String.t(),
          file_hint: String.t() | nil
        }

  defmodule Scanner do
    @moduledoc """
    The default filesystem scanner behind `Assertions.verify/3`'s `:scanner`
    seam: bounded glob under the project root (traversal-filtered, noise
    dirs excluded upstream) + size-capped reads. A `find/2` fault reads as
    "no files" — toward trust; a `read/2` fault or over-cap file reads as
    nil — that file contributes no match, which leans toward contradiction
    when nothing else matches (the pinned scanned-still-counts residual).
    """

    @doc "Regular files matching `hint` under `project_dir` (unbounded; the caller caps)."
    @spec find(String.t(), String.t()) :: [String.t()]
    def find(project_dir, hint) do
      project_dir
      |> Path.join(hint)
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
    rescue
      # A malformed glob must read as "no files" (trust), never raise into
      # the fold.
      # reach:disable-next-line bare_rescue
      _ -> []
    end

    @doc "The file's content, or nil when unreadable or over `max_bytes`."
    @spec read(String.t(), pos_integer()) :: String.t() | nil
    def read(path, max_bytes) do
      with {:ok, %File.Stat{size: size}} when size <= max_bytes <- File.stat(path),
           {:ok, content} <- File.read(path) do
        content
      else
        _over_or_error -> nil
      end
    end
  end

  @doc """
  Verify every assertion against the project tree. Total and never raises:
  a nil/blank `project_dir` skips everything (`verified: true`), and each
  assertion's scan is independently bounded by `opts[:timeout_ms]` (default
  #{@scan_timeout_ms}ms). `opts[:scanner]` injects the filesystem seam.
  """
  @spec verify([map()], String.t() | nil, keyword()) :: [result()]
  def verify(assertions, project_dir, opts \\ [])

  def verify(assertions, project_dir, opts) when is_list(assertions) do
    Enum.map(assertions, &verify_assertion(&1, project_dir, opts))
  end

  def verify(_assertions, _project_dir, _opts), do: []

  defp verify_assertion(assertion, project_dir, opts) do
    record = base_record(assertion)

    cond do
      record.tier in ["T3_BEHAVIORAL", "T4_UNVERIFIABLE"] ->
        %{record | reason: "tier not machine-verifiable (skipped)"}

      not is_binary(project_dir) or String.trim(project_dir) == "" ->
        %{record | reason: "no project directory (cannot verify)"}

      pattern_of(assertion) == nil ->
        %{record | reason: "no pattern to verify"}

      true ->
        scan_bounded(record, assertion, project_dir, opts)
    end
  end

  # Decision 8: the regex length cap is the first ReDoS guard; the bounded
  # Task is the second — a pathological pattern or a huge tree can burn at
  # most the timeout, and a timed-out scan reads as trust. The scan fun
  # rescues internally, so the task cannot die abnormally; `Task.shutdown`
  # reaps the timeout kill.
  defp scan_bounded(record, assertion, project_dir, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @scan_timeout_ms)
    task = Task.async(fn -> scan(record, assertion, project_dir, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> %{record | reason: "scan timed out (cannot verify)"}
    end
  end

  defp scan(record, assertion, project_dir, opts) do
    files = find_files(assertion, project_dir, opts)
    pattern = compile(pattern_of(assertion))

    cond do
      files == [] ->
        %{record | reason: "no files matched hint (cannot verify)"}

      pattern == nil ->
        %{record | reason: "invalid or too-long regex pattern (cannot verify)"}

      true ->
        match_files(record, pattern, files, opts)
    end
  rescue
    # The floor is advisory: any scan fault reads as trust, never a raise
    # out of the task.
    # reach:disable-next-line bare_rescue
    _ -> %{record | reason: "scan failed (cannot verify)"}
  end

  defp match_files(record, pattern, files, opts) do
    cond do
      record.tier == "T2_STRUCTURAL" and basename_match?(pattern, files) ->
        %{record | reason: "matching file exists"}

      Enum.any?(files, &content_match?(pattern, &1, opts)) ->
        %{record | reason: "pattern found in scanned files"}

      true ->
        %{
          record
          | verified: false,
            reason: "contradicted: pattern absent across #{length(files)} scanned files"
        }
    end
  end

  # T2's first check (verifier.py:186-199): the pattern naming a file that
  # exists is structural support, case-insensitive.
  defp basename_match?(pattern, files) do
    case Regex.compile(pattern.source, "i") do
      {:ok, insensitive} -> Enum.any?(files, &Regex.match?(insensitive, Path.basename(&1)))
      {:error, _reason} -> false
    end
  end

  defp content_match?(pattern, path, opts) do
    case scanner(opts).read(path, @max_file_size) do
      content when is_binary(content) -> Regex.match?(pattern, content)
      _unreadable -> false
    end
  end

  # Bounded glob: traversal hints reject up front; matched paths must
  # realpath-resolve under the project root; noise dirs drop; first
  # #{@max_files_per_hint} survive.
  defp find_files(assertion, project_dir, opts) do
    hint = file_hint_of(assertion)

    if hint == nil or ".." in Path.split(hint) do
      []
    else
      root = Path.expand(project_dir)
      found = scanner(opts).find(project_dir, hint)

      found
      |> Enum.filter(&(contained?(&1, root) and not noise?(&1, root)))
      |> Enum.take(@max_files_per_hint)
    end
  end

  # Containment (verifier.py:242-248's realpath check, house form): the
  # expanded path must live under the project root, and a symlink entry is
  # dropped outright (a link escaping the tree must not be read; dropping
  # ⇒ trust). Residual: a symlinked INTERMEDIATE dir inside the repo is not
  # chased — accepted, documented in the PORT map.
  defp contained?(path, root) do
    String.starts_with?(Path.expand(path), root <> "/") and not symlink?(path)
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp noise?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @noise_dirs))
  end

  defp compile(pattern) when is_binary(pattern) and byte_size(pattern) <= @max_pattern_length do
    case Regex.compile(pattern) do
      {:ok, compiled} -> compiled
      {:error, _reason} -> nil
    end
  end

  defp compile(_pattern), do: nil

  defp base_record(assertion) do
    # Wire-shaped per-assertion verification record (fold → Trace +
    # findings); a struct would ripple the JSONB-restored assertion boundary.
    # reach:disable-next-line fixed_shape_map
    %{
      ac_id: string_field(assertion, "ac_id") || "AC?",
      assertion: string_field(assertion, "assertion") || "",
      tier: string_field(assertion, "tier") || "T4_UNVERIFIABLE",
      verified: true,
      reason: "",
      file_hint: file_hint_of(assertion)
    }
  end

  defp pattern_of(assertion), do: string_field(assertion, "pattern")
  defp file_hint_of(assertion), do: string_field(assertion, "file_hint")

  # Assertions arrive string-keyed (the extractor's wire form / JSONB
  # round-trip); atom keys tolerated for hand-built test input.
  defp string_field(map, key) when is_map(map) do
    value =
      case Map.get(map, key) do
        nil -> Map.get(map, atom_key(key))
        found -> found
      end

    case value do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp string_field(_map, _key), do: nil

  # Fixed table — never `String.to_atom/1` on wire input.
  @atom_keys %{
    "ac_id" => :ac_id,
    "assertion" => :assertion,
    "tier" => :tier,
    "pattern" => :pattern,
    "file_hint" => :file_hint
  }

  defp atom_key(key), do: Map.fetch!(@atom_keys, key)

  defp scanner(opts), do: Keyword.get(opts, :scanner, Scanner)
end
