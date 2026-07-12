defmodule JidoClaw.Forge.RecoveredSpec do
  @moduledoc false
  # AR-8b-2 F2 (1.4): re-atomize a jsonb-recovered Forge start spec's known
  # fields before it reaches the Harness, which reads ATOM keys AND atom values
  # (`resolve_client(Map.get(spec, :sandbox, :default))`, `Map.get(spec,
  # :sandbox_spec, %{})`). The whole start spec is persisted as jsonb
  # (`Persistence.session_attrs/2` → `redact_map/1`), so on read-back atom keys
  # AND atom values become strings: a stored `%{sandbox: :docker_sandbox, …}`
  # reads as `%{"sandbox" => "docker_sandbox", …}`. Unnormalized, the Harness
  # misses the atom key and falls to `:default` (HostShell) with an EMPTY
  # `sandbox_spec` — a silent fail-OPEN to no isolation, no `--network none`, no
  # mount, on the exact boundary this tier enforces.
  #
  # LATENT today (exec-only F2 sessions never checkpoint, so `wake/2` returns
  # `{:error, :no_checkpoint}` and Manager auto-recovery never reads the spec
  # back), but hardened centrally so a future checkpoint can't open the hole.
  #
  # Faithful, NOT over-broad (review P2): the harness legitimately supports
  # generic Docker specs and attached sandboxes with network BY DESIGN, so this
  # does NOT force `network: :none`/`isolate_global_config` onto every recovered
  # `:docker_sandbox` spec — the F2 markers are restored ONLY if they were
  # persisted, and a generic Docker spec recovers as-is. Fail CLOSED (`{:error,
  # _}`, never silent `:default`/HostShell) on an un-normalizable shape or an
  # invalid mount entry.

  # Fixed whitelists — the only place a stored string becomes an atom (no
  # `String.to_atom/1` on arbitrary input). Both `sandbox` and `runner` map a
  # known wire value; an unknown value falls back to `String.to_existing_atom/1`
  # ONLY when the atom is validated as a real backend (resp. runner) MODULE
  # (covers a persisted module atom like `"Elixir.JidoClaw.Forge.Sandbox.Docker"`),
  # and fails closed otherwise. An existing but WRONG-KIND atom (`:ok`, `Enum`) is
  # rejected, not passed through — a blind existing-atom fallback would admit it
  # and crash later at `resolve_client`/`resolve_runner`'s `is_atom` catch-all
  # (`:ok.create/1` / `runner_module.init/2`).
  alias JidoClaw.Forge.Sandbox

  @sandbox_atoms %{
    "default" => :default,
    "host_shell" => :host_shell,
    "local" => :local,
    "fake" => :fake,
    "docker_sandbox" => :docker_sandbox
  }

  @runner_atoms %{
    "shell" => :shell,
    "claude_code" => :claude_code,
    "codex" => :codex,
    "workflow" => :workflow,
    "custom" => :custom,
    "fake" => :fake
  }

  @doc """
  Normalize a recovered (or already-atom-keyed) start spec. An atom-keyed spec
  (a live launch, never round-tripped) passes its known fields through unchanged;
  a string-keyed (jsonb-recovered) spec has its `sandbox`/`sandbox_spec`/`runner`
  keys + the `sandbox`/`runner` values + the nested `sandbox_spec` markers
  (`extra_mounts`, `network`, `isolate_global_config`, `workdir`) re-atomized.
  A `config_codec`-stamped `runner_config` additionally decodes through the
  versioned whitelist codec (`runner_config/1`) — typed out, refuse-on-missing
  for the security-critical fields; an unstamped `runner_config` is left
  untouched (the legacy/non-vendor lane).

  Both `sandbox` and `runner` map a known wire string, else fall back to an
  existing atom ONLY when it is validated as a real backend (resp. runner)
  module; an existing-but-wrong-kind atom (`:ok`, `Enum`) is rejected, not passed
  through. Returns `{:ok, spec}` or `{:error, reason}` (fail closed) on an
  un-normalizable `sandbox`/`runner` value, an invalid `extra_mounts` entry, or
  an undecodable stamped `runner_config`.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(spec) when is_map(spec) do
    with {:ok, sandbox} <- normalize_sandbox(get(spec, :sandbox)),
         {:ok, sandbox_spec} <- normalize_sandbox_spec(get(spec, :sandbox_spec)),
         {:ok, runner} <- normalize_runner(get(spec, :runner)),
         {:ok, runner_config} <- normalize_runner_config(get(spec, :runner_config)) do
      normalized =
        spec
        |> drop_keys(["sandbox", "sandbox_spec", "runner", :sandbox, :sandbox_spec, :runner])
        |> put_present(:sandbox, sandbox)
        |> put_present(:sandbox_spec, sandbox_spec)
        |> put_present(:runner, runner)
        |> put_decoded_runner_config(runner_config)

      {:ok, normalized}
    end
  end

  def normalize(_other), do: {:error, :invalid_recovered_spec}

  # ---------------------------------------------------------------------------
  # Versioned runner-config codec (docs/system/forge-session-resume.md)
  #
  # The session-start path persists ONLY materialized static runner config
  # (every default written explicitly by the runner's `materialize_config/1`),
  # stamped with `codec_stamp/1`. This codec is the read side: string-keyed
  # jsonb in, typed (atom keys, whitelisted atom values) out — so a recovered
  # session re-inits with EXACTLY its persisted posture, never a re-applied
  # default that may have drifted (the consolidator omits `access`; a
  # defaulting decode would flip recovered sessions from :full to whatever
  # the runner's default became).
  # ---------------------------------------------------------------------------

  @codec_version 1

  # Per-runner v1 field whitelists: {field, kind}. Anything else — including
  # attempt-scoped values like a tokenized MCP URL or a per-attempt config
  # path — is dropped by construction.
  @claude_code_fields [
    access: :access,
    config_sync: :config_sync,
    strict_mcp: :boolean,
    allowed_mcp_tools: :string_list,
    add_dirs: :string_list,
    prompt: :string,
    model: :string,
    session_name: :string,
    thinking_effort: :string,
    forge_home: :string,
    max_turns: :pos_integer,
    timeout_ms: :pos_integer,
    resume: :resume
  ]

  @codex_fields [
    access: :access,
    config_sync: :config_sync,
    prompt: :string,
    model: :string,
    session_name: :string,
    forge_home: :string,
    codex_home: :string,
    mcp_server_name: :string,
    cwd: :string,
    max_turns: :pos_integer,
    timeout_ms: :pos_integer,
    resume: :resume
  ]

  # Security-critical fields: missing or invalid ⇒ REFUSE recovery loudly —
  # never silently change a recovered session's behavior in either direction.
  # (The fourth member of the security set, the sandbox class, lives at the
  # spec level and is enforced by `normalize_sandbox/1`'s fail-closed path.)
  # Non-critical fields fall to runner-init defaults when ABSENT, but an
  # invalid present value always refuses.
  @claude_code_required [:access, :config_sync, :strict_mcp, :allowed_mcp_tools]
  @codex_required [:access, :config_sync]

  @codecs %{
    "claude_code" => {@claude_code_fields, @claude_code_required},
    "codex" => {@codex_fields, @codex_required}
  }

  @doc """
  The codec stamp `materialize_config/1` implementations embed in their
  output — the marker that a persisted `runner_config` is a complete
  materialized snapshot decodable by `runner_config/1`. Wire-stable
  strings, never atoms.
  """
  @spec codec_stamp(:claude_code | :codex) :: map()
  def codec_stamp(:claude_code), do: %{runner: "claude_code", v: @codec_version}
  def codec_stamp(:codex), do: %{runner: "codex", v: @codec_version}

  @doc """
  Versioned per-runner whitelist decode of a persisted `runner_config`.

  A `config_codec`-stamped map decodes string-keyed → typed (atom keys,
  whitelisted atom values — `String.to_atom/1` never runs), REQUIRING the
  security-critical fields and refusing loudly (`{:error, _}`) when one is
  missing or invalid, when the stamp names an unknown runner, or when the
  version is unsupported. The decoded output keeps the stamp, so a
  recovered spec re-persisted by the recovery claim decodes again on the
  next recovery. An UNSTAMPED map passes through unchanged — the
  legacy/non-vendor lane (shell/workflow/custom/fake); vendor sessions are
  guaranteed stamped at session start, where materialization is enforced.
  """
  @spec runner_config(map()) :: {:ok, map()} | {:error, term()}
  def runner_config(config) when is_map(config) do
    case codec_stamp_of(config) do
      :absent -> {:ok, config}
      {:ok, runner_key} -> decode_runner_config(runner_key, config)
      {:error, reason} -> {:error, reason}
    end
  end

  def runner_config(other), do: {:error, {:invalid_runner_config, other}}

  defp codec_stamp_of(config) do
    case get(config, :config_codec) do
      nil ->
        :absent

      %{} = stamp ->
        validate_stamp(get(stamp, :runner), get(stamp, :v))

      other ->
        {:error, {:invalid_config_codec, other}}
    end
  end

  defp validate_stamp(runner_key, @codec_version) when is_map_key(@codecs, runner_key),
    do: {:ok, runner_key}

  defp validate_stamp(runner_key, version),
    do: {:error, {:unsupported_config_codec, runner_key, version}}

  defp decode_runner_config(runner_key, config) do
    {fields, required} = Map.fetch!(@codecs, runner_key)
    stamp = %{runner: runner_key, v: @codec_version}

    Enum.reduce_while(fields, {:ok, %{config_codec: stamp}}, fn {field, kind}, {:ok, acc} ->
      case get(config, field) do
        nil ->
          if field in required do
            {:halt, {:error, {:missing_runner_config_field, runner_key, field}}}
          else
            {:cont, {:ok, acc}}
          end

        value ->
          case decode_value(kind, value) do
            {:ok, typed} -> {:cont, {:ok, Map.put(acc, field, typed)}}
            :error -> {:halt, {:error, {:invalid_runner_config_field, runner_key, field}}}
          end
      end
    end)
  end

  # Value whitelists tolerate the already-typed atom form too (a decoded
  # config re-persisted and re-read mid-recovery, or a live spec passed
  # through normalize) — but never manufacture atoms from wire strings.
  defp decode_value(:access, v), do: enum_value(v, %{"full" => :full, "read_only" => :read_only})

  defp decode_value(:config_sync, v),
    do: enum_value(v, %{"full" => :full, "auth_only" => :auth_only})

  defp decode_value(:resume, v), do: enum_value(v, %{"off" => :off, "armed" => :armed})
  defp decode_value(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp decode_value(:string, v) when is_binary(v), do: {:ok, v}
  defp decode_value(:pos_integer, v) when is_integer(v) and v > 0, do: {:ok, v}

  defp decode_value(:string_list, v) when is_list(v) do
    if Enum.all?(v, &is_binary/1), do: {:ok, v}, else: :error
  end

  defp decode_value(_kind, _v), do: :error

  defp enum_value(v, whitelist) when is_binary(v), do: Map.fetch(whitelist, v)

  defp enum_value(v, whitelist) when is_atom(v) do
    if v in Map.values(whitelist), do: {:ok, v}, else: :error
  end

  defp enum_value(_v, _whitelist), do: :error

  defp normalize_runner_config(nil), do: {:ok, nil}

  defp normalize_runner_config(config) when is_map(config) do
    case codec_stamp_of(config) do
      # Unstamped pass-through: leave the spec's key form untouched.
      :absent ->
        {:ok, :passthrough}

      {:ok, runner_key} ->
        with {:ok, typed} <- decode_runner_config(runner_key, config) do
          {:ok, {:decoded, typed}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_runner_config(other), do: {:error, {:invalid_runner_config, other}}

  defp put_decoded_runner_config(spec, nil), do: spec
  defp put_decoded_runner_config(spec, :passthrough), do: spec

  defp put_decoded_runner_config(spec, {:decoded, typed}) do
    spec
    |> drop_keys(["runner_config", :runner_config])
    |> Map.put(:runner_config, typed)
  end

  # Atom-or-string key read (the `Verdict.get/2` idiom): atom key wins, else
  # string key — tolerates both an already-atom-keyed launch spec and a
  # string-keyed recovered one.
  defp get(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp normalize_sandbox(value),
    do: normalize_atom(value, @sandbox_atoms, :unrecognized_sandbox, &sandbox_module?/1)

  defp normalize_runner(value),
    do: normalize_atom(value, @runner_atoms, :unrecognized_runner, &runner_module?/1)

  # Whitelist a known wire string → fall back to a validated existing atom → else
  # fail closed. The `nil`/`is_atom` clauses pass a trusted live-launch spec
  # through unchanged (only the binary *recovered* path is validated).
  defp normalize_atom(nil, _map, _tag, _valid?), do: {:ok, nil}
  defp normalize_atom(value, _map, _tag, _valid?) when is_atom(value), do: {:ok, value}

  defp normalize_atom(value, map, tag, valid?) when is_binary(value) do
    case Map.get(map, value) do
      nil -> safe_existing_atom(value, tag, valid?)
      atom -> {:ok, atom}
    end
  end

  defp normalize_atom(other, _map, tag, _valid?), do: {:error, {tag, other}}

  # A persisted MODULE atom (`"Elixir.JidoClaw.Forge.Sandbox.Docker"`) re-atomizes
  # only if it already exists AND is the right kind of module; an existing but
  # wrong-kind atom (`:ok`, `Enum`) fails closed (never silently `:default`, never
  # a late `is_atom` catch-all crash at `resolve_client`/`resolve_runner`).
  defp safe_existing_atom(value, tag, valid?) do
    atom = String.to_existing_atom(value)
    if valid?.(atom), do: {:ok, atom}, else: {:error, {tag, value}}
  rescue
    ArgumentError -> {:error, {tag, value}}
  end

  # Per-kind module validators — check the behaviour's FULL non-optional callback
  # set (a coincidental module exporting every required callback at the exact
  # arity is effectively impossible; a real backend exports them all). The
  # "required" set is precisely `behaviour callbacks − @optional_callbacks`. One
  # shared export-checking helper keeps both predicates one-liners (no clone),
  # using the subsystem's `function_exported?/3` idiom (`sandbox.ex:30`) with
  # `Code.ensure_loaded?/1` first to avoid a false-negative on a not-yet-loaded
  # backend during recovery.
  defp module_with_exports?(mod, exports) do
    Code.ensure_loaded?(mod) and
      Enum.all?(exports, fn {f, a} -> function_exported?(mod, f, a) end)
  end

  # Runner required callbacks (runner.ex; @optional_callbacks :33 excludes
  # handle_output/3, terminate/2, serialize_state/1, restore_state/2). Harness
  # calls these three UNGUARDED (:346 init, :472 run_iteration, :541 apply_input).
  defp runner_module?(mod),
    do: module_with_exports?(mod, [{:init, 2}, {:run_iteration, 3}, {:apply_input, 3}])

  # Sandbox.Behaviour required callbacks (behaviour.ex; @optional_callbacks :28
  # excludes impl_module/0, run/4). Docker + StubSandbox export all of these.
  defp sandbox_module?(mod),
    do:
      module_with_exports?(mod, [
        {:create, 1},
        {:exec, 3},
        {:exec_argv, 4},
        {:spawn, 4},
        {:write_file, 3},
        {:read_file, 2},
        {:inject_env, 2},
        {:destroy, 2}
      ])

  defp normalize_sandbox_spec(nil), do: {:ok, nil}

  defp normalize_sandbox_spec(ss) when is_map(ss) do
    with {:ok, mounts} <- normalize_extra_mounts(get(ss, :extra_mounts)),
         {:ok, allow_network} <- normalize_allow_network(get(ss, :allow_network)) do
      normalized =
        ss
        |> drop_keys([
          "extra_mounts",
          "network",
          "allow_network",
          "isolate_global_config",
          "workdir",
          :extra_mounts,
          :network,
          :allow_network,
          :isolate_global_config,
          :workdir
        ])
        |> put_present(:extra_mounts, mounts)
        |> put_present(:network, normalize_network(get(ss, :network)))
        |> put_present(:allow_network, allow_network)
        |> put_present(:isolate_global_config, normalize_bool(get(ss, :isolate_global_config)))
        |> put_present(:workdir, normalize_workdir(get(ss, :workdir)))

      {:ok, normalized}
    end
  end

  defp normalize_sandbox_spec(_other), do: {:error, :invalid_sandbox_spec}

  # `allow_network` entries become a `sbx policy` CSV at the backend — the
  # same strict `host[:port]` shape rule (`Docker.valid_network_host?/1`)
  # applies to a jsonb-recovered list, fail closed otherwise. Never atomized:
  # the values stay the strings they were persisted as.
  defp normalize_allow_network(nil), do: {:ok, nil}

  defp normalize_allow_network(hosts) when is_list(hosts) do
    if Enum.all?(hosts, &Sandbox.Docker.valid_network_host?/1),
      do: {:ok, hosts},
      else: {:error, {:invalid_allow_network, hosts}}
  end

  defp normalize_allow_network(other), do: {:error, {:invalid_allow_network, other}}

  # Validate each mount entry but KEEP its shape (string-keyed map or tuple) — the
  # single map→tuple conversion lives at the harness boundary
  # (`Harness.build_sandbox_spec`/1.5). Fail closed on a malformed entry.
  defp normalize_extra_mounts(nil), do: {:ok, nil}

  defp normalize_extra_mounts(mounts) when is_list(mounts) do
    reduced =
      Enum.reduce_while(mounts, {:ok, []}, fn entry, {:ok, acc} ->
        if valid_mount?(entry),
          do: {:cont, {:ok, [entry | acc]}},
          else: {:halt, {:error, {:invalid_mount_spec, entry}}}
      end)

    case reduced do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  defp normalize_extra_mounts(_other), do: {:error, :invalid_extra_mounts}

  defp valid_mount?(%{"host" => h, "container" => c, "mode" => m})
       when is_binary(h) and is_binary(c) and is_binary(m),
       do: true

  defp valid_mount?({h, c, m}) when is_binary(h) and is_binary(c) and is_binary(m), do: true
  defp valid_mount?(_entry), do: false

  defp normalize_network(:none), do: :none
  defp normalize_network("none"), do: :none
  # A generic Docker spec may carry another network value by design — pass it
  # through (the backend only honors `:none`); only `nil` is dropped.
  defp normalize_network(nil), do: nil
  defp normalize_network(other), do: other

  defp normalize_bool(true), do: true
  defp normalize_bool(_other), do: nil

  defp normalize_workdir(value) when is_binary(value), do: value
  defp normalize_workdir(_other), do: nil

  defp drop_keys(map, keys), do: Map.drop(map, keys)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
