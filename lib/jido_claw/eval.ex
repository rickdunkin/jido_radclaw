defmodule JidoClaw.Eval do
  @moduledoc """
  Small deterministic eval runner for the prompt-as-data surface (the
  `Jidoka.Eval` shape, adapted). It adds no new runtime path — every kind's
  `execute` only calls existing production functions; whether those run
  against fake or live capabilities is decided by the caller's environment
  (app-env arming + `run_case/2` opts), never by this module naming a test
  module.

  ## Kinds

    * `:prompt` — `JidoClaw.Agent.SubagentPrompt.build/3`. Request:
      `template`, `tool_context`, optional `stage`. Result: `%{content: _}`.
    * `:schema` — `Jido.AI.Output.parse/2` over a worker module's
      `strategy_opts()[:output]`. Request: `module`, `sample`. Result:
      `%{output: _, parsed: _}`.
    * `:composer` — `JidoClaw.RouteComposer.run_sync/1`. Request: `catalog`
      plus optional seed keys (`live`/`artifacts`/`ran`/`max_waves`,
      conditionally-put so absence stays absence); `tenant`/`actor`/
      `context`/`timeout` come from `run_case/2` opts. Result:
      `%{summary: _}`.
    * `:coherence` — a doctrine slice's prose (`JidoClaw.Doctrine.slice/1`)
      against per-token `Output.parse` probes of a worker schema. Request:
      `slice`, `module`, `field` (path into the string-keyed sample),
      `base_sample`, `tokens`, `non_token`.

  ## Assertions

  Per-kind vocabulary (`:prompt` — `contains`/`not_contains`/`equals`;
  `:schema` — `valid` (`true` = the request sample, or explicit sample(s)) /
  `invalid` / `field_equals` (atom + integer-index paths into the ATOM-keyed
  parsed output); `:composer` — `terminal`/`ran`/`artifact_contains`/
  `artifact_equals` (artifact refs resolved lazily per assertion via
  `ComposerArtifact.resolve_value/2` — the one documented impure evaluator);
  `:coherence` — `prose_contains_tokens` (checks the BACKTICKED token form) /
  `schema_accepts_tokens` / `schema_rejects_non_token`). An unknown assertion
  key fails loudly with an `:unknown_assertion` record — a deliberate
  deviation from jidoka's silent skip, since this harness exists to catch
  drift and a typo must not shrink the assertion set and pass. A known key
  with a malformed value or list item fails via `:invalid_assertion_value`,
  and any raise inside an assertion evaluator fails via `:assertion_raised`
  — a broken assertion always fails the run, never crashes it.
  """

  alias Jido.AI.Output
  alias JidoClaw.Agent.SubagentPrompt
  alias JidoClaw.Doctrine
  alias JidoClaw.Eval.Case, as: EvalCase
  alias JidoClaw.Eval.Run
  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.RouteComposer

  @type case_input :: EvalCase.t() | keyword() | map()

  @known_assertions %{
    prompt: [:contains, :not_contains, :equals],
    schema: [:valid, :invalid, :field_equals],
    composer: [:terminal, :ran, :artifact_contains, :artifact_equals],
    coherence: [:prose_contains_tokens, :schema_accepts_tokens, :schema_rejects_non_token]
  }

  @doc """
  Run one eval case: validate → execute the kind's production function →
  evaluate assertions → build the `Run`. A broken case (a raise inside
  execute, or a composer `{:error, _}`) yields a `status: :error` run rather
  than a crash. Opts: `:id_generator` (case id), `:tenant`/`:actor`/
  `:context`/`:timeout` (composer execution + artifact resolution).
  """
  @spec run_case(case_input(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_case(case_input, opts \\ []) do
    with {:ok, %EvalCase{} = eval_case} <- EvalCase.from_input(case_input, opts) do
      eval_case
      |> execute(opts)
      |> build_run(eval_case, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Execute — one clause per kind, production functions only.
  # ---------------------------------------------------------------------------

  defp execute(%EvalCase{} = eval_case, opts) do
    do_execute(eval_case, opts)
  rescue
    # Total by design: a broken case (missing request key, a module without
    # strategy_opts/0, a production-function raise) must yield a `status: :error`
    # run, never crash the harness — so no exception allowlist can be right here.
    # reach:disable-next-line bare_rescue
    exception ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      {:error, %{reason: :execution_raised, message: Exception.message(exception)}}
  end

  defp do_execute(%EvalCase{kind: :prompt, request: request}, _opts) do
    content =
      SubagentPrompt.build(
        Map.get(request, :template),
        Map.get(request, :tool_context, %{}),
        Map.get(request, :stage)
      )

    {:ok, %{content: content}}
  end

  defp do_execute(%EvalCase{kind: :schema, request: request}, _opts) do
    output = worker_output(Map.fetch!(request, :module))
    {:ok, %{output: output, parsed: Output.parse(output, Map.get(request, :sample))}}
  end

  defp do_execute(%EvalCase{kind: :composer, request: request}, opts) do
    # Optional seed keys are conditionally-put: an explicit `live: []` differs
    # from absence on the run_sync side, so absence must stay absence.
    seed_opts =
      Enum.flat_map([:live, :artifacts, :ran, :max_waves], fn key ->
        case Map.fetch(request, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    run_opts =
      [catalog: Map.fetch!(request, :catalog)] ++
        seed_opts ++ Keyword.take(opts, [:tenant, :actor, :context, :timeout])

    with {:ok, summary} <- RouteComposer.run_sync(run_opts) do
      {:ok, %{summary: summary}}
    end
  end

  defp do_execute(%EvalCase{kind: :coherence, request: request}, _opts) do
    output = worker_output(Map.fetch!(request, :module))
    field = Map.fetch!(request, :field)
    base_sample = Map.fetch!(request, :base_sample)
    tokens = Map.fetch!(request, :tokens)
    non_token = Map.fetch!(request, :non_token)

    token_results =
      Enum.map(tokens, fn token ->
        {token, Output.parse(output, put_path(base_sample, field, token))}
      end)

    {:ok,
     %{
       prose: Doctrine.slice(Map.fetch!(request, :slice)),
       tokens: tokens,
       token_results: token_results,
       non_token: non_token,
       non_token_result: Output.parse(output, put_path(base_sample, field, non_token))
     }}
  end

  defp worker_output(module), do: Keyword.fetch!(module.strategy_opts(), :output)

  # Replace an existing value in the string-keyed input sample. Total only over
  # paths that already exist — `Map.update!` raises on a typo'd key and the
  # list clause raises on an out-of-range index (`List.update_at` would
  # silently no-op into a falsely-green probe), so a wrong path becomes a loud
  # `:error` run instead of a weakly-passing one.
  defp put_path(_container, [], value), do: value

  defp put_path(container, [key | rest], value) when is_map(container) do
    Map.update!(container, key, &put_path(&1, rest, value))
  end

  defp put_path(container, [index | rest], value)
       when is_list(container) and is_integer(index) do
    len = length(container)

    if index >= 0 and index < len do
      List.update_at(container, index, &put_path(&1, rest, value))
    else
      raise ArgumentError, "put_path list index #{index} out of range (list length #{len})"
    end
  end

  # ---------------------------------------------------------------------------
  # Evaluate — assertion records; unknown keys fail loudly.
  # ---------------------------------------------------------------------------

  defp evaluate(%EvalCase{kind: kind, assertions: assertions}, result, opts) do
    known = Map.fetch!(@known_assertions, kind)

    Enum.flat_map(assertions, fn {key, value} ->
      if key in known do
        apply_assertion_safely(kind, key, value, result, opts)
      else
        [record(:unknown_assertion, false, known, key)]
      end
    end)
  end

  # Totality net for the evaluate half, mirroring `execute`'s: any raise inside
  # an assertion evaluator (an unanticipated value shape, a non-binary token,
  # the impure artifact resolution) must fail the run as a record, never crash
  # the caller — so no exception allowlist can be right here either.
  defp apply_assertion_safely(kind, key, value, result, opts) do
    apply_assertion(kind, key, value, result, opts)
  rescue
    # reach:disable-next-line bare_rescue
    exception ->
      # credo:disable-for-previous-line ExSlop.Check.Warning.RescueWithoutReraise
      [record(:assertion_raised, false, key, Exception.message(exception))]
  end

  defp apply_assertion(:prompt, :contains, expected, %{content: content}, _opts) do
    expected
    |> List.wrap()
    |> Enum.map(fn needle ->
      found? = is_binary(needle) and String.contains?(content, needle)
      record(:contains, found?, needle, content)
    end)
  end

  defp apply_assertion(:prompt, :not_contains, expected, %{content: content}, _opts) do
    expected
    |> List.wrap()
    |> Enum.map(fn needle ->
      absent? = is_binary(needle) and not String.contains?(content, needle)
      record(:not_contains, absent?, needle, content)
    end)
  end

  defp apply_assertion(:prompt, :equals, expected, %{content: content}, _opts) do
    [record(:equals, content == expected, expected, content)]
  end

  # `valid: true` asserts the request's own (already-parsed) sample.
  defp apply_assertion(:schema, :valid, true, result, _opts) do
    [record(:valid, match?({:ok, _}, result.parsed), :accepted, result.parsed)]
  end

  defp apply_assertion(:schema, :valid, samples, result, _opts) do
    parse_samples(samples, result.output, :valid, :accepted, &match?({:ok, _}, &1))
  end

  defp apply_assertion(:schema, :invalid, samples, result, _opts) do
    parse_samples(samples, result.output, :invalid, :rejected, &match?({:error, _}, &1))
  end

  defp apply_assertion(:schema, :field_equals, pairs, result, _opts) when is_list(pairs) do
    Enum.map(pairs, &field_equals_record(&1, result))
  end

  defp apply_assertion(:composer, :terminal, expected, %{summary: summary}, _opts) do
    [record(:terminal, summary.terminal == expected, expected, summary.terminal)]
  end

  defp apply_assertion(:composer, :ran, expected, %{summary: summary}, _opts) do
    expected
    |> List.wrap()
    |> Enum.map(fn stage ->
      record(:ran, MapSet.member?(summary.ran, stage), stage, Enum.sort(summary.ran))
    end)
  end

  defp apply_assertion(:composer, key, triples, %{summary: summary}, opts)
       when key in [:artifact_contains, :artifact_equals] and is_list(triples) do
    Enum.map(triples, &artifact_record(key, &1, summary, opts))
  end

  # Every canonical token is authored backticked in the doctrine files; a raw
  # substring match would weakly pass on prose like "token / time cost".
  defp apply_assertion(:coherence, :prose_contains_tokens, true, result, _opts) do
    Enum.map(result.tokens, fn token ->
      backticked = "`" <> token <> "`"

      record(
        :prose_contains_tokens,
        String.contains?(result.prose, backticked),
        backticked,
        result.prose
      )
    end)
  end

  defp apply_assertion(:coherence, :schema_accepts_tokens, true, result, _opts) do
    Enum.map(result.token_results, fn {token, parsed} ->
      record(:schema_accepts_tokens, match?({:ok, _}, parsed), token, parsed)
    end)
  end

  defp apply_assertion(:coherence, :schema_rejects_non_token, true, result, _opts) do
    rejected? = match?({:error, _}, result.non_token_result)
    [record(:schema_rejects_non_token, rejected?, result.non_token, result.non_token_result)]
  end

  # A known key with a malformed value must not silently pass either.
  defp apply_assertion(_kind, key, value, _result, _opts) do
    [record(:invalid_assertion_value, false, key, value)]
  end

  defp parse_samples(samples, output, name, expected, accept?) do
    samples
    |> List.wrap()
    |> Enum.map(fn sample ->
      parsed = Output.parse(output, sample)
      record(name, accept?.(parsed), expected, parsed)
    end)
  end

  # Per-item mirror of the whole-value `:invalid_assertion_value` catch-all:
  # a malformed list item (a non-tuple, a tuple with a non-list path) must fail
  # its own record, never crash the map with a FunctionClauseError.
  defp field_equals_record({path, expected}, result) when is_list(path) do
    actual =
      case result.parsed do
        {:ok, parsed} -> get_in(parsed, access_path(path))
        {:error, _} = error -> error
      end

    record(:field_equals, actual == expected, %{path: path, value: expected}, actual)
  end

  defp field_equals_record(other, _result),
    do: record(:invalid_assertion_value, false, :field_equals, other)

  # Parsed worker output carries ATOM keys; integer path segments index lists.
  defp access_path(path) do
    Enum.map(path, fn
      index when is_integer(index) -> Access.at(index)
      key -> key
    end)
  end

  defp artifact_record(key, {name, producer, value}, summary, opts) do
    actual = resolve_artifact(summary, name, producer, opts)

    record(
      key,
      artifact_matches?(key, actual, value),
      %{artifact: name, producer: producer, value: value},
      actual
    )
  end

  # A malformed triple fails its own record before any artifact resolution.
  defp artifact_record(key, other, _summary, _opts),
    do: record(:invalid_assertion_value, false, key, other)

  # The one documented impure evaluator: `summary.artifacts[name][producer]`
  # holds a REF; resolve it lazily per assertion, tenant/actor from opts.
  defp resolve_artifact(summary, name, producer, opts) do
    with ref when is_binary(ref) <-
           get_in(summary.artifacts, [name, producer]) || {:error, :artifact_missing},
         {:ok, value} <-
           ComposerArtifact.resolve_value(ref, Keyword.take(opts, [:tenant, :actor])) do
      value
    end
  end

  defp artifact_matches?(:artifact_contains, actual, needle),
    do: is_binary(actual) and String.contains?(actual, needle)

  defp artifact_matches?(:artifact_equals, actual, value), do: actual == value

  defp record(name, passed?, expected, actual) do
    %{name: name, status: assertion_status(passed?), expected: expected, actual: actual}
  end

  defp assertion_status(true), do: :passed
  defp assertion_status(false), do: :failed

  defp build_run({:ok, result}, %EvalCase{} = eval_case, opts) do
    assertions = evaluate(eval_case, result, opts)
    status = if Enum.all?(assertions, &(&1.status == :passed)), do: :passed, else: :failed

    Run.new(
      case_id: eval_case.id,
      kind: eval_case.kind,
      status: status,
      result: result,
      assertions: assertions,
      observations: observations(eval_case.kind, result, assertions),
      metadata: eval_case.metadata
    )
  end

  defp build_run({:error, reason}, %EvalCase{} = eval_case, _opts) do
    Run.new(
      case_id: eval_case.id,
      kind: eval_case.kind,
      status: :error,
      error: normalize_error(reason),
      metadata: eval_case.metadata
    )
  end

  defp normalize_error(%{reason: _} = error), do: error
  defp normalize_error(reason), do: %{reason: reason}

  defp observations(:prompt, result, _assertions) do
    %{prompt_bytes: byte_size(result.content)}
  end

  defp observations(:schema, result, assertions) do
    %{
      sample_parsed_ok: match?({:ok, _}, result.parsed),
      valid_samples: count_records(assertions, :valid),
      invalid_samples: count_records(assertions, :invalid)
    }
  end

  defp observations(:composer, result, _assertions) do
    summary = result.summary

    %{
      terminal: summary.terminal,
      ran: Enum.sort(summary.ran),
      artifact_names: Enum.sort(Map.keys(summary.artifacts)),
      waves: summary.wave_index
    }
  end

  defp observations(:coherence, result, _assertions) do
    %{token_count: length(result.tokens), prose_bytes: byte_size(result.prose)}
  end

  defp count_records(assertions, name), do: Enum.count(assertions, &(&1.name == name))
end
