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
      `allow_irreversible: true`. A failed event read bubbles up — an unsafe
      replay is never permitted on a failed check.

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

  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Skills
  alias JidoClaw.Skills.Compiler

  # Must match `ReactorRunner`'s replay-inputs encoder. Bump together on any
  # envelope change; any other shape (including unknown versions) refuses as
  # `:corrupt_inputs` — a v2 encoder pairs with a v2 clause here.
  @replay_version 1

  # Mirrors `WorkflowEvent.Projection`'s terminal set: only a run that can no
  # longer make progress is replayable.
  @terminal [:completed, :failed, :cancelled, :abandoned]

  # Atom-creation fence for module-kind runs (GateResume precedent): a config
  # identity must name a reactor in our own namespace before
  # `String.to_existing_atom/1` runs. No `Elixir.` prefix — the identity is
  # `inspect(module)`.
  @allowed_module_prefix "JidoClaw.Orchestration.Reactors."

  # Event kinds proving a step *executed* (started counts: an irreversible
  # side effect may have fired even if the step never completed).
  @irreversible_kinds [:step_started, :step_completed, :step_failed]

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

  # -- Pipeline --

  defp do_replay(run_id, tenant, actor, force?, allow_irreversible?) do
    with {:ok, original} <- load_run(run_id, tenant, actor),
         :ok <- ensure_terminal(original),
         {:ok, kind} <- definition_kind(original),
         # Resolve BEFORE decoding the blob: the [:safe] decode below needs
         # the definition's atoms interned (fresh-VM concern, see moduledoc).
         {:ok, resolved} <- resolve_definition(kind, original),
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

  defp ensure_terminal(%WorkflowRun{status: status}) when status in @terminal, do: :ok
  defp ensure_terminal(_run), do: {:error, {:not_replayable, :run_not_terminal}}

  # `config` is string-keyed jsonb on read. Runs created before Phase 4 (or
  # outside `ReactorRunner`) carry no kind and are simply not replayable.
  defp definition_kind(%WorkflowRun{config: config}) when is_map(config) do
    case Map.get(config, "definition_kind") do
      kind when kind in ["skill", "module"] -> {:ok, kind}
      _other -> {:error, {:not_replayable, :no_definition_kind}}
    end
  end

  defp definition_kind(_run), do: {:error, {:not_replayable, :no_definition_kind}}

  # -- Definition re-resolution (fresh, never the cache) --

  defp resolve_definition("skill", original) do
    name = original.config["reactor"]

    with {:ok, skill} <- lookup_skill(name, skill_project_dir(original)),
         {:ok, reactor} <- compile_skill(skill) do
      {:ok,
       %{
         kind: "skill",
         reactor: reactor,
         hash: DefinitionFingerprint.for_skill(skill),
         # The freshly re-resolved run-level deadline rides to launch/6 —
         # see replay_deadline/2 for the skill/module source asymmetry.
         deadline: skill.deadline
       }}
    end
  end

  defp resolve_definition("module", original) do
    identity = original.config["reactor"]

    with :ok <- check_allowed_module(identity),
         {:ok, module} <- resolve_module(identity) do
      {:ok, %{kind: "module", reactor: module, hash: DefinitionFingerprint.for_module(module)}}
    end
  end

  # The fresh-disk lookup (`Skills.load_skill/2`), NOT the cached `Skills.get/2`
  # — comparing the stored hash against the boot-time cache would defeat the
  # gate whenever the YAML changed on disk after boot.
  defp lookup_skill(name, project_dir) do
    case Skills.load_skill(name, project_dir) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:not_replayable, :skill_unavailable}}
      {:error, {:duplicate_skill_name, _name} = dup} -> {:error, {:not_replayable, dup}}
    end
  end

  # Recorded at launch by `ReactorRunner.run_config/3` when the caller's scope
  # carried one; absent (e.g. a cron run launched from the app root) falls
  # back to the current working directory, mirroring the launch-path default.
  defp skill_project_dir(%WorkflowRun{config: config}) do
    case Map.get(config, "project_dir") do
      dir when is_binary(dir) -> dir
      _missing -> File.cwd!()
    end
  end

  defp compile_skill(skill) do
    case Compiler.compile(skill) do
      {:ok, reactor} -> {:ok, reactor}
      {:error, reason} -> {:error, {:not_replayable, {:compile_failed, reason}}}
    end
  end

  defp check_allowed_module(identity) when is_binary(identity) do
    if String.starts_with?(identity, @allowed_module_prefix) do
      :ok
    else
      {:error, {:not_replayable, {:disallowed_module, identity}}}
    end
  end

  defp check_allowed_module(identity),
    do: {:error, {:not_replayable, {:disallowed_module, identity}}}

  # `String.to_existing_atom/1` (never `to_atom/1`) on the prefix-fenced
  # identity: to have created this run the module must have been loaded, so
  # its atom exists; if not, the module is gone from this VM and the run
  # cannot be replayed anyway.
  defp resolve_module(identity) do
    module = String.to_existing_atom("Elixir." <> identity)

    if Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Reactor) do
      {:ok, module}
    else
      {:error, {:not_replayable, :module_unavailable}}
    end
  rescue
    ArgumentError -> {:error, {:not_replayable, :module_unavailable}}
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
    case WorkflowEvent.for_run(original.id, tenant: tenant, actor: actor) do
      {:ok, events} ->
        if Enum.any?(events, &irreversible_step?/1) do
          {:error, :irreversible_steps_executed}
        else
          :ok
        end

      # Never permit an unsafe replay on a failed read — bubble the error.
      {:error, reason} ->
        {:error, reason}
    end
  end

  # The middleware stamps `irreversible: true` into `step_*` payloads
  # (string-keyed jsonb on read). `step_started` counts: the side effect may
  # have fired even if the step never completed.
  defp irreversible_step?(%WorkflowEvent{kind: kind, payload: payload})
       when kind in @irreversible_kinds and is_map(payload),
       do: payload["irreversible"] == true

  defp irreversible_step?(_event), do: false

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
