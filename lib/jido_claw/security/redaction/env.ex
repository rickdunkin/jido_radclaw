defmodule JidoClaw.Security.Redaction.Env do
  @moduledoc """
  Environment-variable redaction for profile values in logs and
  `/profile current` output, plus the inheritance allowlist for env
  passed to spawned child processes.

  Unlike `JidoClaw.Security.Redaction.Patterns` which scans value strings
  for known secret formats (`sk-...`, `ghp_...`, JWTs), this module
  classifies by *key name* — `DATABASE_PASSWORD=prod-cluster-01` is
  sensitive even though `prod-cluster-01` doesn't match any value
  pattern. Falls through to `Patterns.redact/1` so values with embedded
  API keys still get scrubbed.

  ## Redaction rules (`redact_value/2`, `redact_env/1`)

    * Key name ending in `_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`,
      `_PASS`, `_PAT`, `_CREDENTIAL`, or `_CREDENTIALS`
      (case-insensitive) → whole value masked as `[REDACTED]`.
      Deliberately NOT `_TOKENS`: `input_tokens`/`output_tokens`/
      `total_tokens` are ubiquitous LLM usage counters (same false-
      positive class as `_BASE`); the known plural-secret name
      `ONECLI_AGENT_TOKENS` is matched specifically instead.
    * Bare key name exactly (case-insensitive) `password`, `secret`,
      `token`, `authorization`, or `credential` → whole value masked.
      These carry no suffix but are the canonical shape of secret-bearing
      map keys (e.g. an event/JSON payload `%{"token" => "..."}`). Matched
      *exactly*, not as a substring, so `tokenizer`/`session_id` stay safe.
    * Specific names — `AWS_SECRET_*`, `AWS_SESSION_TOKEN`,
      `AWS_ACCESS_KEY_ID`, `SECRET_KEY_BASE`, `ONECLI_AGENT_TOKENS`,
      `DATABASE_URL`, `DB_URL` → whole value masked (user/host in a
      connection URL can be sensitive on its own).
    * Values matching `scheme://user:pass@host/...` → password segment
      masked, user/scheme/host preserved.
    * Otherwise → pass through `Patterns.redact/1`.

  ## Child-process inheritance (`scrubbed_cmd_env/1`, `scrubbed_port_env/1`)

  Children inherit by *allowlist*, not denylist: every parent var that
  is not explicitly inheritable is unset, so an unconventionally named
  secret (`SECRET_KEY_BASE`, `ONECLI_AGENT_TOKENS`) can't slip through
  on naming alone. Inheritable are:

    * shell/locale ergonomics — `PATH`, `HOME`, `USER`, `LOGNAME`,
      `SHELL`, `TERM`, `COLORTERM`, `LANG`, `LANGUAGE`, `TZ`, `TMPDIR`,
      `EDITOR`, `VISUAL`, `PAGER`, plus any `LC_*` / `XDG_*` var;
    * TLS trust roots — `SSL_CERT_FILE`, `SSL_CERT_DIR`,
      `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`;
    * proxy config — `NO_PROXY`/`no_proxy` unconditionally;
      `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `FTP_PROXY` (and
      lowercase forms) only when the value carries no userinfo — any
      `@` in the authority drops the var, with or without a password
      (`http://user:pass@proxy:8080`, `http://token@proxy:8080`, and
      scheme-less forms); plain `proxy:8080` survives.

  Deliberately NOT inheritable by default — credential-capability vars
  that aren't secret strings themselves but grant auth/signing
  capability to children: `SSH_AUTH_SOCK`, `GPG_TTY`, `GNUPGHOME`.
  Known consequences: SSH-based `git clone` in the resource
  provisioner and GPG-signed git commits stop working until opted back
  in via the extension surfaces below.

  ## Operator extension surfaces

  Extra inheritable names/prefixes are read at call time from:

    * `JIDOCLAW_EXTRA_ALLOWED_ENV_VARS` — comma-separated System env
      var (settable from `.env`), e.g.
      `JIDOCLAW_EXTRA_ALLOWED_ENV_VARS=SSH_AUTH_SOCK,KUBECONFIG`;
    * `config :jido_claw, :extra_allowed_env_vars, ["SSH_AUTH_SOCK"]` —
      app config (exact names);
    * `config :jido_claw, :extra_allowed_env_prefixes, ["MYCO_"]` —
      app config (prefixes).

  An override passed to `scrubbed_cmd_env/1` always wins and bypasses
  the allowlist entirely — a child that genuinely needs a secret must
  be handed it explicitly. The one exception is the hard denylist below:
  denylisted overrides are dropped, not honored.

  ## Hard scrub denylist (`denylisted?/1`)

  A small set of Claude Code host-session vars is denylisted outright:
  `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`,
  `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_SSE_PORT`, plus any
  `CLAUDECODE_*`-prefixed var. When this app itself runs inside a
  Claude Code session these identify the *host* session; a spawned
  `claude` CLI child inheriting them can bind to the wrong session or
  SSE port. Unlike the ordinary scrub they can never be re-opened —
  the operator extension surfaces cannot admit them, and overrides
  carrying them are dropped. Deliberately NOT the whole
  `CLAUDE_CODE_*` namespace: only the session-identity vars are
  fenced; other `CLAUDE_CODE_*` names stay ordinary (scrubbed by
  default, operator-reopenable).

  ## Documented false negatives

  Matching leaves identifier keys like `SESSION_ID`, `USER_ID`,
  `CLIENT_ID` untouched. Over-redacting identifiers that show up in
  legitimate tracing/debugging output is worse than under-redacting for a
  dev tool — the trade-off is explicit.
  """

  alias JidoClaw.Security.Redaction.Patterns

  @sensitive_suffix ~r/_(KEY|TOKEN|SECRET|PASSWORD|PASS|PAT|CREDENTIAL|CREDENTIALS)$/i
  @sensitive_specific ~r/^(AWS_SECRET_.*|AWS_SESSION_TOKEN|AWS_ACCESS_KEY_ID|SECRET_KEY_BASE|ONECLI_AGENT_TOKENS|DATABASE_URL|DB_URL)$/i
  @sensitive_exact ~w(password secret token authorization credential)
  @url_with_creds ~r{(\w+://)([^:@/]+):([^@/]+)(@)}

  @inherit_exact ~w(
    PATH HOME USER LOGNAME SHELL TERM COLORTERM LANG LANGUAGE TZ TMPDIR
    EDITOR VISUAL PAGER
    SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE
    CURL_CA_BUNDLE
    NO_PROXY no_proxy
  )

  @inherit_prefixes ~w(LC_ XDG_)

  # Hard scrub denylist — see the moduledoc section. Exact names plus
  # the CLAUDECODE_ prefix; deliberately NOT all of CLAUDE_CODE_*.
  @scrub_denylist_exact ~w(
    CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH
    CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SSE_PORT
  )
  @scrub_denylist_prefix "CLAUDECODE_"

  # Inherited only when the value carries no credentials — see
  # proxy_value_has_creds?/1.
  @proxy_vars ~w(HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY
                 http_proxy https_proxy all_proxy ftp_proxy)

  @doc """
  Redacts sensitive values in the given env map. Returns a new map with
  the same keys and redacted-or-preserved values.
  """
  @spec redact_env(map()) :: map()
  def redact_env(env) when is_map(env) do
    Enum.into(env, %{}, fn {k, v} -> {k, redact_value(k, v)} end)
  end

  def redact_env(other), do: other

  @doc """
  Redacts a single value based on its key name.

    * Sensitive keys → `[REDACTED]`
    * URL-with-creds values → password segment masked
    * Otherwise → `Patterns.redact/1` (catches embedded API keys)

  Defensive on non-binary values: coerced via `to_string/1` before
  matching so call-sites passing arbitrary terms from logs/signals
  don't crash.
  """
  @spec redact_value(String.t(), String.t() | term()) :: String.t()
  def redact_value(key, value) when is_binary(key) do
    value_str = coerce(value)

    cond do
      sensitive_key?(key) ->
        "[REDACTED]"

      String.match?(value_str, @url_with_creds) ->
        Regex.replace(@url_with_creds, value_str, "\\1\\2:[REDACTED]\\4")

      true ->
        Patterns.redact(value_str)
    end
  end

  def redact_value(_key, value), do: coerce(value)

  @doc """
  `:env` option for `System.cmd` call sites: unsets every currently-set
  parent var that is not on the inheritance allowlist (see the
  moduledoc), then appends the given overrides. An override always wins
  and bypasses the allowlist — a child that genuinely needs a secret
  must be handed it explicitly. Override keys/values are coerced via
  `to_string/1`; an explicit `nil` value still means "unset".

  `Port.open` call sites need `scrubbed_port_env/1` instead — port env
  entries take charlists, and unset is `false` rather than `nil`.
  """
  @spec scrubbed_cmd_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
  def scrubbed_cmd_env(overrides \\ []) do
    override_map =
      overrides
      |> Map.new(fn {k, v} ->
        {to_string(k), if(is_nil(v), do: nil, else: to_string(v))}
      end)
      |> Map.reject(fn {key, _} -> denylisted?(key) end)

    extra_exact = extra_allowed_vars()
    extra_prefixes = extra_allowed_prefixes()

    unsets =
      for {key, value} <- System.get_env(),
          not inheritable?(key, value, extra_exact, extra_prefixes),
          not Map.has_key?(override_map, key),
          do: {key, nil}

    unsets ++ Map.to_list(override_map)
  end

  @doc """
  `:env` option for `Port.open` call sites — same scrub-then-override
  semantics as `scrubbed_cmd_env/1`, shaped for ports: charlist
  keys/values, `false` to unset.
  """
  @spec scrubbed_port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
  def scrubbed_port_env(overrides \\ []) do
    for {k, v} <- scrubbed_cmd_env(overrides) do
      {String.to_charlist(k), if(is_nil(v), do: false, else: String.to_charlist(v))}
    end
  end

  @doc """
  Returns `true` when the given key name matches a sensitive pattern.
  """
  @spec sensitive_key?(String.t()) :: boolean()
  def sensitive_key?(key) when is_binary(key) do
    String.match?(key, @sensitive_suffix) or String.match?(key, @sensitive_specific) or
      String.downcase(key) in @sensitive_exact
  end

  def sensitive_key?(_), do: false

  @doc """
  Returns `true` when the key is on the hard scrub denylist — Claude
  Code host-session vars that must never reach a spawned child, not
  even via the operator extension surfaces or an explicit override.
  See the moduledoc section.
  """
  @spec denylisted?(String.t() | term()) :: boolean()
  def denylisted?(key) when is_binary(key) do
    key in @scrub_denylist_exact or String.starts_with?(key, @scrub_denylist_prefix)
  end

  def denylisted?(_), do: false

  defp inheritable?(key, value, extra_exact, extra_prefixes) do
    cond do
      denylisted?(key) -> false
      key in @inherit_exact -> true
      key in @proxy_vars -> not proxy_value_has_creds?(value)
      String.starts_with?(key, @inherit_prefixes) -> true
      key in extra_exact -> true
      extra_prefixes != [] and String.starts_with?(key, extra_prefixes) -> true
      true -> false
    end
  end

  # Any `@` in the authority (after an optional `scheme://`) is
  # userinfo — token-only `token@host` is as credentialed as
  # `user:pass@host`. Per RFC 3986 the authority ends at the first
  # `/`, `?`, or `#`, so an `@` in the path or query doesn't count.
  defp proxy_value_has_creds?(value) do
    value
    |> strip_scheme()
    |> String.split(["/", "?", "#"], parts: 2)
    |> hd()
    |> String.contains?("@")
  end

  defp strip_scheme(value) do
    case String.split(value, "://", parts: 2) do
      [_scheme, rest] -> rest
      [_] -> value
    end
  end

  defp extra_allowed_vars do
    from_app = Application.get_env(:jido_claw, :extra_allowed_env_vars, [])

    from_system =
      case System.get_env("JIDOCLAW_EXTRA_ALLOWED_ENV_VARS") do
        nil ->
          []

        raw ->
          raw
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    from_app ++ from_system
  end

  defp extra_allowed_prefixes do
    Application.get_env(:jido_claw, :extra_allowed_env_prefixes, [])
  end

  defp coerce(v) when is_binary(v), do: v
  defp coerce(v), do: to_string(v)
end
