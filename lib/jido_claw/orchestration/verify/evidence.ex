defmodule JidoClaw.Orchestration.Verify.Evidence do
  @moduledoc """
  The evidence floor (OB1-3, absorbing camus C1-6c): classify a worker stage's
  self-reported claims against the transcript the engine already stores
  durably, and synthesize deterministic findings for positive discrepancies.
  Port of ouroboros's transcript-grounded evidence verifier — semantics map
  `docs/exploration/ouroboros/PORT-OB1-3.md` (`Q00/ouroboros @ e905a41c`, MIT,
  © 2025 Q00).

  Three claim kinds ride a `%StageEmission{}`'s `evidence` block:

    * `:commands_run` — supported when a durable `run_command` tool row's
      recorded command backs the claim (normalized containment, tolerant of
      plumbing) with `:preserved` exit-code provenance; a masked/unanalyzable
      match is `:form_mismatch`.
    * `:tests_passed` — supported only by a matching row that IS a test
      invocation (`ShellCommand.exit_code_provenance/1`'s runner fact), with
      `exit_code == 0`, unmasked provenance, and no skip flags. A matched row
      with a nonzero exit is `:unsupported` — the false-green catch. A
      matched-but-masked (or unanalyzable) row is `:form_mismatch`.
    * `:files_touched` — supported iff the claimed path's git status CHANGED
      during this wave, or an already-dirty path has two bounded fingerprints
      whose content/type/mode identity changed (dispatch-time vs fold-time;
      union across same-wave stages). Bare existence is never support; a path
      outside the repo skips (can't verify ⇒ trust).

  The conservative override rule governs everything: only a *positive
  discrepancy* (`:unsupported`) ever becomes a finding; can't-verify skips
  toward trust, and masking (`:form_mismatch`) is findings-only-context in v1
  — it never flips anything. The verdict partition is ouroboros-verbatim: any
  genuinely-absent claim ⇒ `:fabrication_suspected`; all-masked ⇒
  `:form_mismatch`; nothing checked ⇒ `:skipped`.

  Self-report exclusion is structural: the evidence base is the durable
  `:tool_call`/`:tool_result` rows (`Conversations.Message.by_request`), never
  assistant text — a claim cannot support itself. Rows whose metadata was
  sensitivity-scrubbed (`%{"redacted" => true}`) are excluded; a transcript
  whose tool rows are all unreadable skips `:redacted` — degraded, never
  suspicious. The rows are compaction-immune (the Recorder writes from
  `ai.tool.*` signals regardless of context compaction), which is how the
  OpenHelm OH1-3 compaction guard folds in here as the absent-transcript skip.

  The impure read rides the `reader/0` seam (`config :jido_claw, :evidence,
  reader: module` — the `Verify.git/0` precedent); everything else is pure.
  """

  alias JidoClaw.Security.ShellCommand
  alias JidoClaw.Security.ShellCommand.Provenance

  @type claim_status :: :supported | :unsupported | :form_mismatch | :skipped
  @type claim_kind :: :commands_run | :tests_passed | :files_touched

  @type claim_result :: %{
          kind: claim_kind(),
          value: String.t(),
          status: claim_status(),
          detail: String.t()
        }

  @type verdict :: :clean | :form_mismatch | :fabrication_suspected | :skipped

  @type classification :: %{
          verdict: verdict(),
          claims: [claim_result()],
          counts: %{
            supported: non_neg_integer(),
            unsupported: non_neg_integer(),
            form_mismatch: non_neg_integer(),
            skipped: non_neg_integer()
          }
        }

  @type observation :: %{command: String.t(), exit_code: integer() | nil}

  @type observations :: %{
          tool_rows: {:ok, [observation()]} | {:skip, atom()},
          changed_paths: {:ok, MapSet.t(String.t())} | {:skip, atom()},
          fingerprint_changed_paths: MapSet.t(String.t()),
          repo: String.t() | nil
        }

  @type discrepancy :: %{title: String.t(), location: String.t(), description: String.t()}

  @detail_cap 200
  @description_cap 900

  # ---------------------------------------------------------------------------
  # Seam + gather (the only impure surface)
  # ---------------------------------------------------------------------------

  @doc """
  The transcript reader seam: `config :jido_claw, :evidence, reader: module`
  (a module exporting `tool_rows(session_id, request_id, opts) :: {:ok,
  [row]} | {:error, term}`), defaulting to the real `Evidence.Reader`.
  """
  @spec reader() :: module()
  def reader do
    :jido_claw
    |> Application.get_env(:evidence, [])
    |> Keyword.get(:reader, __MODULE__.Reader)
  end

  @doc """
  Gather the evidence base for one stage emission: the request's decoded
  `run_command` tool rows plus the wave-scoped changed-path sets from the
  `ctx` porcelain snapshots and bounded before/after fingerprints captured by
  the composer. Each half skips independently — nil request_id, a read error,
  or an all-redacted transcript skip the tool-row half (toward trust, never
  toward suspicion); a missing porcelain snapshot skips the files half even
  when fingerprints exist. Missing fingerprints add no proof. Never raises.
  """
  @spec gather(String.t() | nil, map()) :: observations()
  def gather(request_id, ctx) when is_map(ctx) do
    %{
      tool_rows: gather_tool_rows(request_id, ctx),
      changed_paths: gather_changed_paths(ctx),
      fingerprint_changed_paths: gather_fingerprint_changed_paths(ctx),
      repo: ctx[:repo]
    }
  end

  defp gather_tool_rows(request_id, _ctx) when not is_binary(request_id),
    do: {:skip, :no_request_id}

  defp gather_tool_rows(request_id, ctx) do
    case ctx[:session_id] do
      session_id when is_binary(session_id) ->
        read_tool_rows(session_id, request_id, tenant: ctx[:tenant], actor: ctx[:actor])

      _missing ->
        {:skip, :no_session}
    end
  end

  defp read_tool_rows(session_id, request_id, opts) do
    case reader().tool_rows(session_id, request_id, opts) do
      {:ok, rows} when is_list(rows) -> decode_rows(rows)
      {:error, _reason} -> {:skip, :read_error}
    end
  rescue
    # The floor is advisory: a reader fault degrades to a skip, never into
    # the wave fold.
    # reach:disable-next-line bare_rescue
    _ -> {:skip, :read_error}
  end

  defp gather_changed_paths(ctx) do
    case {ctx[:before_porcelain], ctx[:after_porcelain]} do
      {before_snapshot, after_snapshot}
      when is_binary(before_snapshot) and is_binary(after_snapshot) ->
        {:ok, changed_paths(before_snapshot, after_snapshot)}

      _missing ->
        {:skip, :no_snapshot}
    end
  end

  defp gather_fingerprint_changed_paths(ctx) do
    fingerprint_changed_paths(
      ctx[:before_file_fingerprints],
      ctx[:after_file_fingerprints]
    )
  end

  # ---------------------------------------------------------------------------
  # Row decode (pure; the TranscriptEnvelope-quirk boundary)
  # ---------------------------------------------------------------------------

  @doc """
  Decode raw transcript rows (each `%{role, tool_call_id, metadata}`-shaped,
  atom- or string-keyed) into command observations. `{:skip, :no_transcript}`
  when no tool rows exist at all (the vendor arm — its CLI's tool calls never
  ride our pipeline); `{:skip, :redacted}` when tool rows exist but every one
  is sensitivity-scrubbed (degraded, never suspicious).
  """
  @spec decode_rows([map()]) :: {:ok, [observation()]} | {:skip, :no_transcript | :redacted}
  def decode_rows(rows) do
    tool_rows = Enum.filter(rows, &tool_row?/1)

    cond do
      tool_rows == [] -> {:skip, :no_transcript}
      Enum.all?(tool_rows, &redacted_row?/1) -> {:skip, :redacted}
      true -> {:ok, observations_from(Enum.reject(tool_rows, &redacted_row?/1))}
    end
  end

  defp tool_row?(row) do
    field(row, :role) in [:tool_call, :tool_result, "tool_call", "tool_result"]
  end

  # The Recorder's sensitivity scrub replaces the whole metadata map with
  # `%{"redacted" => true}`; a non-map metadata is equally unreadable.
  defp redacted_row?(row) do
    case field(row, :metadata) do
      %{} = metadata -> field(metadata, :redacted) == true
      _other -> true
    end
  end

  defp observations_from(rows) do
    {calls, results} =
      Enum.reduce(rows, {[], %{}}, fn row, {calls, results} ->
        metadata = field(row, :metadata)
        call_id = field(row, :tool_call_id)

        cond do
          field(metadata, :tool_name) != "run_command" ->
            {calls, results}

          field(row, :role) in [:tool_call, "tool_call"] ->
            case command_of(metadata) do
              command when is_binary(command) -> {[{call_id, command} | calls], results}
              _other -> {calls, results}
            end

          true ->
            case Map.get(results, call_id) do
              nil -> {calls, Map.put(results, call_id, exit_code_of(metadata))}
              _existing -> {calls, results}
            end
        end
      end)

    calls
    |> Enum.reverse()
    |> Enum.map(fn {call_id, command} ->
      # Wire-shaped observation record (gather → classify); a struct would
      # ripple the reader-stub boundary.
      # reach:disable-next-line fixed_shape_map
      %{command: command, exit_code: Map.get(results, call_id)}
    end)
  end

  defp command_of(metadata) do
    case field(metadata, :arguments) do
      %{} = arguments -> field(arguments, :command)
      _other -> nil
    end
  end

  # `{:ok, %{exit_code: N, …}}` persists (via TranscriptEnvelope + JSONB) as
  # `%{"status" => "ok", "value" => %{"exit_code" => N}}`; anything else —
  # error envelopes, missing results, tuple quirks — reads as nil
  # (unanalyzable, never fabricated).
  defp exit_code_of(metadata) do
    with %{} = result <- field(metadata, :result),
         %{} = value <- field(result, :value),
         exit_code when is_integer(exit_code) <- field(value, :exit_code) do
      exit_code
    else
      _other -> nil
    end
  end

  # Atom key wins (test-built rows), else the string key (JSONB round-trip).
  defp field(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp field(_map, _key), do: nil

  # ---------------------------------------------------------------------------
  # Porcelain diff (pure — the camus C1-6c files reconcile)
  # ---------------------------------------------------------------------------

  @doc """
  The wave changed-path set: every path whose XY status differs between the
  dispatch-time and fold-time untracked-inclusive porcelain snapshots —
  including appearing (`??`) or disappearing. Rename rows (`R  old -> new`)
  contribute both sides. Pure string parsing; quoted paths are unquoted.
  """
  @spec changed_paths(String.t(), String.t()) :: MapSet.t(String.t())
  def changed_paths(before_snapshot, after_snapshot) do
    before_statuses = porcelain_status_map(before_snapshot)
    after_statuses = porcelain_status_map(after_snapshot)

    [Map.keys(before_statuses), Map.keys(after_statuses)]
    |> Enum.concat()
    |> Enum.uniq()
    |> Enum.filter(fn path ->
      Map.get(before_statuses, path) != Map.get(after_statuses, path)
    end)
    |> MapSet.new()
  end

  @doc "Every path represented by one porcelain snapshot, including both rename sides."
  @spec snapshot_paths(String.t()) :: MapSet.t(String.t())
  def snapshot_paths(snapshot) when is_binary(snapshot) do
    snapshot
    |> porcelain_status_map()
    |> Map.keys()
    |> MapSet.new()
  end

  def snapshot_paths(_snapshot), do: MapSet.new()

  @doc "Paths with two present bounded fingerprints whose values differ."
  @spec fingerprint_changed_paths(map() | nil, map() | nil) :: MapSet.t(String.t())
  def fingerprint_changed_paths(before_fingerprints, after_fingerprints)
      when is_map(before_fingerprints) and is_map(after_fingerprints) do
    Enum.reduce(before_fingerprints, MapSet.new(), fn {path, before_fp}, changed ->
      case Map.fetch(after_fingerprints, path) do
        {:ok, after_fp}
        when is_binary(before_fp) and is_binary(after_fp) and before_fp != after_fp ->
          MapSet.put(changed, path)

        _missing_or_unreadable ->
          changed
      end
    end)
  end

  def fingerprint_changed_paths(_before_fingerprints, _after_fingerprints),
    do: MapSet.new()

  defp porcelain_status_map(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &porcelain_line/2)
  end

  defp porcelain_line(<<x, y, ?\s, rest::binary>>, acc) do
    status = <<x, y>>

    case rename_parts(x, y, rest) do
      {:rename, from, to} ->
        acc
        |> Map.put(unquote_path(from), status <> ":renamed-from")
        |> Map.put(unquote_path(to), status)

      {:path, path} ->
        Map.put(acc, unquote_path(path), status)
    end
  end

  defp porcelain_line(_line, acc), do: acc

  # Only R/C statuses carry the porcelain v1 `old -> new` grammar. Find the
  # separator outside Git's C-quoted strings so an ordinary path literally
  # named `foo -> bar` is never split into fabricated rename sides.
  defp rename_parts(x, y, rest) when x in [?R, ?C] or y in [?R, ?C] do
    case rename_separator_index(rest, 0, false) do
      nil ->
        {:path, rest}

      index ->
        from = binary_part(rest, 0, index)
        to = binary_part(rest, index + 4, byte_size(rest) - index - 4)
        {:rename, from, to}
    end
  end

  defp rename_parts(_x, _y, rest), do: {:path, rest}

  defp rename_separator_index(<<>>, _index, _quoted?), do: nil

  defp rename_separator_index(<<?\\, _escaped, rest::binary>>, index, true),
    do: rename_separator_index(rest, index + 2, true)

  defp rename_separator_index(<<?", rest::binary>>, index, quoted?),
    do: rename_separator_index(rest, index + 1, not quoted?)

  defp rename_separator_index(<<" -> ", _rest::binary>>, index, false), do: index

  defp rename_separator_index(<<_byte, rest::binary>>, index, quoted?),
    do: rename_separator_index(rest, index + 1, quoted?)

  # Git C-quotes paths containing whitespace/nonprintable bytes. Decode its
  # fixed escape set and one-to-three-digit octal byte escapes in one pass;
  # chained String.replace calls are incorrect for a literal `\\n` filename
  # because decoding `\\\\` first manufactures a newline escape.
  defp unquote_path(<<?", rest::binary>> = original) do
    with size when size > 0 <- byte_size(rest),
         ?" <- :binary.last(rest) do
      inner = binary_part(rest, 0, size - 1)

      case decode_git_quoted(inner, []) do
        {:ok, decoded} -> decoded
        :error -> original
      end
    else
      _missing_close_quote ->
        original
    end
  end

  defp unquote_path(plain), do: plain

  defp decode_git_quoted(<<>>, acc) do
    decoded =
      acc
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    {:ok, decoded}
  end

  defp decode_git_quoted(<<?", _rest::binary>>, _acc), do: :error
  defp decode_git_quoted(<<?\\>>, _acc), do: :error

  defp decode_git_quoted(<<?\\, escaped, rest::binary>>, acc)
       when escaped in [?a, ?b, ?t, ?n, ?v, ?f, ?r, ?", ?\\] do
    byte =
      case escaped do
        ?a -> 7
        ?b -> 8
        ?t -> 9
        ?n -> 10
        ?v -> 11
        ?f -> 12
        ?r -> 13
        other -> other
      end

    decode_git_quoted(rest, [<<byte>> | acc])
  end

  defp decode_git_quoted(<<?\\, octal, rest::binary>>, acc) when octal in ?0..?7 do
    {digits, rest} = take_octal(rest, [octal], 1)
    reversed = Enum.reverse(digits)
    value = List.to_integer(reversed, 8)
    decode_git_quoted(rest, [<<value>> | acc])
  end

  defp decode_git_quoted(<<?\\, _unknown, _rest::binary>>, _acc), do: :error

  defp decode_git_quoted(<<byte, rest::binary>>, acc),
    do: decode_git_quoted(rest, [<<byte>> | acc])

  defp take_octal(<<digit, rest::binary>>, digits, count)
       when digit in ?0..?7 and count < 3,
       do: take_octal(rest, [digit | digits], count + 1)

  defp take_octal(rest, digits, _count), do: {digits, rest}

  # ---------------------------------------------------------------------------
  # Classify (pure)
  # ---------------------------------------------------------------------------

  @doc """
  Classify one stage's claims against the gathered observations. Total over
  arbitrary input: nil/empty claims yield the `:skipped` verdict. Verdict
  partition (ouroboros-verbatim): any `:unsupported` ⇒
  `:fabrication_suspected`; else any `:form_mismatch` ⇒ `:form_mismatch`;
  else any `:supported` ⇒ `:clean`; else `:skipped`.
  """
  @spec classify(map() | nil, observations()) :: classification()
  def classify(claims, observations) when is_map(claims) do
    results =
      Enum.flat_map([:commands_run, :tests_passed, :files_touched], fn kind ->
        claims
        |> Map.get(kind, [])
        |> claim_values()
        |> Enum.map(&classify_claim(kind, &1, observations))
      end)

    %{verdict: verdict(results), claims: results, counts: counts(results)}
  end

  def classify(_claims, _observations),
    do: %{verdict: :skipped, claims: [], counts: counts([])}

  # Totality guard: a claim kind's value is only ever consumed as a list of
  # binaries; any other shape contributes nothing (the mapper normalized
  # upstream, but classify must not trust its caller).
  defp claim_values(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp claim_values(_values), do: []

  defp verdict(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      :unsupported in statuses -> :fabrication_suspected
      :form_mismatch in statuses -> :form_mismatch
      :supported in statuses -> :clean
      true -> :skipped
    end
  end

  defp counts(results) do
    base = %{supported: 0, unsupported: 0, form_mismatch: 0, skipped: 0}

    Enum.reduce(results, base, fn %{status: status}, acc ->
      Map.update!(acc, status, &(&1 + 1))
    end)
  end

  defp classify_claim(kind, value, observations) when kind in [:commands_run, :tests_passed] do
    case observations.tool_rows do
      {:skip, reason} ->
        claim_result(kind, value, :skipped, "transcript unavailable (#{reason})")

      {:ok, []} ->
        claim_result(kind, value, :skipped, "no command transcript (vendor arm or no commands)")

      {:ok, rows} ->
        classify_command_kind(kind, value, rows)
    end
  end

  defp classify_claim(:files_touched, value, observations) do
    case observations.changed_paths do
      {:skip, reason} ->
        claim_result(:files_touched, value, :skipped, "wave snapshot unavailable (#{reason})")

      {:ok, changed} ->
        classify_file_claim(
          value,
          changed,
          Map.get(observations, :fingerprint_changed_paths, MapSet.new()),
          observations.repo
        )
    end
  end

  # ---- commands_run / tests_passed ----

  defp classify_command_kind(:commands_run, value, rows) do
    matches = Enum.filter(rows, &command_claim_match?(value, &1))

    cond do
      matches == [] ->
        claim_result(:commands_run, value, :unsupported, "no matching command in transcript")

      Enum.any?(matches, &(provenance(&1).exit_code == :preserved)) ->
        claim_result(:commands_run, value, :supported, "backed by transcript")

      true ->
        claim_result(
          :commands_run,
          value,
          :form_mismatch,
          "matched only runs with masked or unanalyzable exit plumbing"
        )
    end
  end

  defp classify_command_kind(:tests_passed, value, rows) do
    # One pass over the matched runner invocations, folding the precedence
    # facts: any clean green ⇒ supported; else the first red exit (the
    # false-green catch) ⇒ unsupported; else a skip-flagged runner ⇒
    # unsupported; else matched-but-masked ⇒ form_mismatch.
    summary = test_run_summary(value, rows)

    cond do
      not summary.matched ->
        claim_result(
          :tests_passed,
          value,
          :unsupported,
          "no matching test invocation in transcript"
        )

      summary.green ->
        claim_result(:tests_passed, value, :supported, "clean test invocation, exit 0")

      summary.red != nil ->
        claim_result(
          :tests_passed,
          value,
          :unsupported,
          "matching test invocation exited #{summary.red}"
        )

      summary.skipped_tool != nil ->
        claim_result(
          :tests_passed,
          value,
          :unsupported,
          "matching #{summary.skipped_tool} invocation skips tests"
        )

      true ->
        claim_result(
          :tests_passed,
          value,
          :form_mismatch,
          "matched only runs with masked or unanalyzable exit plumbing"
        )
    end
  end

  # A row folds into the tests_passed summary only when it matches the claim
  # AND is a recognized test runner (an echoed command can never match into
  # support).
  defp test_run_summary(value, rows) do
    Enum.reduce(rows, %{matched: false, green: false, red: nil, skipped_tool: nil}, fn row, acc ->
      with true <- test_claim_match?(value, row),
           %Provenance{test_runner: %{} = runner} = prov <- provenance(row) do
        fold_test_row(acc, row, prov, runner)
      else
        _no_match_or_no_runner -> acc
      end
    end)
  end

  defp fold_test_row(acc, row, prov, runner) do
    %{
      matched: true,
      green:
        acc.green or
          (row.exit_code == 0 and prov.exit_code == :preserved and not runner.skipped?),
      red:
        acc.red ||
          if(is_integer(row.exit_code) and row.exit_code != 0, do: row.exit_code),
      skipped_tool: acc.skipped_tool || if(runner.skipped?, do: runner.tool)
    }
  end

  # commands_run: the claim must be contained in the recorded command
  # (claim ⊆ row) — the row may carry plumbing the claim omits, but a claim
  # naming MORE than ran is never supported.
  defp command_claim_match?(value, row) do
    claim = normalize_text(value)
    recorded = normalize_text(row.command)
    claim != "" and (claim == recorded or String.contains?(recorded, claim))
  end

  # tests_passed additionally tolerates the row ⊆ claim direction (the agent
  # may append plumbing or a summary to the invocation it cites); support
  # still requires the ROW to be a test invocation, so an echoed command can
  # never match into support.
  defp test_claim_match?(value, row) do
    claim = normalize_text(value)
    recorded = normalize_text(row.command)

    claim != "" and recorded != "" and
      (claim == recorded or String.contains?(recorded, claim) or
         String.contains?(claim, recorded))
  end

  defp provenance(row), do: ShellCommand.exit_code_provenance(row.command)

  # ---- files_touched (decision 5 + signed 2026-07-09 fingerprint amendment) ----

  defp classify_file_claim(value, changed, fingerprint_changed, repo) do
    case normalize_claim_path(value, repo) do
      {:ok, path} ->
        classify_file_change(value, path, changed, fingerprint_changed)

      :outside ->
        claim_result(:files_touched, value, :skipped, "path outside the repo (cannot verify)")

      :invalid ->
        claim_result(:files_touched, value, :skipped, "unresolvable path (cannot verify)")
    end
  end

  defp classify_file_change(value, path, changed, fingerprint_changed) do
    cond do
      MapSet.member?(changed, path) ->
        claim_result(:files_touched, value, :supported, "path status changed this wave")

      MapSet.member?(fingerprint_changed, path) ->
        claim_result(
          :files_touched,
          value,
          :supported,
          "path content fingerprint changed this wave"
        )

      true ->
        claim_result(
          :files_touched,
          value,
          :unsupported,
          "path did not change this wave (existence alone is not support)"
        )
    end
  end

  # Repo-relative claims normalize directly; absolute claims resolve under
  # `repo` when possible. Traversal (`..`) and paths outside the repo skip —
  # can't verify ⇒ trust, never a positive discrepancy.
  defp normalize_claim_path(value, repo) do
    path =
      value
      |> String.trim()
      |> strip_dot_slash()

    cond do
      path == "" ->
        :invalid

      Path.type(path) == :absolute ->
        relativize(path, repo)

      ".." in Path.split(path) ->
        :outside

      true ->
        {:ok, path}
    end
  end

  defp strip_dot_slash("./" <> rest), do: rest
  defp strip_dot_slash(other), do: other

  defp relativize(_path, repo) when not is_binary(repo), do: :outside

  defp relativize(path, repo) do
    expanded = Path.expand(path)
    root = Path.expand(repo)

    case Path.relative_to(expanded, root) do
      ^expanded -> :outside
      relative -> {:ok, relative}
    end
  end

  defp claim_result(kind, value, status, detail) do
    # Wire-shaped claim record (classify → ledger event + findings); a struct
    # would ripple the JSONB boundary.
    # reach:disable-next-line fixed_shape_map
    %{
      kind: kind,
      value: String.slice(value, 0, @detail_cap),
      status: status,
      detail: detail
    }
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  defp normalize_text(_text), do: ""

  # ---------------------------------------------------------------------------
  # Findings (pure — the ONE synthesis path both slices share)
  # ---------------------------------------------------------------------------

  @doc """
  The stage's positive discrepancies as `{title, location, description}`
  triples — one per claim KIND (not per claim), so the `FindingKey` identity
  (location + title) stays stable across waves while the varying specifics
  (values, exit codes) ride only the description. `:form_mismatch` claims
  deliberately produce nothing here (findings-only-context in v1).
  """
  @spec discrepancies(String.t(), classification()) :: [discrepancy()]
  def discrepancies(stage, %{claims: claims}) do
    claims
    |> Enum.filter(&(&1.status == :unsupported))
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _group} -> Atom.to_string(kind) end)
    |> Enum.map(fn {kind, group} ->
      details =
        Enum.map_join(group, "; ", fn claim -> "#{claim.value} (#{claim.detail})" end)

      # Wire-shaped discrepancy triple (shared with slice 2's assertion path).
      # reach:disable-next-line fixed_shape_map
      %{
        title: title(kind),
        location: "evidence:#{stage}:#{kind}",
        description: String.slice("stage #{stage}: #{details}", 0, @description_cap)
      }
    end)
  end

  defp title(:tests_passed), do: "evidence: claimed test pass unsupported by transcript"
  defp title(:commands_run), do: "evidence: claimed command not backed by transcript"
  defp title(:files_touched), do: "evidence: claimed file change absent from wave diff"

  @doc """
  Synthesize `VerifyStage`-shaped finding maps from discrepancy triples —
  engine findings that ride Hook R (trust-boundary law 2: the deterministic
  verdict never rides an LLM relay). Slice 2's assertion violations feed the
  same path with their own triples.
  """
  @spec findings([discrepancy()]) :: [map()]
  def findings(discrepancies) do
    for discrepancy <- discrepancies do
      %{
        "severity" => "error",
        "title" => discrepancy.title,
        "location" => discrepancy.location,
        "description" => discrepancy.description
      }
    end
  end

  @doc "The fixer-facing action summary line for a set of discrepancy triples."
  @spec action_needed([discrepancy()]) :: String.t()
  def action_needed(discrepancies) do
    locations =
      discrepancies
      |> Enum.map(& &1.location)
      |> Enum.uniq()
      |> Enum.join(", ")

    "evidence claims were contradicted by the engine (#{locations}): redo the " <>
      "claimed work honestly — run tests cleanly (no exit-masking plumbing), " <>
      "report only commands that actually ran and files that actually changed. " <>
      "The engine re-checks every claim against the transcript and bounded wave evidence."
  end
end
