# Patch for jido_action — Jido.Exec (compile-time GENERATOR, not a copy)
#
# Compile-time patched build of jido_action 2.3.1 `Jido.Exec`, portions
# Copyright 2026 Mike Hostetler, Apache-2.0 — see
# priv/licenses/jido_action-APACHE-2.0.txt and the section 4(b) notice in
# priv/licenses/jido_action-NOTICE.txt. Modified by JidoClaw: the two
# map-wrap arms of `handle_action_result/4` gain `maybe_mark_wrap/3` +
# `canonical_envelope?/1` (+ the `__jido_claw_patch_info__/0` build marker).
# The hunk strings below ARE the prominent modified-file record.
#
# WHY: `Jido.Exec`'s map-wrap of a tool error is lossy — post-wrap, the
# exact wrap of a canonical `{code, message, details}` envelope and any
# hand-built native error whose details happen to carry `:code` + `:details`
# are byte-identical, so the served-MCP error boundary's tier-1 selection
# ("this IS our envelope, report its domain code") rested on a forgeable
# shape. The fork stamps an opt-provided per-call reference into the wrap's
# details — ONLY when the pre-wrap reason itself matched the raw
# canonical-envelope contract — giving the boundary a witness it detaches on
# exact ref identity (see JidoClaw.MCPServer.ErrorBoundary). Every exec
# caller that passes no opt (agent loop, skills, consolidator, deposit) is
# byte-identical to upstream by construction.
#
# WHY A GENERATOR (docs/exploration/pms/pad/PORT-PD1-2-EXEC.md — the signed
# semantics map for this port):
#   - Stacktrace byte fidelity: `handle_action_exception/4` embeds
#     `__STACKTRACE__` — with `Jido.Exec` file/line frames — into error
#     details the served surface's content[0] renders. Compiling the patched
#     source under the SAME file string the dep's own compilation recorded
#     in its line annotations ("lib/jido_action/exec.ex", empirically
#     confirmed from a raised frame) with line-count-preserving hunks keeps
#     no-opt raise-path errors rendering byte-identical to the unpatched
#     world. (`module_info(:compile)[:source]` differs — it records an
#     absolute path — but that string is never wire-rendered.)
#   - Parity by construction: an accidental edit anywhere else in the 889
#     upstream lines (retry, timeout, async, compensation) is structurally
#     impossible; the generator IS the reconstruction a committed copy would
#     need a separate guard for.
#
# The produced BEAM's durable incremental-build owner is
# Mix.Tasks.Compile.JidoclawReleasePatches: on EVERY compile it verifies the
# app-side `Elixir.Jido.Exec.beam` carries `@jido_claw_patch_info` with the
# CURRENT pins (upstream sha AND patch revision) and regenerates otherwise —
# a deps rebuild or hunk edit can never leave boot force-load, tests, or
# releases silently running upstream (or an outdated fork) `Jido.Exec`.
# Boot force-load + release BEAM relocation are driven by
# `JidoClaw.Core.DependencyPatches.patched_modules/0` (`{Jido.Exec,
# :jido_action}`). Remove once jido_action stamps wrap provenance natively
# or exposes a result-normalization seam (2.3.1's `:error_normalization`
# opt is accepted-and-ignored, so none exists today).
defmodule JidoClaw.Core.JidoExecPatch do
  @moduledoc false

  alias Jido.Exec

  @project_root Path.expand("../../..", __DIR__)
  @upstream_source_rel "deps/jido_action/lib/jido_action/exec.ex"

  # Recompile this generator (re-arming the drift gate below) whenever the
  # dep source changes.
  @external_resource Path.join(@project_root, @upstream_source_rel)

  # sha256 of the pinned upstream source (jido_action 2.3.1). A jido_action
  # bump or local deps edit fails COMPILATION via the gate below, before any
  # test runs.
  @pinned_upstream_sha256 "1eab8f18204b605038a87932edc34903c9149a5ef57cf5382749432ceb640752"

  # The file string the dep's own compilation recorded in its line
  # annotations (dep-root-relative; stacktrace frames render exactly this).
  @compile_file_string "lib/jido_action/exec.ex"

  # The two surgical hunks — exact-string, LINE-COUNT-PRESERVING, each
  # asserted to match exactly once. `_opts` -> `opts` on the arm heads (opts
  # are already threaded to handle_action_result/4 upstream) and the wrap
  # call marks the details. The exception pass-through arms and everything
  # else stay verbatim.
  @hunk_wrap_3tuple_old """
    defp handle_action_result({:error, reason, other}, action, log_level, _opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {message, details} = extract_error_fields(reason)
      {:error, Error.execution_error(message, details), other}
    end
  """

  @hunk_wrap_3tuple_new """
    defp handle_action_result({:error, reason, other}, action, log_level, opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {message, details} = extract_error_fields(reason)
      {:error, Error.execution_error(message, maybe_mark_wrap(details, reason, opts)), other}
    end
  """

  @hunk_wrap_2tuple_old """
    defp handle_action_result({:error, reason}, action, log_level, _opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {message, details} = extract_error_fields(reason)
      {:error, Error.execution_error(message, details)}
    end
  """

  @hunk_wrap_2tuple_new """
    defp handle_action_result({:error, reason}, action, log_level, opts) do
      Telemetry.cond_log_error(log_level, action, reason)
      {message, details} = extract_error_fields(reason)
      {:error, Error.execution_error(message, maybe_mark_wrap(details, reason, opts))}
    end
  """

  @wrap_arm_hunks [
    {@hunk_wrap_3tuple_old, @hunk_wrap_3tuple_new},
    {@hunk_wrap_2tuple_old, @hunk_wrap_2tuple_new}
  ]

  # Appended AFTER the last upstream definition, before the terminal `end` —
  # no upstream definition shifts lines. %UPSTREAM_SHA256%/%PATCH_REVISION%
  # interpolate at generation time.
  @helper_block_template """

    # ── JidoClaw patch block (appended by lib/jido_claw/core/jido_exec_patch.ex;
    # everything above this comment is verbatim jido_action 2.3.1 source) ──

    Module.register_attribute(__MODULE__, :jido_claw_patch_info, persist: true)

    @jido_claw_patch_info [
      upstream_sha256: "%UPSTREAM_SHA256%",
      patch_revision: "%PATCH_REVISION%"
    ]

    @doc false
    @spec __jido_claw_patch_info__() :: keyword()
    def __jido_claw_patch_info__, do: @jido_claw_patch_info

    # PATCH: stamp the caller's per-call wrap-provenance ref into the wrap's
    # details — the served-MCP boundary's tier-1 witness (it detaches the key
    # on exact ref identity; see JidoClaw.MCPServer.ErrorBoundary). Stamped
    # ONLY when the pre-wrap reason matched the raw canonical-envelope
    # contract — the witness attests "exec wrapped a canonical envelope",
    # never merely "exec wrapped a map" (a non-exception struct with
    # colliding message/code/details fields extracts to the same details
    # shape and must stay unstamped -> native tier). Map.put_new, NEVER
    # Map.put: a producer squatting the key must keep its junk value so the
    # boundary's identity check refuses, the term stays byte-identical to
    # the unpatched world, and the error falls to the native tier (mis-tier
    # DOWN, the safe direction). No opt (every non-served exec caller) =>
    # byte-identical behavior by construction.
    defp maybe_mark_wrap(details, reason, opts) do
      case Keyword.get(opts, :jido_claw_wrap_provenance) do
        token when is_reference(token) ->
          if canonical_envelope?(reason) do
            Map.put_new(details, :__jido_claw_exec_wrapped__, token)
          else
            details
          end

        _absent_or_junk ->
          details
      end
    end

    defp canonical_envelope?(%{code: code, message: message, details: details} = reason)
         when not is_struct(reason) and is_atom(code) and is_binary(message) and
                is_map(details),
         do: true

    defp canonical_envelope?(_reason), do: false
  """

  # Patch revision: a digest over the generator's inputs (hunks + helper
  # template). Paired with the upstream sha in the build marker so an old
  # persisted BEAM can't pass the incremental-build owner after the hunks or
  # helper change while jido_action stays pinned.
  @patch_inputs [
    @helper_block_template
    | Enum.flat_map(@wrap_arm_hunks, fn {old, new} -> [old, new] end)
  ]
  @patch_revision Base.encode16(
                    :crypto.hash(:sha256, Enum.join(@patch_inputs, "\n<<hunk>>\n")),
                    case: :lower
                  )

  # ── Compile-time drift gate ──────────────────────────────────────────────
  # Runs when THIS file compiles; @external_resource above re-arms it on any
  # dep-source change, so a jido_action bump fails compilation loudly.
  current_upstream_sha =
    Base.encode16(
      :crypto.hash(:sha256, File.read!(Path.join(@project_root, @upstream_source_rel))),
      case: :lower
    )

  if current_upstream_sha != @pinned_upstream_sha256 do
    raise """
    jido_action's exec.ex has drifted from the pinned Jido.Exec fork source.

      file:    #{@upstream_source_rel}
      pinned:  #{@pinned_upstream_sha256}
      current: #{current_upstream_sha}

    Re-port required: re-verify the surgical hunks and helper block against the
    moved source per docs/exploration/pms/pad/PORT-PD1-2-EXEC.md, then update
    @pinned_upstream_sha256.
    """
  end

  @doc """
  Project-relative path of the pinned upstream source. The compile stage and
  tests resolve it against the project root / an explicit fixture dir.
  """
  @spec upstream_source_path() :: Path.t()
  def upstream_source_path, do: @upstream_source_rel

  @doc "The pinned sha256 of the upstream `exec.ex` (jido_action 2.3.1)."
  @spec pinned_upstream_sha256() :: String.t()
  def pinned_upstream_sha256, do: @pinned_upstream_sha256

  @doc "The current patch revision (digest of the hunks + helper template)."
  @spec patch_revision() :: String.t()
  def patch_revision, do: @patch_revision

  @doc """
  Verify the target BEAM carries the build marker with the CURRENT pins;
  regenerate it from `source_path` when absent or stale. Path-parameterized
  so tests run it against fixture copies, never the live build's BEAM.
  A regeneration returns the captured compiler diagnostics (see
  `generate!/2`) so the compiler task can carry them to the strict gate.
  """
  @spec verify_or_regenerate!(Path.t(), Path.t()) :: :current | {:generated, [map()]}
  def verify_or_regenerate!(source_path, target_beam_path) do
    if patched_beam_current?(target_beam_path) do
      :current
    else
      {:generated, generate!(source_path, target_beam_path)}
    end
  end

  @doc """
  True when `target_beam_path` is a `Jido.Exec` BEAM whose persisted
  `@jido_claw_patch_info` matches BOTH current pins (upstream sha + patch
  revision). Missing/unreadable/unmarked/stale all read false.
  """
  @spec patched_beam_current?(Path.t()) :: boolean()
  def patched_beam_current?(target_beam_path) do
    case :beam_lib.chunks(String.to_charlist(target_beam_path), [:attributes]) do
      {:ok, {Exec, [attributes: attributes]}} -> patch_info_current?(attributes)
      _missing_or_unreadable_or_foreign -> false
    end
  end

  @doc """
  Read `source_path` (asserting the pinned sha — generation NEVER patches
  drifted source), apply the hunks + helper block, compile under the
  upstream file string, and write the BEAM to `target_beam_path`. Returns
  the compile's captured diagnostics: the generated module's own warnings
  must reach `jidoclaw.compile_check`'s allowlist split, not vanish into a
  `Code.compile_string` print. The pinned fork compiles warning-free today,
  so a non-empty list is itself a canary.
  """
  @spec generate!(Path.t(), Path.t()) :: [map()]
  def generate!(source_path, target_beam_path) do
    source = File.read!(source_path)
    assert_pinned_source!(source, source_path)
    {binary, diagnostics} = compile_patched!(patched_source(source))
    File.mkdir_p!(Path.dirname(target_beam_path))
    File.write!(target_beam_path, binary)
    diagnostics
  end

  @doc """
  The fully patched source: hunks applied (each asserted to match exactly
  once), helper block appended before the terminal `end`.
  """
  @spec patched_source(String.t()) :: String.t()
  def patched_source(source) do
    @wrap_arm_hunks
    |> Enum.reduce(source, &apply_hunk!/2)
    |> append_helper_block!()
  end

  defp apply_hunk!({old, new}, source) do
    case String.split(source, old) do
      [prefix, suffix] ->
        prefix <> new <> suffix

      parts ->
        raise """
        Jido.Exec fork hunk matched #{length(parts) - 1} times (expected exactly 1):

        #{old}
        Re-port required — see docs/exploration/pms/pad/PORT-PD1-2-EXEC.md.
        """
    end
  end

  defp append_helper_block!(source) do
    unless String.ends_with?(source, "\nend\n") do
      raise "Jido.Exec fork: upstream source no longer ends with the terminal `end` — re-port required"
    end

    body = binary_part(source, 0, byte_size(source) - byte_size("end\n"))
    body <> helper_block() <> "end\n"
  end

  defp helper_block do
    @helper_block_template
    |> String.replace("%UPSTREAM_SHA256%", @pinned_upstream_sha256)
    |> String.replace("%PATCH_REVISION%", @patch_revision)
  end

  defp compile_patched!(patched) do
    case compile_with_diagnostics(patched, @compile_file_string) do
      {[{Exec, binary}], diagnostics} ->
        {binary, diagnostics}

      {other, _diagnostics} ->
        raise "Jido.Exec fork compile produced unexpected modules: " <>
                inspect(Enum.map(other, &elem(&1, 0)))
    end
  end

  @doc """
  Compile `source` under `file` with the module-conflict warning suppressed,
  CAPTURING compiler diagnostics via `Code.with_diagnostics/2` instead of
  letting them print — captured is what lets the compiler task return them
  through the `Mix.Task.Compiler` contract into the strict gate. Returns
  `{compiled_modules, diagnostics}`.
  """
  @spec compile_with_diagnostics(String.t(), Path.t()) :: {[{module(), binary()}], [map()]}
  def compile_with_diagnostics(source, file) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Code.with_diagnostics(fn -> Code.compile_string(source, file) end)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  # Erlang SPLICES list-valued module attributes into the accumulated
  # attribute list, so the persisted keyword list reads back FLAT from
  # :beam_lib (empirically `[upstream_sha256: ..., patch_revision: ...]`,
  # not `[[...]]`); flatten+wrap tolerates both encodings and any junk
  # reads as stale.
  defp patch_info_current?(attributes) do
    info = List.flatten(List.wrap(Keyword.get(attributes, :jido_claw_patch_info)))

    Keyword.keyword?(info) and
      Keyword.get(info, :upstream_sha256) == @pinned_upstream_sha256 and
      Keyword.get(info, :patch_revision) == @patch_revision
  end

  defp assert_pinned_source!(source, source_path) do
    current = Base.encode16(:crypto.hash(:sha256, source), case: :lower)

    if current != @pinned_upstream_sha256 do
      raise """
      Jido.Exec fork: refusing to patch drifted source.

        file:    #{source_path}
        pinned:  #{@pinned_upstream_sha256}
        current: #{current}

      Re-port required — see docs/exploration/pms/pad/PORT-PD1-2-EXEC.md.
      """
    end

    :ok
  end
end
