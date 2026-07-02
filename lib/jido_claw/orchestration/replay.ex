defmodule JidoClaw.Orchestration.Replay do
  @moduledoc """
  The single decision point for re-running a terminal `WorkflowRun` (Phase 4,
  FEATURES-WORTH-BORROWING T1-3): the dashboard button and the MCP
  `replay_workflow` tool both funnel through `replay/2`, so the safety gates
  are applied exactly once, in one place.

  ## Two safety gates

  Skills are LLM-edited YAML, so a naive re-run has two footguns this module
  exists to refuse:

    * **Definition gate** — the definition is re-resolved *fresh* and
      re-fingerprinted (`DefinitionFingerprint`); a mismatch against the hash
      stored at the original launch means the semantics changed since, and the
      replay is refused with `{:error, {:definition_changed, stored, current}}`.
      Override: `force: true` (logged).
    * **Irreversible gate** — if the original run *executed* any step declared
      `irreversible: true` (scanned from the durable `step_*` event payloads
      the middleware stamps), re-running it would repeat an un-undoable side
      effect; refused with `{:error, :irreversible_steps_executed}`. Override:
      `allow_irreversible: true`. A failed event read is **normalized** to
      `{:not_replayable, :irreversible_check_failed}` (never bubbled raw) — an
      unsafe replay is never permitted on a failed check, and the refusal joins
      the vocabulary `diagnose` reports, so the MCP/dashboard surfaces attach a
      structured preflight report instead of an opaque error.

  Both overrides are operator affordances (the dashboard); the MCP tool
  deliberately exposes neither.

  ## Fresh re-resolution (never the cache)

  A skill is re-resolved from **disk** via `Skills.load_skill/2` (matched on
  the skill's `name:` field, never a filename built from the run name) using
  `config["project_dir"]` recorded at launch — the boot-time `Skills.get/2`
  cache would mask exactly the on-disk edit the hash gate exists to catch. A
  module identity is accepted only under the `JidoClaw.Orchestration.Reactors.`
  prefix (the atom-creation fence; note: `config["reactor"]` is
  `inspect(module)` — no `Elixir.` prefix, unlike `GateResume`'s checkpoint
  strings) and must resolve to a loaded reactor module.

  Re-resolution happens **before** the inputs blob is decoded: decoding is
  `binary_to_term/2` `[:safe]`, which fails on atoms not currently interned —
  on a fresh VM the definition's input-key atoms may exist only once its
  module is loaded (the same concern `GateResume`'s two-stage decode
  addresses). The blob is the AshCloak-encrypted `replay_inputs` column
  written at create and never cleared; this module is its only decoder.

  ## Replay scope

  The decoded `extra_context` (the durable agent scope — tenant/session/
  workspace/user identity) is forwarded verbatim, with two exceptions: a
  synthetic per-tick `"cron:" <> _` `workspace_id` is replaced with a fresh
  `"replay:<original-short-id>:<unique>"` scratch key, and `:actor` is
  dropped — the live caller's actor is authoritative (the runner's base-wins
  merge already enforces that; dropping avoids carrying a stale embedded one).

  ## Envelope

  Uniform two-way result: `{:ok, new_run}` whenever a replay run came into
  existence — **including** one that launched and then failed or paused at a
  gate (inspect `run.status`/`run.error`); `{:error, reason}` for refusals
  and pre-run launch failures. The new run carries `retry_of_id` =
  the original's id (provenance). Pre-existing rows without a stored hash or
  inputs blob simply refuse as `:no_hash` / `:no_inputs` (greenfield — no
  backfill).
  """

  require Logger

  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.Replay.DefinitionResolver
  alias JidoClaw.Orchestration.Replay.Diagnostics
  alias JidoClaw.Orchestration.Replay.EventReader
  alias JidoClaw.Orchestration.Replay.Safety
  alias JidoClaw.Orchestration.WorkflowRun

  # Must match `ReactorRunner`'s replay-inputs encoder. Bump together on any
  # envelope change; any other shape (including unknown versions) refuses as
  # `:corrupt_inputs` — a v2 encoder pairs with a v2 clause here.
  @replay_version 1

  @doc """
  Replay terminal run `run_id` as a fresh `WorkflowRun`.

  Required opts: `:tenant`, `:actor` (missing → `{:error,
  :missing_required_opt}` — never raises). Optional: `force: true` overrides
  the definition gate; `allow_irreversible: true` overrides the irreversible
  gate. Returns the uniform envelope described in the moduledoc; refusal
  reasons: `:not_found` · `{:not_replayable, _}` ·
  `{:definition_changed, stored, current}` · `:irreversible_steps_executed` ·
  `{:launch_failed, _}`.
  """
  @spec replay(String.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def replay(run_id, opts \\ []) do
    with {:ok, tenant} <- Keyword.fetch(opts, :tenant),
         {:ok, actor} <- Keyword.fetch(opts, :actor) do
      do_replay(
        run_id,
        tenant,
        actor,
        Keyword.get(opts, :force, false),
        Keyword.get(opts, :allow_irreversible, false)
      )
    else
      :error -> {:error, :missing_required_opt}
    end
  end

  @doc """
  Preflight diagnostics for `run_id` — a pure, never-decrypting projection of
  the recorded run's health plus the determinable replay blockers. Facade over
  `JidoClaw.Orchestration.Replay.Diagnostics.diagnose/2`; see that module for
  the two-axes contract and the never-decrypt discipline.
  """
  @spec diagnose(String.t(), keyword()) ::
          {:ok, Diagnostics.t()} | {:error, :missing_required_opt | :not_found}
  def diagnose(run_id, opts \\ []), do: Diagnostics.diagnose(run_id, opts)

  # -- Pipeline --

  defp do_replay(run_id, tenant, actor, force?, allow_irreversible?) do
    with {:ok, original} <- load_run(run_id, tenant, actor),
         :ok <- ensure_terminal(original),
         {:ok, kind} <- DefinitionResolver.definition_kind(original),
         # Resolve BEFORE decoding the blob: the [:safe] decode below needs
         # the definition's atoms interned (fresh-VM concern, see moduledoc).
         {:ok, resolved} <- DefinitionResolver.resolve(kind, original),
         {:ok, inputs, extra_context} <- decode_inputs(original, tenant, actor),
         :ok <- check_definition(original, resolved, force?),
         :ok <- check_irreversible(original, tenant, actor, allow_irreversible?) do
      launch(original, resolved, inputs, extra_context, tenant, actor)
    end
  end

  # Tenant-scoped read ⇒ tenant isolation for free: a cross-tenant id is
  # filtered out by the read policy and lands here as not-found.
  defp load_run(run_id, tenant, actor) do
    case WorkflowRun.by_id(run_id, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = run} -> {:ok, run}
      _other -> {:error, :not_found}
    end
  end

  defp ensure_terminal(%WorkflowRun{status: status}) do
    if Safety.terminal_status?(status),
      do: :ok,
      else: {:error, {:not_replayable, :run_not_terminal}}
  end

  # -- Inputs decode (the only consumer of the replay_inputs blob) --

  defp decode_inputs(original, tenant, actor) do
    case decrypt_inputs(original, tenant, actor) do
      {:ok, blob} -> decode_blob(blob)
      {:error, _reason} = error -> error
    end
  end

  # Mirrors `GateResume.decrypt_checkpoint/3`: load the AshCloak
  # `replay_inputs` calculation (vault-decrypt). A vault failure (key
  # rotation, corrupt ciphertext) raises inside the calculation — the blob can
  # never be decoded, so it refuses as corrupt.
  defp decrypt_inputs(run, tenant, actor) do
    case Ash.load(run, :replay_inputs, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{replay_inputs: blob}} when is_binary(blob) ->
        {:ok, blob}

      {:ok, _no_blob} ->
        {:error, {:not_replayable, :no_inputs}}

      {:error, reason} ->
        Logger.warning("[Replay] replay_inputs load failed for run #{run.id}: #{inspect(reason)}")
        {:error, {:not_replayable, :corrupt_inputs}}
    end
  rescue
    # reach:disable-next-line bare_rescue
    error ->
      # Cloak raises (Cloak.MissingCipher / decrypt failures) are an open set;
      # any of them means the blob is unreadable -> refuse as corrupt.
      Logger.warning(
        "[Replay] replay_inputs decrypt raised for run #{run.id}: #{Exception.message(error)}"
      )

      {:error, {:not_replayable, :corrupt_inputs}}
  end

  # `[:safe]` decode of the versioned envelope. The blob preserves atom keys
  # (unlike the string-keyed jsonb config — respect the asymmetry); its atoms
  # are interned by now because the definition was resolved first.
  defp decode_blob(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      {@replay_version, inputs, extra_context} when is_map(inputs) and is_map(extra_context) ->
        {:ok, inputs, extra_context}

      _other_shape_or_version ->
        {:error, {:not_replayable, :corrupt_inputs}}
    end
  rescue
    ArgumentError -> {:error, {:not_replayable, :corrupt_inputs}}
  end

  # -- Gates --

  defp check_definition(%WorkflowRun{definition_hash: nil}, _resolved, _force?),
    do: {:error, {:not_replayable, :no_hash}}

  defp check_definition(%WorkflowRun{definition_hash: stored}, %{hash: stored}, _force?), do: :ok

  defp check_definition(%WorkflowRun{definition_hash: stored} = run, %{hash: current}, force?) do
    if force? do
      Logger.warning(
        "[Replay] forcing replay of run #{run.id} past a definition change " <>
          "(stored #{stored}, current #{current})"
      )

      :ok
    else
      {:error, {:definition_changed, stored, current}}
    end
  end

  defp check_irreversible(_original, _tenant, _actor, true), do: :ok

  defp check_irreversible(original, tenant, actor, false) do
    # O-M1: only the step kinds `Safety.irreversible_executed?/1` inspects
    # (single-sourced in `Safety.irreversible_kinds/0`) — the gate no longer
    # loads the ENTIRE event log. Bounded by step count; no `kind` index, so
    # the win is fewer rows decoded/folded.
    case EventReader.for_run(original.id,
           query: [filter: [kind: [in: Safety.irreversible_kinds()]]],
           tenant: tenant,
           actor: actor
         ) do
      {:ok, events} ->
        if Safety.irreversible_executed?(events) do
          {:error, :irreversible_steps_executed}
        else
          :ok
        end

      # Never permit an unsafe replay on a failed read. Normalize the opaque Ash
      # error into the refusal vocabulary (matching what `diagnose` emits) so the
      # MCP tool and dashboard attach a structured preflight report rather than
      # an `inspect/1` blob; log the underlying reason first (the gate-warning
      # style above).
      {:error, reason} ->
        Logger.warning(
          "[Replay] irreversible-event read failed for run #{original.id}: #{inspect(reason)}"
        )

        {:error, {:not_replayable, :irreversible_check_failed}}
    end
  end

  # -- Launch --

  defp launch(original, resolved, inputs, extra_context, tenant, actor) do
    case ReactorRunner.run(resolved.reactor, inputs,
           tenant: tenant,
           actor: actor,
           name: original.name,
           # Match the launch paths: compiled skills run async, dev modules
           # sync (`ReactorRunner`'s default).
           async?: resolved.kind == "skill",
           context: replay_context(extra_context, original),
           definition_hash: definition_hash_opt(resolved),
           deadline: replay_deadline(resolved, original),
           retry_of_id: original.id
         ) do
      # A replay run exists — its outcome (completed / failed / paused at a
      # gate) lives on the run; one envelope for every caller.
      {:ok, _value, run} -> {:ok, run}
      {:error, _reason, %WorkflowRun{} = run} -> {:ok, run}
      # Pre-run failure: no replay run ever came into existence.
      {:error, reason, nil} -> {:error, {:launch_failed, reason}}
    end
  end

  # Skill structs can't be fingerprinted by the runner — pass the hash just
  # computed from the fresh skill; module reactors self-compute (nil).
  defp definition_hash_opt(%{kind: "skill", hash: hash}), do: hash
  defp definition_hash_opt(_resolved), do: nil

  # Deadline-source asymmetry (T2-1): a skill replay carries the FRESHLY
  # re-resolved `skill.deadline` — deadlines are excluded from the definition
  # fingerprint, so a deadline-only YAML edit passes the gate un-forced and
  # the replay should honor the edit. A module-reactor replay preserves the
  # original run's policy (`config["deadline"]`, string-keyed jsonb —
  # `ReactorRunner`'s `Deadline.parse/1` re-normalizes it): the runner is a
  # generic deadline-capable API and module replays must not silently drop it.
  defp replay_deadline(%{kind: "skill", deadline: deadline}, _original), do: deadline
  defp replay_deadline(_resolved, original), do: original.config["deadline"]

  # Preserve the durable scope verbatim (tenant/session/workspace/user
  # identity keeps child transcript + correlation writes coherent), except:
  # drop `:actor` (the live caller's actor is authoritative) and replace a
  # synthetic per-tick cron scratch workspace with a fresh replay-scoped one.
  defp replay_context(extra_context, original) do
    extra_context
    |> Map.delete(:actor)
    |> replace_cron_workspace(original)
  end

  defp replace_cron_workspace(%{workspace_id: "cron:" <> _rest} = context, original) do
    short_id = String.slice(original.id, 0, 8)

    Map.put(
      context,
      :workspace_id,
      "replay:#{short_id}:#{System.unique_integer([:positive])}"
    )
  end

  defp replace_cron_workspace(context, _original), do: context
end
