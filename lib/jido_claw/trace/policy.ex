defmodule JidoClaw.Trace.Policy do
  @moduledoc """
  Trace redaction + sampling policy, as plain data.

  `JidoClaw.Trace.Collector` snapshots one `%Policy{}` at init (the MapSet
  construction is too costly per-event) and threads it through ingest:
  `scrub/2` cleans every `:measurements`/`:metadata` payload before it
  reaches the ring or `trace_events`, and `keep_trace?/2` decides whether
  a trace is ingested at all.

  ## Redaction — curated floor + central-stack reuse

  Key classification is a **hybrid**. The curated lists carried on the
  struct (`omit_keys`, `redact_exact`, `redact_contains`, `redact_suffixes`)
  are the **floor** — they default to the exact values the trace subsystem
  has always used, so there is zero redaction regression for existing keys.
  In particular the 7 unseparated compound forms (`apikey`, `authtoken`,
  `privatekey`, `accesskey`, `bearer`, `apisecret`, `clientsecret`) are kept
  here because they are neither bare-exact nor suffix-matchable by the
  central stack. On top of that floor, key classification also unions in
  `JidoClaw.Security.Redaction.Env.sensitive_key?/1`, so evolving central
  coverage (`authorization`, `credential`, the `_PAT`/`_CREDENTIAL(S)`
  suffixes, …) applies to traces too.

  This is the only trace redactor that reuses the central
  `JidoClaw.Security.Redaction` stack, matching `OutputRedaction` /
  `LogRedactor`.

  ## Value scrubbing — an intentional stricter default

  Beyond key-name redaction, every binary **leaf value** that is not
  omitted or key-redacted is run through
  `JidoClaw.Security.Redaction.Patterns.redact/1` first. This newly catches
  secrets embedded inside an otherwise-benign string value
  (`note: "Bearer sk-ant-…"`) that key-only redaction misses — including
  values nested inside tuples (`outcome: {:error, "Bearer sk-ant-…"}`). It
  is `redact`-then-validate, never validate-then-redact: validating first
  would let an ASCII secret inside an invalid binary pass unscrubbed. The
  cost is one regex sweep per string leaf, which is acceptable on a bounded
  personal deployment.

  Precedence matches the historical `cond`: **omit** > **redact** >
  value-scrub.

  ## Serialization safety + exotic leaves

  `scrub/2` also guarantees the payload is safe for the `measurements` /
  `metadata` jsonb columns:

    * structs are reduced via `Map.from_struct/1` and key-redacted (NOT
      `inspect/1`'d — that would render `%Foo{token: "secret"}` raw);
    * tuples become **scrubbed lists** (jsonb has no tuple encoding, and
      this also closes the tuple-nested secret leak above);
    * pids, funs, refs, and ports are `inspect/1`'d to strings;
    * a binary that is still invalid UTF-8 after redaction is `inspect/1`'d.

  ## Sampling — deterministic, per-trace, keep-all by default

  `keep_trace?/2` hashes the trace key with `:erlang.phash2/2` and keeps it
  when `phash2(key, 100) < round(sample_rate * 100)`. The decision is
  **per-trace** (a trace is wholly kept or wholly dropped) and a pure
  deterministic function of the key, so the Collector recomputes it each
  event with no drop-cache to grow unbounded. `sample_rate: 1.0` keeps
  everything (a no-op vs the historical behavior); `0.0` drops everything.

  ## Configuration

  `from_config/1` reads the `:jido_claw, :trace` block. `sample_rate`
  accepts an integer or float and is clamped to `[0.0, 1.0]` (garbage ⇒
  `1.0`). `extra_omit_keys` / `extra_redact_keys` are additive-only key
  lists (atoms or mixed-case strings, normalized to lowercased strings and
  `MapSet.union`-ed onto the built-ins) — they can extend coverage but can
  never un-redact a built-in.
  """

  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Security.Redaction.Patterns

  # Kept as plain lists (not compile-time MapSet literals): a literal MapSet
  # attribute passed to a MapSet function reads as a transparent term and
  # trips Dialyzer's opacity check, so every MapSet here is built at runtime
  # via `MapSet.new/1`.
  @default_omit_keys ~w(
    arguments content context data input llm_opts messages output params
    prompt query raw raw_request raw_response request request_opts response
    result stacktrace state text thinking_content
  )

  @default_redact_exact ~w(
    api_key apikey password secret token auth_token authtoken private_key
    privatekey access_key accesskey bearer api_secret apisecret client_secret
    clientsecret
  )

  @default_redact_contains ["secret_"]
  @default_redact_suffixes ["_secret", "_key", "_token", "_password"]

  defstruct sample_rate: 1.0,
            omit_keys: MapSet.new(@default_omit_keys),
            redact_exact: MapSet.new(@default_redact_exact),
            redact_contains: @default_redact_contains,
            redact_suffixes: @default_redact_suffixes

  @type t :: %__MODULE__{
          sample_rate: float(),
          omit_keys: MapSet.t(String.t()),
          redact_exact: MapSet.t(String.t()),
          redact_contains: [String.t()],
          redact_suffixes: [String.t()]
        }

  @doc """
  Returns the default policy: keep-all sampling and the built-in curated
  redaction lists, with no operator extensions applied.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Builds a policy from a `:jido_claw, :trace` config (keyword or map).

  Reads `sample_rate` (clamped) and the additive `extra_omit_keys` /
  `extra_redact_keys` lists; the suffix/substring rules keep their
  built-in defaults.
  """
  @spec from_config(keyword() | map()) :: t()
  def from_config(config) do
    %__MODULE__{
      sample_rate: normalize_sample_rate(config_get(config, :sample_rate, 1.0)),
      omit_keys: union_keys(@default_omit_keys, config_get(config, :extra_omit_keys, [])),
      redact_exact: union_keys(@default_redact_exact, config_get(config, :extra_redact_keys, []))
    }
  end

  @doc """
  Recursively scrubs a payload: omits large keys, redacts sensitive keys,
  value-scrubs embedded secrets in string leaves, and normalizes exotic
  leaves (structs, tuples, pids/funs/refs/ports, invalid binaries) into a
  jsonb-safe shape.
  """
  @spec scrub(t(), term()) :: term()
  def scrub(%__MODULE__{} = p, value) when is_struct(value),
    do: scrub(p, Map.from_struct(value))

  def scrub(%__MODULE__{} = p, %{} = map), do: Map.new(map, &scrub_pair(p, &1))
  def scrub(%__MODULE__{} = p, list) when is_list(list), do: Enum.map(list, &scrub(p, &1))

  def scrub(%__MODULE__{} = p, tuple) when is_tuple(tuple),
    do: Enum.map(Tuple.to_list(tuple), &scrub(p, &1))

  def scrub(%__MODULE__{}, value) when is_binary(value) do
    redacted = Patterns.redact(value)
    if String.valid?(redacted), do: redacted, else: inspect(redacted)
  end

  def scrub(%__MODULE__{}, value)
      when is_pid(value) or is_function(value) or is_reference(value) or is_port(value),
      do: inspect(value)

  def scrub(%__MODULE__{}, value), do: value

  @doc """
  Returns `true` when a trace with the given key should be ingested.

  Deterministic per-key: the same `key` + `sample_rate` always yields the
  same answer, so a kept trace's later events still ingest and a dropped
  trace's events drop consistently.
  """
  @spec keep_trace?(t(), term()) :: boolean()
  def keep_trace?(%__MODULE__{sample_rate: rate}, key) do
    :erlang.phash2(key, 100) < round(rate * 100)
  end

  # -- redaction helpers ------------------------------------------------------

  defp scrub_pair(p, {key, value}) do
    cond do
      omit_key?(p, key) -> {key, "[OMITTED]"}
      redact_key?(p, key) -> {key, "[REDACTED]"}
      true -> {key, scrub(p, value)}
    end
  end

  defp omit_key?(p, key) when is_atom(key), do: omit_key?(p, Atom.to_string(key))

  defp omit_key?(p, key) when is_binary(key),
    do: MapSet.member?(p.omit_keys, String.downcase(key))

  defp omit_key?(_p, _key), do: false

  defp redact_key?(p, key) when is_atom(key), do: redact_key?(p, Atom.to_string(key))

  defp redact_key?(p, key) when is_binary(key) do
    downcased = String.downcase(key)

    MapSet.member?(p.redact_exact, downcased) or
      Enum.any?(p.redact_contains, &String.contains?(downcased, &1)) or
      Enum.any?(p.redact_suffixes, &String.ends_with?(downcased, &1)) or
      Env.sensitive_key?(key)
  end

  defp redact_key?(_p, _key), do: false

  # -- config helpers ---------------------------------------------------------

  defp config_get(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_get(config, key, default) when is_map(config), do: Map.get(config, key, default)
  defp config_get(_config, _key, default), do: default

  defp normalize_sample_rate(rate) when is_integer(rate), do: normalize_sample_rate(rate * 1.0)
  defp normalize_sample_rate(rate) when is_float(rate) and rate < 0.0, do: 0.0
  defp normalize_sample_rate(rate) when is_float(rate) and rate > 1.0, do: 1.0
  defp normalize_sample_rate(rate) when is_float(rate), do: rate
  defp normalize_sample_rate(_rate), do: 1.0

  # Additive union, built in one runtime `MapSet.new/1` from the default
  # list plus the normalized extras (avoids a literal-MapSet opacity trip).
  defp union_keys(default_list, extra) when is_list(extra) do
    extra
    |> Enum.map(&normalize_key/1)
    |> Enum.concat(default_list)
    |> MapSet.new()
  end

  defp union_keys(default_list, _extra), do: MapSet.new(default_list)

  defp normalize_key(key), do: String.downcase(to_string(key))
end
