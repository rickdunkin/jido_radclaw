defmodule JidoClaw.Tools.SearchCode do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "search_code",
    description:
      "Search files recursively with bounded regex, traversal, byte, match, and time budgets. Oversized and non-regular files are skipped, and deadline-limited results are explicitly marked partial. Returns matching lines with file paths and line numbers.",
    category: "filesystem",
    tags: ["io", "read"],
    output_schema: [
      matches: [type: :string, required: true],
      total_matches: [type: :integer, required: true]
    ],
    schema: [
      pattern: [type: :string, required: true, doc: "Search pattern (regex supported)"],
      path: [type: :string, default: ".", doc: "Directory to search in"],
      glob: [type: :string, doc: "File pattern filter (e.g. '*.ex', '*.ts')"],
      max_results: [type: :integer, default: 50, doc: "Max results to return"]
    ]

  alias JidoClaw.Tools.FilePayloadLimit
  alias JidoClaw.Tools.MCPScope
  alias JidoClaw.VFS.Resolver
  alias JidoClaw.VFS.Sandbox

  @max_results 1_000
  @max_depth 64
  @max_entries 20_000
  @max_directory_entries 5_000
  @max_files 5_000
  @max_total_bytes 50 * 1024 * 1024
  @max_matches 100_000
  @max_pattern_bytes 8 * 1024
  @max_glob_bytes 4 * 1024
  @default_timeout_ms 5_000
  @regex_match_limit 100_000
  @regex_recursion_limit 10_000
  @deadline_key :__jido_deadline_ms__
  @search_deadline_opt :search_deadline_ms
  @compile_hook_opt :search_compile_hook
  @visit_hook_opt :search_visit_hook

  @impl Jido.Action
  def run(%{pattern: _pattern} = params, context) do
    MCPScope.wrap(:search_code, params, context, fn enriched ->
      with {:ok, opts} <- Sandbox.resolver_opts(get_in(enriched, [:tool_context])) do
        search(params, with_deadline(opts, enriched))
      end
    end)
  end

  @doc """
  The pure recursive search core, shared by `search_code` (sandbox/cwd opts) and
  `search_real_code` (real-tree opts, AR-8b-2 F3). Takes already-derived
  `Resolver` opts so the opts source (and the owning tool's own
  `MCPScope.wrap`/approval/redaction pipeline) stays with each surface. Both
  surfaces share the same per-file and aggregate traversal budgets. Structural,
  aggregate-byte, regex-work, and match-count caps fail loudly. A per-file size
  cap and non-regular local entries skip those paths with explicit counts, while
  a traversal deadline returns the matches found so far with an explicit
  incomplete-result note. Returns the `search_code` result shape or `{:error, _}`.
  """
  @spec search(%{required(:pattern) => String.t(), optional(atom()) => term()}, keyword()) ::
          {:ok, %{matches: String.t(), total_matches: non_neg_integer()}} | {:error, term()}
  def search(%{pattern: pattern} = params, opts) do
    max_results = normalize_max_results(Map.get(params, :max_results, 50))
    {deadline, compile_hook, visit_hook, resolver_opts} = search_deadline(opts)
    budget = new_budget(max_results, deadline, visit_hook)

    with {:ok, regex} <- compile_pattern(pattern, deadline, compile_hook),
         {:ok, glob} <- compile_glob(Map.get(params, :glob), deadline, compile_hook) do
      Map.get(params, :path, ".")
      |> search_path(regex, glob, resolver_opts, budget, 0)
      |> format_search_result(max_results)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
    end
  end

  defp format_search_result({:ok, result}, max_results),
    do: {:ok, render_result(result, max_results, nil)}

  defp format_search_result({:partial, result, reason}, max_results),
    do: {:ok, render_result(result, max_results, reason)}

  defp format_search_result({:error, reason}, _max_results) when is_binary(reason),
    do: {:error, reason}

  defp format_search_result({:error, reason}, _max_results), do: {:error, inspect(reason)}

  defp render_result(result, max_results, incomplete_reason) do
    content =
      result.matches
      |> Enum.reverse()
      |> Enum.join("\n")

    notes =
      []
      |> maybe_add_truncation_note(result.total_matches, max_results)
      |> maybe_add_oversized_note(result.skipped_oversized)
      |> maybe_add_non_regular_note(result.skipped_non_regular)
      |> maybe_add_incomplete_note(incomplete_reason, result)
      |> Enum.reverse()

    matches = Enum.join(Enum.reject([content | notes], &(&1 == "")), "\n")
    %{matches: matches, total_matches: result.total_matches}
  end

  defp maybe_add_truncation_note(notes, total, retained) when total > retained,
    do: ["(#{total - retained} more matches truncated)" | notes]

  defp maybe_add_truncation_note(notes, _total, _retained), do: notes

  defp maybe_add_oversized_note(notes, 0), do: notes

  defp maybe_add_oversized_note(notes, count) do
    noun = if count == 1, do: "file", else: "files"

    [
      "(partial search: skipped #{count} oversized #{noun} above the " <>
        "#{FilePayloadLimit.max_bytes()}-byte per-file cap)"
      | notes
    ]
  end

  defp maybe_add_non_regular_note(notes, 0), do: notes

  defp maybe_add_non_regular_note(notes, count) do
    noun = if count == 1, do: "entry", else: "entries"

    [
      "(partial search: skipped #{count} non-regular filesystem #{noun} to avoid " <>
        "potentially blocking reads)"
      | notes
    ]
  end

  defp maybe_add_incomplete_note(notes, nil, _result), do: notes

  defp maybe_add_incomplete_note(notes, :deadline, result) do
    [
      "(incomplete search: deadline reached after #{result.files} searched files; " <>
        "total_matches counts only examined content)"
      | notes
    ]
  end

  defp compile_pattern(pattern, deadline, compile_hook) when is_binary(pattern) do
    with :ok <- compile_input_size(pattern, "regular expression", @max_pattern_bytes),
         {:ok, result} <-
           compile_before_deadline(deadline, :regex, compile_hook, fn ->
             Regex.compile(pattern)
           end) do
      case result do
        {:ok, regex} -> {:ok, regex}
        {:error, reason} -> {:error, "invalid search pattern: #{inspect(reason)}"}
      end
    end
  end

  defp compile_pattern(_pattern, _deadline, _compile_hook),
    do: {:error, "invalid search pattern: expected string"}

  defp compile_glob(nil, _deadline, _compile_hook), do: {:ok, nil}

  defp compile_glob(glob, deadline, compile_hook) when is_binary(glob) do
    with :ok <- compile_input_size(glob, "glob", @max_glob_bytes),
         {:ok, result} <-
           compile_before_deadline(deadline, :glob, compile_hook, fn ->
             try do
               {:ok, GlobEx.compile!(glob)}
             rescue
               error in GlobEx.CompileError -> {:error, Exception.message(error)}
             end
           end) do
      case result do
        {:ok, compiled} -> {:ok, compiled}
        {:error, reason} -> {:error, "invalid glob: #{reason}"}
      end
    end
  end

  defp compile_glob(_glob, _deadline, _compile_hook),
    do: {:error, "invalid glob: expected string"}

  defp compile_input_size(value, kind, limit) do
    if byte_size(value) <= limit, do: :ok, else: limit_error("#{kind} bytes", limit)
  end

  # Compilation itself is isolated in a supervised, unlinked task and bounded
  # by the search's remaining absolute deadline. The task catches every compiler
  # exception so it always exits normally; on timeout it is brutally stopped and
  # drained by `Task.shutdown/2`. Byte caps above are the first line of defense
  # and also bound work in runtimes where a regex compiler NIF cannot observe a
  # process exit until it returns.
  defp compile_before_deadline(deadline, kind, compile_hook, fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "search limit exceeded: deadline"}
    else
      task =
        Task.Supervisor.async_nolink(JidoClaw.TaskSupervisor, fn ->
          try do
            {:returned, compile_hook.(kind, fun)}
            # User-selected compiler hooks expose an open exception set; the task
            # must always report it as data so its deadline/kill envelope holds.
          rescue
            # reach:disable-next-line bare_rescue
            exception -> {:raised, Exception.message(exception)}
          catch
            kind, reason -> {:raised, inspect({kind, reason})}
          end
        end)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:returned, result}} ->
          if System.monotonic_time(:millisecond) >= deadline,
            do: {:error, "search limit exceeded: deadline"},
            else: {:ok, result}

        {:ok, {:raised, reason}} ->
          {:error, "pattern compilation failed: #{reason}"}

        {:exit, reason} ->
          {:error, "pattern compilation failed: #{inspect(reason)}"}

        nil ->
          {:error, "search limit exceeded: deadline"}
      end
    end
  end

  @doc "Adds the tighter of Jido's absolute deadline and the local search timeout to resolver opts."
  @spec with_deadline(keyword(), map()) :: keyword()
  def with_deadline(opts, context) do
    now = System.monotonic_time(:millisecond)
    local_deadline = now + configured_timeout_ms()

    deadline =
      case Map.get(context, @deadline_key) do
        absolute when is_integer(absolute) -> min(absolute, local_deadline)
        _missing -> local_deadline
      end

    Keyword.put(opts, @search_deadline_opt, deadline)
  end

  defp search_deadline(opts) do
    now = System.monotonic_time(:millisecond)

    {configured_hook, without_compile_hook} =
      Keyword.pop(opts, @compile_hook_opt, &default_compile_hook/2)

    {configured_visit_hook, without_hooks} =
      Keyword.pop(without_compile_hook, @visit_hook_opt, &default_visit_hook/1)

    compile_hook =
      if is_function(configured_hook, 2), do: configured_hook, else: &default_compile_hook/2

    visit_hook =
      if is_function(configured_visit_hook, 1),
        do: configured_visit_hook,
        else: &default_visit_hook/1

    case Keyword.pop(without_hooks, @search_deadline_opt) do
      {deadline, resolver_opts} when is_integer(deadline) ->
        {deadline, compile_hook, visit_hook, resolver_opts}

      {_missing, resolver_opts} ->
        {now + configured_timeout_ms(), compile_hook, visit_hook, resolver_opts}
    end
  end

  defp configured_timeout_ms do
    configured = Application.get_env(:jido_claw, :search_code, [])

    value =
      cond do
        is_list(configured) -> Keyword.get(configured, :timeout_ms, @default_timeout_ms)
        is_map(configured) -> Map.get(configured, :timeout_ms, @default_timeout_ms)
        true -> @default_timeout_ms
      end

    if is_integer(value) and value > 0, do: value, else: @default_timeout_ms
  end

  defp default_compile_hook(_kind, fun), do: fun.()
  defp default_visit_hook(_path), do: :ok

  defp new_budget(max_results, deadline, visit_hook) do
    %{
      entries: 0,
      files: 0,
      bytes: 0,
      total_matches: 0,
      skipped_oversized: 0,
      skipped_non_regular: 0,
      matches: [],
      retain: max_results,
      deadline: deadline,
      visit_hook: visit_hook
    }
  end

  defp normalize_max_results(value) when is_integer(value),
    do: min(max(value, 1), @max_results)

  defp normalize_max_results(_value), do: 50

  defp search_path(_path, _regex, _glob, _opts, _budget, depth) when depth > @max_depth,
    do: limit_error("directory depth", @max_depth)

  defp search_path(path, regex, glob, opts, budget, depth) do
    case check_deadline(budget) do
      :deadline ->
        {:partial, budget, :deadline}

      :ok ->
        with {:ok, budget} <- count_entry(budget) do
          case Resolver.ls(path, opts) do
            {:ok, names} -> search_directory(path, names, regex, glob, opts, budget, depth)
            {:error, _reason} -> search_file(path, regex, glob, opts, budget)
          end
        end
    end
  end

  defp search_directory(path, names, regex, glob, opts, budget, depth) do
    if Enum.count_until(names, @max_directory_entries + 1) > @max_directory_entries do
      limit_error("entries in one directory", @max_directory_entries)
    else
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, budget}, fn name, {:ok, acc} ->
        case search_path(join_path(path, name), regex, glob, opts, acc, depth + 1) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:partial, next, reason} -> {:halt, {:partial, next, reason}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp search_file(path, regex, glob, opts, budget) do
    if glob_match?(glob, path) do
      with :ok <- run_visit_hook(budget.visit_hook, path),
           {:ok, budget} <- count_file(budget) do
        case check_deadline(budget) do
          :deadline -> {:partial, budget, :deadline}
          :ok -> read_searchable_file(path, regex, opts, budget)
        end
      end
    else
      {:ok, budget}
    end
  end

  defp read_searchable_file(path, regex, opts, budget) do
    case FilePayloadLimit.validate_read(path, opts) do
      :ok -> read_and_match(path, regex, opts, budget)
      {:error, reason} -> file_read_error(path, reason, budget)
    end
  end

  defp read_and_match(path, regex, opts, budget) do
    case Resolver.read(path, opts) do
      {:ok, content} when is_binary(content) ->
        case FilePayloadLimit.validate_read_content(path, content) do
          :ok ->
            with {:ok, budget} <- count_bytes(budget, byte_size(content)) do
              matching_lines(path, content, regex, budget)
            end

          {:error, reason} ->
            file_read_error(path, reason, budget)
        end

      {:error, reason} ->
        {:error, "Cannot search #{path}: #{inspect(reason)}"}
    end
  end

  defp file_read_error(path, reason, budget) do
    cond do
      oversized_file_error?(reason) ->
        {:ok, %{budget | skipped_oversized: budget.skipped_oversized + 1}}

      non_regular_file_error?(reason) ->
        {:ok, %{budget | skipped_non_regular: budget.skipped_non_regular + 1}}

      true ->
        {:error, "Cannot search #{path}: #{inspect(reason)}"}
    end
  end

  defp oversized_file_error?(%{details: %{max_bytes: max_bytes}}),
    do: max_bytes == FilePayloadLimit.max_bytes()

  defp oversized_file_error?(_reason), do: false

  defp non_regular_file_error?(%{details: %{type: type}}), do: type != :regular
  defp non_regular_file_error?(_reason), do: false

  defp run_visit_hook(hook, path) do
    hook.(path)
    :ok
  end

  defp glob_match?(nil, _path), do: true
  defp glob_match?(glob, path), do: GlobEx.match?(glob, Path.basename(path))

  defp matching_lines(path, content, regex, budget) do
    if String.valid?(content) do
      content
      |> String.splitter("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, budget}, fn {line, line_number}, {:ok, acc} ->
        case match_line(path, line, line_number, regex, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:partial, next, reason} -> {:halt, {:partial, next, reason}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:ok, budget}
    end
  end

  defp match_line(path, line, line_number, regex, budget) do
    case check_deadline(budget) do
      :deadline ->
        {:partial, budget, :deadline}

      :ok ->
        with {:ok, matched?} <- bounded_regex_match(regex, line) do
          if matched?,
            do: add_match(budget, "#{path}:#{line_number}:#{line}"),
            else: {:ok, budget}
        end
    end
  end

  defp count_entry(%{entries: count}) when count >= @max_entries,
    do: limit_error("traversed entries", @max_entries)

  defp count_entry(budget), do: {:ok, %{budget | entries: budget.entries + 1}}

  defp count_file(%{files: count}) when count >= @max_files,
    do: limit_error("searched files", @max_files)

  defp count_file(budget), do: {:ok, %{budget | files: budget.files + 1}}

  defp count_bytes(%{bytes: bytes}, size) when bytes + size > @max_total_bytes,
    do: limit_error("total file bytes", @max_total_bytes)

  defp count_bytes(budget, size), do: {:ok, %{budget | bytes: budget.bytes + size}}

  defp add_match(%{total_matches: count}, _line) when count >= @max_matches,
    do: limit_error("matching lines", @max_matches)

  defp add_match(budget, line) do
    matches =
      if budget.total_matches < budget.retain, do: [line | budget.matches], else: budget.matches

    {:ok, %{budget | total_matches: budget.total_matches + 1, matches: matches}}
  end

  defp bounded_regex_match(regex, line) do
    case :re.run(line, regex.re_pattern, [
           {:match_limit, @regex_match_limit},
           {:match_limit_recursion, @regex_recursion_limit},
           :report_errors,
           {:capture, :none}
         ]) do
      :match -> {:ok, true}
      :nomatch -> {:ok, false}
      {:error, reason} -> limit_error("regular expression #{reason}", @regex_match_limit)
    end
  end

  defp check_deadline(%{deadline: deadline}) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: :deadline,
      else: :ok
  end

  defp limit_error(kind, limit), do: {:error, "search limit exceeded: #{kind} (#{limit})"}

  defp join_path(parent, child) do
    case String.trim_trailing(parent, "/") do
      "" -> child
      "/" -> "/" <> child
      path -> path <> "/" <> child
    end
  end
end
