defmodule JidoClaw.Tools.OutputShaper do
  @moduledoc """
  Format-aware, reversible compression of verbose tool output.

  Sits between `OutputRedaction` and `OutputLimit` in the shared tool
  pipeline (`JidoClaw.Tools.Action`): redaction must see the full
  original (shaping is a form of truncation), and `OutputLimit` stays as
  the dumb backstop. The rule that keeps shaping safe: **compress the
  green, never the red** — success noise becomes counts; error detail
  stays verbatim.

  Corollary invariant: the shaper never hands `OutputLimit` something
  it would cut. Anything bound for the model that exceeds the inline
  cap — an oversized shaped body, or all-signal output too big to pass
  through — is stored under a ref and bounded to the cap by head+tail
  elision (`Generic.fit/2`) with the ref footer intact, because the
  backstop's ref-less head-cut would silently drop the tail where
  failures live.

  Shaping is reversible: the full captured text is stored under a ref
  (`JidoClaw.Conversations.ToolOutput`, via `OutputShaper.Store`) and
  retrievable through the `fetch_output` tool, so the agent never has to
  re-run a command to recover dropped detail. Two degradation modes:

    * **No tenant in scope** — storage is deterministically impossible,
      so the shaper passes through entirely (`shapeable?/3` guard).
    * **Transient store failure** — the one documented exception:
      output is shaped without a ref (footer says "full output
      unavailable"). The shaped body still carries the red verbatim;
      passing a 512KB capture through would let `OutputLimit`'s 32KB
      head-cut drop the failures at the tail, which is strictly worse.

  `shapeable?/3` is deliberately cheap and side-effect-free — a pure
  read of config + params + context. `RunCommand` calls it **before**
  execution (the capture decision) and this module calls it again after
  (the shaping decision), so capture and shaping can never disagree.
  """

  # Containment boundary: shaping (and its Trace emits) must NEVER turn a
  # good tool result into a crash — any internal fault hands the original
  # result back, so the rescues are deliberately catch-all.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Security.Redaction.Patterns
  alias JidoClaw.Shell.SessionManager
  alias JidoClaw.Tools.OutputLimit
  alias JidoClaw.Tools.OutputShaper.Generic
  alias JidoClaw.Tools.OutputShaper.GitDiff
  alias JidoClaw.Tools.OutputShaper.MixCompile
  alias JidoClaw.Tools.OutputShaper.MixTest
  alias JidoClaw.Tools.OutputShaper.Parsed
  alias JidoClaw.Tools.OutputShaper.Store

  # Allowlist: tool name → the result-map text field the shaper acts on.
  # Everything else (including fetch_output — the recursion guard) passes
  # through untouched.
  @shapeable_tools %{"run_command" => :output, "git_diff" => :diff}

  # CSI (colors, cursor), OSC (titles, hyperlinks), then remaining
  # two-byte ESC sequences — in that order, so ESC-[ / ESC-] are consumed
  # as CSI/OSC starts before the generic rule sees them.
  @ansi_csi ~r/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/
  @ansi_osc ~r/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?/
  @ansi_two_byte ~r/\x1b[\x40-\x5f]/

  # OutputLimit's truncation marker, anchored to the end of the text —
  # a substring scan would false-positive on real output that merely
  # mentions the phrase.
  @output_limit_marker ~r/\[tool output truncated: original \d+ bytes, cap \d+ bytes\]\s*\z/

  @config_defaults [
    enabled?: true,
    min_shape_bytes: 2_048,
    capture_bytes: 512 * 1024,
    ref_ttl_days: 7,
    failures_budget_bytes: 24 * 1024,
    generic_head_bytes: 2_048,
    generic_tail_bytes: 4_096
  ]

  # Raw-dispatch callers can hand tools string-keyed params (validated and
  # MCP-atomized paths arrive atom-keyed). Normalize the keys the shaper
  # reads ONCE at the public entry points so everything downstream uses
  # atom keys only. Fixed key set — no user-controlled atom creation.
  @string_param_keys %{
    "command" => :command,
    "staged" => :staged,
    "path" => :path,
    "stream_to_display" => :stream_to_display
  }

  # -- Config accessors --------------------------------------------------------

  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled?)

  @spec min_shape_bytes() :: pos_integer()
  def min_shape_bytes, do: config(:min_shape_bytes)

  @spec capture_bytes() :: pos_integer()
  def capture_bytes, do: config(:capture_bytes)

  @spec ref_ttl_days() :: pos_integer()
  def ref_ttl_days, do: config(:ref_ttl_days)

  @spec failures_budget_bytes() :: pos_integer()
  def failures_budget_bytes, do: config(:failures_budget_bytes)

  @spec generic_head_bytes() :: pos_integer()
  def generic_head_bytes, do: config(:generic_head_bytes)

  @spec generic_tail_bytes() :: pos_integer()
  def generic_tail_bytes, do: config(:generic_tail_bytes)

  defp config(key) do
    :jido_claw
    |> Application.get_env(:output_shaping, [])
    |> Keyword.get(key, @config_defaults[key])
  end

  # -- Predicates ---------------------------------------------------------------

  @doc """
  True when the streaming request will actually stream: requested via
  `stream_to_display` AND not running under MCP serve-mode (where the
  request is dropped — stdio framing). The raw param alone would wrongly
  skip capture+shaping for MCP callers whose streaming request gets
  dropped.
  """
  @spec effective_streaming?(map()) :: boolean()
  def effective_streaming?(params) when is_map(params) do
    requested? = Map.get(normalize_params(params), :stream_to_display) == true

    requested? and Application.get_env(:jido_claw, :serve_mode) != :mcp
  end

  @doc """
  True when this tool call's output should be captured large and shaped.

  Cheap and side-effect-free by contract — called both by `RunCommand`
  before execution (capture sizing) and by `shape_result/4` afterwards.
  Requires: shaping enabled, tool on the allowlist, not effectively
  streaming, and a tenant in `tool_context` (without one, storage is
  deterministically impossible and shaping would always violate
  reversibility).
  """
  @spec shapeable?(String.t(), map(), map() | nil) :: boolean()
  def shapeable?(tool_name, params, context) when is_map(params) do
    enabled?() and
      Map.has_key?(@shapeable_tools, tool_name) and
      not effective_streaming?(params) and
      tenant_present?(context)
  end

  def shapeable?(_tool_name, _params, _context), do: false

  defp tenant_present?(%{tool_context: %{tenant_id: tenant_id}})
       when is_binary(tenant_id) and tenant_id != "",
       do: true

  defp tenant_present?(_), do: false

  # -- Pipeline stage -----------------------------------------------------------

  @doc """
  Shape a tool result. Pass-through for everything except an allowlisted
  tool's successful result whose text field clears `min_shape_bytes/0`.
  Errors (2- and 3-tuple) are never touched; `effects` are preserved.
  Any internal failure returns the original result unchanged.
  """
  @spec shape_result(term(), String.t(), map(), map() | nil) :: term()
  def shape_result(result, tool_name, params, context) do
    if shapeable?(tool_name, params, context) do
      safe_shape(result, tool_name, params, context)
    else
      result
    end
  end

  defp safe_shape(result, tool_name, params, context) do
    do_shape(result, tool_name, normalize_params(params), context)
  rescue
    e ->
      Logger.warning("[OutputShaper] shaping #{tool_name} raised: #{Exception.message(e)}")
      emit_error_trace(tool_name, e)
      result
  end

  defp do_shape({:ok, map}, tool, params, ctx) when is_map(map) and not is_struct(map) do
    {:ok, shape_map(map, tool, params, ctx)}
  end

  defp do_shape({:ok, map, effects}, tool, params, ctx)
       when is_map(map) and not is_struct(map) do
    {:ok, shape_map(map, tool, params, ctx), effects}
  end

  defp do_shape(other, _tool, _params, _ctx), do: other

  defp shape_map(map, tool, params, ctx) do
    field = Map.fetch!(@shapeable_tools, tool)
    text = Map.get(map, field)

    if is_binary(text) and needs_shaping?(text) do
      shape_text(map, field, text, tool, params, ctx)
    else
      map
    end
  end

  # min_shape_bytes is only a noise floor. When the inline cap is
  # configured below it, sub-floor output that OutputLimit would cut
  # must still be shaped — skipping it would reintroduce the ref-less
  # truncation the shaper exists to prevent.
  defp needs_shaping?(text) do
    byte_size(text) >= min_shape_bytes() or byte_size(text) > OutputLimit.max_bytes()
  end

  defp shape_text(map, field, text, tool, params, ctx) do
    # ANSI escapes can interrupt a secret (`sk-\e[0m...`) so the upstream
    # OutputRedaction pass may have missed it — stripping reassembles it.
    # Re-redacting the stripped text is mandatory before it is parsed,
    # shaped, or stored.
    clean =
      text
      |> strip_ansi()
      |> Patterns.redact()

    truncated? = upstream_truncated?(clean)
    format = detect_format(tool, params)

    # Passthrough emits the raw `text` (not `clean`), so the
    # would-OutputLimit-cut-it gate downstream must be on `text`'s size.
    case shaped_body(clean, format, truncated?, byte_size(text)) do
      :passthrough ->
        JidoClaw.Telemetry.emit_shaping(tool, format, 0)
        map

      {body, summary, used_format} ->
        finish_shape(
          map,
          field,
          %{
            text: text,
            clean: clean,
            body: body,
            summary: summary,
            format: used_format,
            truncated?: truncated?
          },
          tool,
          params,
          ctx
        )
    end
  end

  # `shaping` keys: :text (original field value), :clean (stripped +
  # re-redacted), :body (parser output), :summary, :format, :truncated?.
  defp finish_shape(map, field, shaping, tool, params, ctx) do
    %{text: text, clean: clean, body: body, summary: summary, truncated?: truncated?} = shaping

    tc = tool_context(ctx)
    command = command_for(tool, params)
    captured_bytes = byte_size(clean)
    delta = delta_line(tool, summary, command, tc)

    store_attrs = %{
      tool: tool,
      command: command,
      content: clean,
      byte_size: captured_bytes,
      truncated: truncated?,
      exit_code: exit_code_of(map),
      summary: summary
    }

    {ref, footer} =
      case Store.put(store_attrs, tc) do
        {:ok, ref} -> {ref, footer_line(ref, captured_bytes, truncated?)}
        :error -> {nil, "\n\n(full output unavailable)"}
      end

    # An oversized shaped body (huge first failure block, unbounded diff
    # stat header, all-signal output routed here) must never reach
    # OutputLimit — its blind head-cut would drop the tail AND the
    # footer carrying the ref. Bound it to the cap ourselves; storage
    # above already holds the full `clean`, so nothing is lost. If
    # delta+footer alone exceed the cap (pathological config), accept
    # OutputLimit as the final net — the ref exists, so it's recoverable.
    budget = OutputLimit.max_bytes() - byte_size(delta) - byte_size(footer)

    bounded =
      case Generic.fit(body, max(budget, 0)) do
        {:ok, fitted} -> fitted
        :nocompress -> body
      end

    output = delta <> bounded <> footer
    bytes_saved = max(byte_size(text) - byte_size(output), 0)

    JidoClaw.Telemetry.emit_shaping(tool, shaping.format, bytes_saved)
    emit_shaped_trace(tool, shaping.format, ref, captured_bytes, byte_size(output), bytes_saved)

    map
    |> Map.put(field, output)
    |> Map.put(:shaped, true)
    |> Map.put(:captured_bytes, captured_bytes)
    |> Map.put(:truncated, truncated?)
    |> put_present(:output_ref, ref)
    |> put_present(:summary, summary)
  end

  # -- Body selection -----------------------------------------------------------

  # Upstream-truncated input never reaches a format parser: the signal a
  # parser keys on (summary lines) may describe only the surviving head,
  # so counts would be fabricated. Generic head+tail is the honest shape.
  defp shaped_body(clean, _format, true, original_size),
    do: generic_or_passthrough(clean, original_size)

  defp shaped_body(clean, :mix_test, false, original_size) do
    dispatch_parsed(
      MixTest.parse(clean, failures_budget_bytes()),
      clean,
      :mix_test,
      original_size
    )
  end

  defp shaped_body(clean, :mix_compile, false, original_size) do
    dispatch_parsed(MixCompile.parse(clean), clean, :mix_compile, original_size)
  end

  defp shaped_body(clean, :git_diff, false, original_size) do
    dispatch_parsed(
      GitDiff.parse(clean, failures_budget_bytes()),
      clean,
      :git_diff,
      original_size
    )
  end

  defp shaped_body(clean, :generic, false, original_size),
    do: generic_or_passthrough(clean, original_size)

  # `compressed?: false` means the format matched but the body is
  # all-signal (mostly verbatim failures/warnings) — head+tail would cut
  # red detail, so the original passes through when `OutputLimit` can
  # carry it whole. Above the inline cap passthrough is the worse cut
  # (ref-less head-only): shape it anyway — ref stored, body bounded in
  # `finish_shape/6`. `:nomatch` means not really this format — generic
  # is the honest fallback.
  defp dispatch_parsed(
         {:ok, %Parsed{compressed?: true, body: body, summary: summary}},
         _clean,
         fmt,
         _original_size
       ) do
    {body, summary, fmt}
  end

  defp dispatch_parsed(
         {:ok, %Parsed{compressed?: false, body: body, summary: summary}},
         _clean,
         fmt,
         original_size
       ) do
    passthrough_unless_oversized(body, summary, fmt, original_size)
  end

  defp dispatch_parsed(:nomatch, clean, _fmt, original_size),
    do: generic_or_passthrough(clean, original_size)

  defp generic_or_passthrough(clean, original_size) do
    case Generic.head_tail(clean, generic_head_bytes(), generic_tail_bytes()) do
      {:ok, body} -> {body, nil, :generic}
      :nocompress -> passthrough_unless_oversized(clean, nil, :generic, original_size)
    end
  end

  defp passthrough_unless_oversized(body, summary, fmt, original_size) do
    if original_size > OutputLimit.max_bytes() do
      {body, summary, fmt}
    else
      :passthrough
    end
  end

  # -- Format detection ---------------------------------------------------------

  defp detect_format("git_diff", _params), do: :git_diff

  defp detect_format("run_command", params) do
    command = command_for("run_command", params) || ""

    cond do
      Regex.match?(~r/^\s*(\w+=\S+\s+)*mix\s+test\b/, command) -> :mix_test
      Regex.match?(~r/^\s*(\w+=\S+\s+)*mix\s+compile\b/, command) -> :mix_compile
      true -> :generic
    end
  end

  defp detect_format(_tool, _params), do: :generic

  # Params are normalized to atom keys at the public entry points.
  defp command_for("run_command", params), do: Map.get(params, :command)

  # git_diff has no command param — reconstruct the canonical invocation
  # so fingerprints key per-tool comparisons consistently.
  defp command_for("git_diff", params) do
    flags = [
      if(Map.get(params, :staged) == true, do: "--cached"),
      case Map.get(params, :path) do
        path when is_binary(path) -> "-- #{path}"
        _ -> nil
      end
    ]

    Enum.join(["git diff" | Enum.reject(flags, &is_nil/1)], " ")
  end

  defp command_for(_tool, _params), do: nil

  defp normalize_params(params) when is_map(params) do
    Enum.reduce(@string_param_keys, params, fn {string_key, atom_key}, acc ->
      case Map.fetch(acc, string_key) do
        {:ok, value} -> Map.put_new(Map.delete(acc, string_key), atom_key, value)
        :error -> acc
      end
    end)
  end

  # -- Previous-run delta -------------------------------------------------------

  # Compare this run's failure set with the latest stored run of the same
  # command in the same session. Best-effort: any miss or failure yields
  # the empty string. Runs BEFORE Store.put so the lookup can't see the
  # row we're about to insert.
  defp delta_line("run_command", %{failures: current}, command, tc)
       when is_list(current) and is_binary(command) do
    with session_uuid when is_binary(session_uuid) and session_uuid != "" <-
           Map.get(tc, :session_uuid),
         fingerprint when is_binary(fingerprint) <- Store.fingerprint(command),
         {:ok, row} <- Store.latest_for_fingerprint(session_uuid, fingerprint, "run_command", tc),
         prior when is_list(prior) <- prior_failures(row) do
      build_delta(prior, current)
    else
      _ -> ""
    end
  end

  defp delta_line(_tool, _summary, _command, _tc), do: ""

  defp prior_failures(%{summary: %{} = summary}) do
    case Map.get(summary, "failures") do
      failures when is_list(failures) -> failures
      _ -> nil
    end
  end

  defp prior_failures(_row), do: nil

  defp build_delta(prior, current) do
    prior_keys = MapSet.new(prior, &failure_key/1)
    current_keys = MapSet.new(current, &failure_key/1)

    cond do
      MapSet.size(prior_keys) == 0 and MapSet.size(current_keys) == 0 ->
        ""

      MapSet.equal?(prior_keys, current_keys) ->
        n = MapSet.size(current_keys)
        "↻ same #{n} failure#{plural(n)} as previous run\n"

      true ->
        new_count = MapSet.size(MapSet.difference(current_keys, prior_keys))
        new_note = if new_count > 0, do: " (#{new_count} new)", else: ""

        "↻ failures changed: was #{MapSet.size(prior_keys)}, now #{MapSet.size(current_keys)}" <>
          new_note <> "\n"
    end
  end

  # Identity spans the atom-keyed current summary and the string-keyed
  # JSONB round-trip of the prior one.
  defp failure_key(%{test: test, location: location}), do: {test, location}
  defp failure_key(%{"test" => test} = failure), do: {test, Map.get(failure, "location")}
  defp failure_key(other), do: other

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # -- Helpers ------------------------------------------------------------------

  @doc false
  @spec strip_ansi(binary()) :: binary()
  def strip_ansi(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@ansi_csi, &1, ""))
    |> then(&Regex.replace(@ansi_osc, &1, ""))
    |> then(&Regex.replace(@ansi_two_byte, &1, ""))
  end

  # Exact suffix matches against the known markers — real output could
  # contain the phrase mid-stream. SessionManager owns its note strings
  # (`SessionManager.truncation_note/1`), so marker-text drift breaks at
  # one definition site instead of silently disabling detection.
  defp upstream_truncated?(text) do
    String.ends_with?(text, SessionManager.truncation_note(false)) or
      String.ends_with?(text, SessionManager.truncation_note(true)) or
      Regex.match?(@output_limit_marker, text)
  end

  defp footer_line(ref, bytes, false) do
    "\n\n[full output: #{bytes} bytes — fetch_output ref=#{ref}]"
  end

  # The ref holds what was *captured*, which above the capture cap is
  # not everything — the hint stays honest about that.
  defp footer_line(ref, bytes, true) do
    "\n\n[captured output (upstream-truncated): #{bytes} bytes — fetch_output ref=#{ref}]"
  end

  defp exit_code_of(%{exit_code: exit_code}) when is_integer(exit_code), do: exit_code
  defp exit_code_of(_map), do: nil

  defp tool_context(%{tool_context: tc}) when is_map(tc), do: tc
  defp tool_context(_ctx), do: %{}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp emit_shaped_trace(tool, format, ref, captured_bytes, shaped_bytes, bytes_saved) do
    JidoClaw.Trace.emit(
      :output,
      %{event: :shaped, name: tool, format: format, ref: ref},
      %{bytes_saved: bytes_saved, captured_bytes: captured_bytes, shaped_bytes: shaped_bytes}
    )
  rescue
    _ -> :ok
  end

  defp emit_error_trace(tool, error) do
    JidoClaw.Trace.emit(
      :output,
      %{event: :error, name: tool, stage: :shape, reason: Exception.message(error)},
      %{system_time: System.system_time()}
    )
  rescue
    _ -> :ok
  end
end
