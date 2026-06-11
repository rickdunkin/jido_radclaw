defmodule JidoClaw.Security.Redaction.LogRedactor do
  @moduledoc false

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Security.Redaction.Patterns

  @filter_id :jidoclaw_redact_secrets

  # Standard logger meta keys passed through verbatim — set by the
  # logger itself, never secret-bearing, and often charlists/pids that
  # are pure overhead to walk. :crash_reason is deliberately NOT here:
  # GenServer crash reports carry process state, which is exactly
  # where secrets hide.
  @skip_meta_keys [
    :mfa,
    :file,
    :line,
    :pid,
    :gl,
    :time,
    :domain,
    :application,
    :report_cb,
    :ancestors,
    :callers,
    :registered_name
  ]

  # Containers nested deeper than this below the meta/report root are
  # replaced with "[REDACTED:DEPTH]" — never passed through: deeply
  # nested GenServer state is exactly where secrets hide. Binaries are
  # leaves and redact at any depth.
  @max_meta_depth 4

  # Erlang ~F.P.PadModC control sequences (see io:format/2): optional
  # width (-10, *), precision (.5, .*), pad char (.0, .*), t/l/k
  # modifiers, then the control character — any letter plus the
  # integer-base controls # and +, or ~~ for a literal tilde.
  @format_directive ~r/~(?:[-+]?\d+|\*)?(?:\.(?:\d+|\*)?(?:\.(?:.|\*))?)?[tlk]*(?:[a-zA-Z#+]|~)/

  @spec install!() :: :ok
  def install! do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, {:already_exists, @filter_id}} -> :ok
    end
  end

  @spec filter(:logger.log_event(), keyword()) :: :logger.log_event() | :stop
  def filter(%{msg: message, meta: meta} = event, _config) do
    %{event | msg: redact_message(message), meta: redact_meta(meta)}
  catch
    # A filter that crashes gets removed by :logger — every subsequent
    # event would then pass unredacted. Dropping the one event that
    # broke the walker fails closed instead.
    _kind, _reason -> :stop
  end

  @spec filter(Logger.message(), Logger.level(), Logger.metadata(), keyword()) ::
          Logger.message() | :stop
  def filter(message, _level, _metadata, _config) do
    redact_message(message)
  end

  defp redact_message(message) do
    case message do
      msg when is_binary(msg) ->
        Patterns.redact(msg)

      {:string, msg} ->
        {:string, Patterns.redact(IO.iodata_to_binary(msg))}

      {:report, report} when is_map(report) ->
        {:report, redact_keyed_root(report)}

      {:report, report} when is_list(report) ->
        {:report, redact_report_list(report)}

      {format, args} when is_list(args) ->
        {redact_format(format), walk_list(args, 1)}

      msg when is_list(msg) ->
        Patterns.redact(IO.iodata_to_binary(msg))

      other ->
        other
    end
  end

  # -- meta / report walking ---------------------------------------------------

  defp redact_meta(meta) when is_map(meta), do: redact_keyed_root(meta)
  defp redact_meta(other), do: other

  defp redact_keyed_root(map) when is_map(map) do
    Map.new(map, &redact_root_pair/1)
  end

  defp redact_report_list(report) do
    if Keyword.keyword?(report) do
      Enum.map(report, &redact_root_pair/1)
    else
      walk_list(report, 1)
    end
  end

  defp redact_root_pair({k, v}) do
    cond do
      skip_key?(k) -> {k, v}
      key_sensitive?(k) -> {k, "[REDACTED]"}
      true -> {k, redact_meta_value(v, 1)}
    end
  end

  # Bounded, shape-preserving value walker. `depth` is the nesting
  # depth of `value` below the meta/report root; containers past
  # @max_meta_depth are replaced wholesale (fail closed), leaves are
  # never depth-limited.
  @spec redact_meta_value(term(), pos_integer()) :: term()
  defp redact_meta_value(value, _depth) when is_binary(value), do: redact_binary(value)

  defp redact_meta_value(%mod{} = value, depth) do
    if depth > @max_meta_depth do
      "[REDACTED:DEPTH]"
    else
      fields =
        value
        |> Map.from_struct()
        |> Enum.map(&walk_pair(&1, depth + 1))

      struct(mod, fields)
    end
  end

  defp redact_meta_value(value, depth) when is_map(value) do
    if depth > @max_meta_depth do
      "[REDACTED:DEPTH]"
    else
      Map.new(value, &walk_pair(&1, depth + 1))
    end
  end

  defp redact_meta_value(value, depth) when is_tuple(value) do
    if depth > @max_meta_depth do
      "[REDACTED:DEPTH]"
    else
      value
      |> Tuple.to_list()
      |> Enum.map(&redact_meta_value(&1, depth + 1))
      |> List.to_tuple()
    end
  end

  defp redact_meta_value(value, depth) when is_list(value) do
    cond do
      charlist?(value) -> redact_charlist(value)
      depth > @max_meta_depth -> "[REDACTED:DEPTH]"
      Keyword.keyword?(value) -> Enum.map(value, &walk_pair(&1, depth + 1))
      true -> walk_list(value, depth + 1)
    end
  end

  defp redact_meta_value(value, _depth), do: value

  defp walk_pair({k, v}, depth) do
    if key_sensitive?(k), do: {k, "[REDACTED]"}, else: {k, redact_meta_value(v, depth)}
  end

  # Hand-rolled so improper lists (possible inside crash terms) keep
  # their shape instead of crashing Enum.
  @spec walk_list(term(), pos_integer()) :: term()
  defp walk_list([head | tail], depth),
    do: [redact_meta_value(head, depth) | walk_list(tail, depth)]

  defp walk_list([], _depth), do: []
  defp walk_list(improper_tail, depth), do: redact_meta_value(improper_tail, depth)

  defp key_sensitive?(k) when is_atom(k), do: Env.sensitive_key?(Atom.to_string(k))
  defp key_sensitive?(k) when is_binary(k), do: Env.sensitive_key?(k)
  defp key_sensitive?(_), do: false

  defp skip_key?(k), do: k in @skip_meta_keys

  # Charlists are text leaves like binaries — redacted whole via a
  # binary round-trip (redact_charlist/1), never walked char-by-char,
  # which would mangle them. Hand-rolled to stay safe on improper
  # lists.
  defp charlist?([]), do: true
  defp charlist?([h | t]) when is_integer(h), do: charlist?(t)
  defp charlist?(_), do: false

  # Patterns are unicode regexes; an invalid-UTF8 binary (raw bytes in
  # crash state) would crash them — pass it through instead of taking
  # the whole filter down.
  defp redact_binary(value) do
    if String.valid?(value), do: Patterns.redact(value), else: value
  end

  # A clean no-op returns the original list so benign charlists (and
  # plain integer lists like ~w args) pass byte-identical.
  defp redact_charlist(value) do
    string = List.to_string(value)
    redacted = redact_binary(string)
    if redacted == string, do: value, else: String.to_charlist(redacted)
  rescue
    # Non-codepoint integers (possible inside crash terms) — pass the
    # list through rather than let the raise escape to filter/2's
    # catch, which would drop the whole event.
    _e in [ArgumentError, UnicodeConversionError] -> value
  end

  # -- format-string redaction ---------------------------------------------------

  # Redact only the literal segments between ~F.P.PadModC directives —
  # a directive can't be mangled by construction (the generic
  # `token=value` pattern would otherwise eat a `token=~s` directive).
  defp redact_format(format) when is_binary(format) do
    @format_directive
    |> Regex.split(format, include_captures: true)
    |> Enum.map_join(fn segment ->
      if Regex.match?(@format_directive, segment), do: segment, else: redact_binary(segment)
    end)
  end

  defp redact_format(format) when is_list(format) do
    format
    |> List.to_string()
    |> redact_format()
    |> String.to_charlist()
  rescue
    # Improper/malformed iodata — :io_lib would choke on it anyway;
    # leave it for the handler to deal with.
    _e in [ArgumentError, UnicodeConversionError] -> format
  end

  defp redact_format(format), do: format
end
