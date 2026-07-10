defmodule JidoClaw.Orchestration.Verify.Git do
  @moduledoc """
  The single git capture seam for the deterministic verify authority (and, in
  Phase 2, `JidoClaw.Tools.GitCommit`'s engine facts) — single-sourced here so
  the `System.cmd` git idiom is never cloned across the verify/commit surfaces.

  Every capture is nil-on-failure (nonzero exit, missing git, not a repo, a
  raise): callers treat nil as "capture unavailable" and fail toward
  inconclusive, never toward a fabricated value. The tracked-diff capture does
  not merge stderr into the bytes it hashes. Bounded manifest discovery uses
  `Core.OsCmd`; its merged stream must parse as exact NUL-delimited paths or
  the capture fails closed.

  Working-tree digests include nonignored untracked files under explicit
  bounds. Regular files are streamed twice without crossing the byte cap; the
  two full-length hashes must agree under pre/mid/post descriptor and path
  identity fences.
  Symlinks contribute their link text and are never read through. Unsupported
  types, unsafe paths, read races, and crossed bounds make capture unavailable.
  """

  require Logger
  require Record

  alias JidoClaw.Core.FileStat
  alias JidoClaw.Core.OsCmd
  alias JidoClaw.Security.Redaction.Env

  Record.defrecordp(
    :file_info,
    Record.extract(:file_info, from_lib: "kernel/include/file.hrl")
  )

  @max_untracked_files 1_000
  @max_untracked_content_bytes 10 * 1024 * 1024
  @max_path_bytes 4_096
  @read_chunk_bytes 64 * 1024
  @default_capture_timeout_ms 10_000
  @default_capture_concurrency 2
  @capture_supervisor JidoClaw.Orchestration.VerifyCaptureTaskSupervisor

  @path_domain "jido-claw:path-fingerprint:v1\0"
  @tree_domain "jido-claw:working-tree-digest:v2\0"
  @manifest_domain "jido-claw:untracked-manifest:v1\0"

  @typedoc "Bounds accepted by path and working-tree fingerprint capture."
  @type fingerprint_opts :: [
          max_files: non_neg_integer(),
          max_content_bytes: non_neg_integer(),
          max_path_bytes: pos_integer(),
          on_error: :fail | :omit,
          capture_timeout_ms: pos_integer(),
          capture_hook: (String.t(), File.Stat.t() -> any()),
          between_read_hook: (String.t(), map() -> any())
        ]

  @doc "The VM-wide maximum number of verify filesystem captures allowed to run concurrently."
  @spec capture_concurrency() :: pos_integer()
  def capture_concurrency do
    case verify_capture_config()[:max_concurrency] do
      value when is_integer(value) and value > 0 -> min(value, 4)
      _invalid -> @default_capture_concurrency
    end
  end

  @doc "The full sha of `repo`'s current HEAD, or nil when git cannot answer."
  @spec head(String.t()) :: String.t() | nil
  def head(repo) do
    case git(["rev-parse", "HEAD"], repo) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          sha -> sha
        end

      _other ->
        nil
    end
  end

  @doc """
  Nonignored-untracked-inclusive porcelain snapshot of `repo` vs HEAD
  (`""` = clean), or nil when git cannot answer. Gitignored paths stay outside
  the verify authority; submodule noise is excluded.
  """
  @spec porcelain(String.t()) :: String.t() | nil
  def porcelain(repo) do
    case git(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all"], repo) do
      {output, 0} -> output
      _other -> nil
    end
  end

  @doc """
  Untracked-inclusive porcelain snapshot used by the evidence floor's
  wave-boundary capture. This remains a named seam even though verify
  porcelain now has the same inclusion policy.
  """
  @spec porcelain_all(String.t()) :: String.t() | nil
  def porcelain_all(repo), do: porcelain(repo)

  @doc "The production fingerprint bounds, exposed so other engine evidence stays aligned."
  @spec fingerprint_limits() :: %{
          max_files: pos_integer(),
          max_content_bytes: pos_integer(),
          max_path_bytes: pos_integer()
        }
  def fingerprint_limits do
    %{
      max_files: @max_untracked_files,
      max_content_bytes: @max_untracked_content_bytes,
      max_path_bytes: @max_path_bytes
    }
  end

  @doc """
  Fingerprints one exact repo-relative path, or returns nil when the path is
  unsafe, absent, unreadable, raced, unsupported, or over a bound.

  Regular files bind path, type/mode, and content. Symlinks bind path,
  type/mode, and link-target bytes without following the target. The result is
  a domain-separated lowercase SHA-256 digest.
  """
  @spec path_fingerprint(String.t(), String.t(), fingerprint_opts()) :: String.t() | nil
  def path_fingerprint(repo, relative_path, opts \\ []) do
    bounded_capture(opts, fn -> do_path_fingerprint(repo, relative_path, opts) end)
  end

  defp do_path_fingerprint(repo, relative_path, opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, canonical, _content_bytes} <-
           capture_path(repo, relative_path, limits.max_content_bytes, limits, opts) do
      canonical
      |> sha256()
      |> hex()
    else
      _error -> nil
    end
  end

  @doc """
  Fingerprints a bounded set of paths under one aggregate byte budget.

  `on_error: :fail` is all-or-nothing and is what the verify authority uses.
  `on_error: :omit` conservatively omits individually unavailable paths for
  findings-only consumers; global file/content/path bounds still fail the
  whole capture. Duplicate paths are counted once.
  """
  @spec path_fingerprints(String.t(), Enumerable.t(), fingerprint_opts()) ::
          %{optional(String.t()) => String.t()} | nil
  def path_fingerprints(repo, paths, opts \\ []) do
    bounded_capture(opts, fn -> do_path_fingerprints(repo, paths, opts) end)
  end

  defp do_path_fingerprints(repo, paths, opts) do
    with {:ok, limits} <- limits(opts),
         {:ok, on_error} <- on_error(opts),
         {:ok, sorted_paths} <- bounded_paths(paths, limits.max_files),
         {:ok, captures} <- capture_paths(repo, sorted_paths, limits, opts, on_error) do
      Map.new(captures, fn {path, digest} -> {path, hex(digest)} end)
    else
      _error -> nil
    end
  end

  @doc """
  Content-addressed working-tree digest, or nil when capture is unavailable.

  The digest is domain-separated over the tracked binary diff and a sorted,
  bounded manifest of every path reported by
  `git ls-files --others --exclude-standard -z`. Each manifest entry is the
  `path_fingerprint/3` canonical digest; any path failure makes this
  authority capture unavailable rather than silently incomplete.
  """
  @spec diff_digest(String.t(), fingerprint_opts()) :: String.t() | nil
  def diff_digest(repo, opts \\ []) do
    bounded_capture(opts, fn -> do_diff_digest(repo, opts) end)
  end

  defp do_diff_digest(repo, opts) do
    with {:ok, limits} <- limits(opts),
         {tracked_diff, 0} <-
           git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD"], repo),
         {:ok, untracked_paths} <- untracked_paths(repo, limits),
         {:ok, captures} <- capture_paths(repo, untracked_paths, limits, opts, :fail) do
      manifest = [@manifest_domain, u64(length(captures)), Enum.map(captures, &manifest_entry/1)]

      [@tree_domain, field(tracked_diff), field(manifest)]
      |> sha256()
      |> hex()
    else
      _error -> nil
    end
  end

  # A FIFO swapped into the lstat→open window blocks inside prim_file.open_nif.
  # Killing the owning BEAM process does NOT cancel that underlying dirty-I/O
  # syscall. On timeout we therefore ignore (detach from) the task but leave it
  # supervised and counted against a small `max_children` ceiling. The caller
  # returns nil immediately; further captures fail closed once the ceiling is
  # occupied, and a task that eventually unwinds releases its slot naturally.
  defp bounded_capture(opts, fun) when is_list(opts) and is_function(fun, 0) do
    with {:ok, timeout_ms} <- capture_timeout_ms(opts),
         {:ok, task} <- start_capture_task(fun) do
      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          nil

        nil ->
          ignore_timed_out_capture(task, timeout_ms)
      end
    else
      _unavailable -> nil
    end
  rescue
    # Public fail-closed boundary: Enumerable implementations, injected hooks,
    # task-supervisor availability, and filesystem calls are all open sets.
    # reach:disable-next-line bare_rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp bounded_capture(_opts, _fun), do: nil

  defp start_capture_task(fun) do
    {:ok, Task.Supervisor.async_nolink(@capture_supervisor, fun)}
  rescue
    _error in [RuntimeError, ArgumentError] -> {:error, :capture_capacity}
  catch
    :exit, _reason -> {:error, :capture_supervisor_unavailable}
  end

  defp ignore_timed_out_capture(task, timeout_ms) do
    case Task.ignore(task) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        nil

      nil ->
        Logger.warning(
          "[Verify.Git] filesystem capture exceeded #{timeout_ms}ms; " <>
            "leaving the task supervised to contain a potentially blocked open"
        )

        :telemetry.execute(
          [:jido_claw, :orchestration, :verify_capture_timeout],
          %{count: 1},
          %{timeout_ms: timeout_ms}
        )

        nil
    end
  end

  defp capture_timeout_ms(opts) do
    timeout_ms = Keyword.get(opts, :capture_timeout_ms, configured_capture_timeout_ms())

    if is_integer(timeout_ms) and timeout_ms > 0,
      do: {:ok, timeout_ms},
      else: {:error, :invalid_capture_timeout}
  end

  defp configured_capture_timeout_ms do
    case verify_capture_config()[:timeout_ms] do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_capture_timeout_ms
    end
  end

  defp verify_capture_config,
    do: Application.get_env(:jido_claw, :verify_capture, [])

  defp capture_paths(repo, paths, limits, opts, on_error) do
    result =
      Enum.reduce_while(paths, {:ok, [], 0}, fn path, {:ok, captures, used_bytes} ->
        remaining = limits.max_content_bytes - used_bytes

        case capture_path(repo, path, remaining, limits, opts) do
          {:ok, canonical, content_bytes} ->
            digest = sha256(canonical)
            {:cont, {:ok, [{path, digest} | captures], used_bytes + content_bytes}}

          {:error, :bound} ->
            {:halt, {:error, :bound}}

          {:error, reason} ->
            capture_error(reason, on_error, captures, used_bytes)
        end
      end)

    case result do
      {:ok, captures, _used_bytes} -> {:ok, Enum.reverse(captures)}
      error -> error
    end
  end

  defp capture_error(_reason, :omit, captures, used_bytes),
    do: {:cont, {:ok, captures, used_bytes}}

  defp capture_error(reason, :fail, _captures, _used_bytes),
    do: {:halt, {:error, reason}}

  defp capture_path(repo, relative_path, remaining_bytes, limits, opts) do
    with {:ok, root, full_path} <- safe_path(repo, relative_path, limits.max_path_bytes),
         :ok <- stable_parents(root, relative_path),
         {:ok, before} <- File.lstat(full_path, time: :posix),
         :ok <- run_hook(opts, :capture_hook, full_path, before),
         {:ok, canonical, content_bytes} <-
           capture_type(full_path, relative_path, before, remaining_bytes, opts),
         {:ok, final_stat} <- File.lstat(full_path, time: :posix),
         true <- stable_stat?(before, final_stat),
         :ok <- stable_parents(root, relative_path) do
      {:ok, canonical, content_bytes}
    else
      false -> {:error, :race}
      {:error, _reason} = error -> error
      _other -> {:error, :capture}
    end
  end

  defp capture_type(
         full_path,
         relative_path,
         %File.Stat{type: :regular} = before,
         limit,
         opts
       ) do
    if before.size > limit do
      {:error, :bound}
    else
      capture_regular(full_path, relative_path, before, limit, opts)
    end
  end

  defp capture_type(
         full_path,
         relative_path,
         %File.Stat{type: :symlink} = before,
         limit,
         _opts
       ) do
    with {:ok, target} <- File.read_link(full_path),
         :ok <- within_byte_limit(target, limit),
         {:ok, final_stat} <- File.lstat(full_path, time: :posix),
         true <- stable_stat?(before, final_stat) do
      canonical = canonical_entry(relative_path, :symlink, before.mode, sha256(target))
      {:ok, canonical, byte_size(target)}
    else
      false -> {:error, :race}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_type(_full_path, _relative_path, _before, _limit, _opts),
    do: {:error, :special}

  defp capture_regular(full_path, relative_path, before, limit, opts) do
    case File.open(full_path, [:read, :binary, :raw], fn io ->
           with {:ok, opened_before} <- handle_stat(io),
                true <- stable_stat?(before, opened_before),
                {:ok, first_hash, content_bytes} <- hash_bounded(io, limit),
                true <- content_bytes == opened_before.size,
                :ok <- run_hook(opts, :between_read_hook, full_path, opened_before),
                {:ok, opened_middle} <- handle_stat(io),
                true <- stable_stat?(opened_before, opened_middle),
                {:ok, 0} <- :file.position(io, :bof),
                {:ok, second_hash, second_bytes} <- hash_bounded(io, limit),
                true <- second_bytes == content_bytes and second_hash == first_hash,
                {:ok, opened_after} <- handle_stat(io),
                true <- stable_stat?(opened_middle, opened_after) do
             {:ok, first_hash, content_bytes}
           else
             false -> {:error, :race}
             {:error, _reason} = error -> error
             _other -> {:error, :read}
           end
         end) do
      {:ok, {:ok, content_hash, content_bytes}} ->
        {:ok, canonical_entry(relative_path, :regular, before.mode, content_hash), content_bytes}

      {:ok, {:error, _reason} = error} ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_stat(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        {:ok,
         %{
           type: file_info(info, :type),
           size: file_info(info, :size),
           mode: file_info(info, :mode),
           mtime: file_info(info, :mtime),
           ctime: file_info(info, :ctime),
           major_device: file_info(info, :major_device),
           minor_device: file_info(info, :minor_device),
           inode: file_info(info, :inode)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp within_byte_limit(bytes, limit) when byte_size(bytes) <= limit, do: :ok
  defp within_byte_limit(_bytes, _limit), do: {:error, :bound}

  defp hash_bounded(io, limit), do: hash_bounded(io, :crypto.hash_init(:sha256), 0, limit)

  defp hash_bounded(io, context, used, limit) do
    read_size = min(@read_chunk_bytes, limit - used + 1)

    case IO.binread(io, read_size) do
      :eof ->
        {:ok, :crypto.hash_final(context), used}

      {:error, reason} ->
        {:error, reason}

      bytes when is_binary(bytes) and used + byte_size(bytes) <= limit ->
        hash_bounded(io, :crypto.hash_update(context, bytes), used + byte_size(bytes), limit)

      _over_limit ->
        {:error, :bound}
    end
  end

  defp safe_path(repo, relative_path, max_path_bytes)
       when is_binary(repo) and is_binary(relative_path) do
    components = Path.split(relative_path)

    with :ok <- validate_relative_path(relative_path, components, max_path_bytes) do
      root = Path.expand(repo)
      full_path = Path.join(root, relative_path)

      case File.lstat(root, time: :posix) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, root, full_path}
        _error -> {:error, :invalid_repo}
      end
    end
  end

  defp safe_path(_repo, _relative_path, _max_path_bytes), do: {:error, :invalid_path}

  defp validate_relative_path(relative_path, components, max_path_bytes) do
    cond do
      relative_path == "" -> {:error, :invalid_path}
      byte_size(relative_path) > max_path_bytes -> {:error, :bound}
      not String.valid?(relative_path) -> {:error, :invalid_path}
      :binary.match(relative_path, <<0>>) != :nomatch -> {:error, :invalid_path}
      Path.type(relative_path) != :relative -> {:error, :invalid_path}
      Enum.any?(components, &(&1 in ["", ".", ".."])) -> {:error, :invalid_path}
      Enum.join(components, "/") != relative_path -> {:error, :invalid_path}
      true -> :ok
    end
  end

  defp stable_parents(root, relative_path) do
    relative_path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while({:ok, root}, fn component, {:ok, parent} ->
      next = Path.join(parent, component)

      case File.lstat(next, time: :posix) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next}}
        _error -> {:halt, {:error, :unsafe_parent}}
      end
    end)
    |> case do
      {:ok, _parent} -> :ok
      error -> error
    end
  end

  defp stable_stat?(left, right), do: FileStat.stable?(left, right)

  defp canonical_entry(path, type, mode, content_hash) do
    [
      @path_domain,
      field(path),
      field(Atom.to_string(type)),
      field(Integer.to_string(mode)),
      field(content_hash)
    ]
  end

  defp manifest_entry({_path, digest}), do: field(digest)

  # Manifest discovery itself is bounded: `System.cmd/3` would buffer all
  # output before the file-count check. `OsCmd` caps the child at one byte past
  # the largest legal manifest, and the NUL parser halts on the first overlong
  # path or (max_files + 1)th unique entry before sorting anything.
  defp untracked_paths(repo, limits) do
    with executable when is_binary(executable) <- System.find_executable("git"),
         {output, 0} <-
           OsCmd.run(
             executable,
             ["ls-files", "--others", "--exclude-standard", "-z"],
             cd: repo,
             env: Env.scrubbed_cmd_env(),
             max_output_bytes: manifest_output_cap(limits)
           ),
         {:ok, paths} <- parse_z_paths(output, limits, MapSet.new()) do
      {:ok, Enum.sort(MapSet.to_list(paths))}
    else
      _error -> {:error, :manifest}
    end
  end

  defp manifest_output_cap(limits),
    do: limits.max_files * (limits.max_path_bytes + 1) + 1

  defp parse_z_paths("", _limits, paths), do: {:ok, paths}

  defp parse_z_paths(output, limits, paths) when is_binary(output) do
    case :binary.match(output, <<0>>) do
      {0, 1} ->
        {:error, :invalid_manifest}

      {path_bytes, 1} when path_bytes > limits.max_path_bytes ->
        {:error, :bound}

      {path_bytes, 1} ->
        path = binary_part(output, 0, path_bytes)
        rest = binary_part(output, path_bytes + 1, byte_size(output) - path_bytes - 1)

        cond do
          MapSet.member?(paths, path) ->
            parse_z_paths(rest, limits, paths)

          MapSet.size(paths) >= limits.max_files ->
            {:error, :bound}

          true ->
            parse_z_paths(rest, limits, MapSet.put(paths, path))
        end

      :nomatch ->
        {:error, :invalid_manifest}
    end
  end

  defp bounded_paths(paths, max_files) do
    result =
      Enum.reduce_while(paths, {:ok, MapSet.new()}, fn path, {:ok, unique} ->
        cond do
          MapSet.member?(unique, path) ->
            {:cont, {:ok, unique}}

          MapSet.size(unique) >= max_files ->
            {:halt, {:error, :bound}}

          true ->
            {:cont, {:ok, MapSet.put(unique, path)}}
        end
      end)

    case result do
      {:ok, unique} ->
        sorted =
          unique
          |> MapSet.to_list()
          |> Enum.sort()

        {:ok, sorted}

      {:error, _reason} = error ->
        error
    end
  end

  defp limits(opts) when is_list(opts) do
    max_files = Keyword.get(opts, :max_files, @max_untracked_files)
    max_content_bytes = Keyword.get(opts, :max_content_bytes, @max_untracked_content_bytes)
    max_path_bytes = Keyword.get(opts, :max_path_bytes, @max_path_bytes)

    if is_integer(max_files) and max_files >= 0 and is_integer(max_content_bytes) and
         max_content_bytes >= 0 and is_integer(max_path_bytes) and max_path_bytes > 0 do
      {:ok,
       %{
         max_files: max_files,
         max_content_bytes: max_content_bytes,
         max_path_bytes: max_path_bytes
       }}
    else
      {:error, :invalid_bounds}
    end
  end

  defp limits(_opts), do: {:error, :invalid_bounds}

  defp on_error(opts) do
    case Keyword.get(opts, :on_error, :fail) do
      mode when mode in [:fail, :omit] -> {:ok, mode}
      _invalid -> {:error, :invalid_on_error}
    end
  end

  defp run_hook(opts, key, full_path, stat) do
    case Keyword.get(opts, key) do
      nil ->
        :ok

      hook when is_function(hook, 2) ->
        hook.(full_path, stat)
        :ok

      _invalid ->
        {:error, :invalid_hook}
    end
  end

  defp field(iodata) do
    size = IO.iodata_length(iodata)
    [u64(size), iodata]
  end

  defp u64(integer), do: <<integer::unsigned-big-64>>
  defp sha256(iodata), do: :crypto.hash(:sha256, iodata)
  defp hex(digest), do: Base.encode16(digest, case: :lower)

  # The shared git System.cmd idiom (git_status.ex): scrubbed child env, cd
  # into the repo, nil-safe on the spawn-failure raises (missing git binary /
  # bad cwd raise ErlangError; a malformed arg raises ArgumentError — the
  # `Core.OsCmd.run_cmd/2` rescue set).
  defp git(args, repo) do
    System.cmd("git", args, cd: repo, env: Env.scrubbed_cmd_env())
  rescue
    _error in [ErlangError, ArgumentError] -> {"", 1}
  end
end
