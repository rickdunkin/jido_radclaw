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

  Both `sandbox` and `runner` map a known wire string, else fall back to an
  existing atom ONLY when it is validated as a real backend (resp. runner)
  module; an existing-but-wrong-kind atom (`:ok`, `Enum`) is rejected, not passed
  through. Returns `{:ok, spec}` or `{:error, reason}` (fail closed) on an
  un-normalizable `sandbox`/`runner` value or an invalid `extra_mounts` entry.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(spec) when is_map(spec) do
    with {:ok, sandbox} <- normalize_sandbox(get(spec, :sandbox)),
         {:ok, sandbox_spec} <- normalize_sandbox_spec(get(spec, :sandbox_spec)),
         {:ok, runner} <- normalize_runner(get(spec, :runner)) do
      normalized =
        spec
        |> drop_keys(["sandbox", "sandbox_spec", "runner", :sandbox, :sandbox_spec, :runner])
        |> put_present(:sandbox, sandbox)
        |> put_present(:sandbox_spec, sandbox_spec)
        |> put_present(:runner, runner)

      {:ok, normalized}
    end
  end

  def normalize(_other), do: {:error, :invalid_recovered_spec}

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
    with {:ok, mounts} <- normalize_extra_mounts(get(ss, :extra_mounts)) do
      normalized =
        ss
        |> drop_keys([
          "extra_mounts",
          "network",
          "isolate_global_config",
          "workdir",
          :extra_mounts,
          :network,
          :isolate_global_config,
          :workdir
        ])
        |> put_present(:extra_mounts, mounts)
        |> put_present(:network, normalize_network(get(ss, :network)))
        |> put_present(:isolate_global_config, normalize_bool(get(ss, :isolate_global_config)))
        |> put_present(:workdir, normalize_workdir(get(ss, :workdir)))

      {:ok, normalized}
    end
  end

  defp normalize_sandbox_spec(_other), do: {:error, :invalid_sandbox_spec}

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
