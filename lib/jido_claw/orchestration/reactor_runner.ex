defmodule JidoClaw.Orchestration.ReactorRunner do
  @moduledoc """
  Invocation seam that runs a reactor under the `WorkflowRun` event envelope.
  It is the single front-door for both shapes of reactor: developer-authored
  `Ash.Reactor` **modules** (e.g. `Reactors.ProjectRegistration`) and
  LLM-authored YAML skills compiled to `%Reactor{}` **structs** at runtime by
  `JidoClaw.Skills.Compiler`. `JidoClaw.Orchestration.WorkflowRunner` (the cron
  adapter) and `JidoClaw.Tools.RunSkill` (the chat tool) both compile their
  skill and hand the struct here.

  `run/3` creates the durable `WorkflowRun` (genesis `:pending`) *before*
  `Reactor.run/4`, then seeds the run identity into the Reactor context as
  `%{tenant:, actor:, workflow_run:, reactor:}` (merged over any caller
  `:context` map, base wins). `ReactorMiddleware.init/1` appends `run_started`
  (flipping the run to `:running` in the same transaction) and the
  step/terminal timeline. The reactor never creates the run — the envelope does.

  ## Middleware auto-wiring

  The runner is the envelope authority: `run/3` resolves the reactor (a module
  → its struct, or a struct passed through as-is) and injects
  `ReactorMiddleware` into it (dedup-safe via an explicit membership check — a
  reactor that already declares the middleware runs its original struct
  unchanged). This guarantees a `run_started`/`run_completed` pair, so a
  *successful* run can never strand the `WorkflowRun` in `:pending` for want of
  a producer. A reactor *may* declare the middleware but need not.

  ## Ungated struct support (compiled skills)

  `run/3` accepts a `%Reactor{}` struct for compiled skills, which **never
  halt** (no `GateStep`). For a struct the `reactor:` context string is the
  `:name` opt and `finalize_opts[:reactor_module]` is `nil`, so a `{:halted, _}`
  from a struct is out of scope — it falls through `finalize/3`'s defensive
  `:unexpected_halt` → fail-with-audit. This is **not** general gated-struct
  support: a gated struct reactor would need checkpoint-identity design (the
  resume allowlist keys on a *module* name) and is a separate future item.

  ## Options

  `:tenant`/`:actor` are required. `:name` overrides the run name. `:async?`
  (default `false`; compiled skills pass `true`) is threaded into
  `Reactor.run/4`. `:context` is an extra map merged into the base Reactor
  context — **base wins**, so `tenant`/`actor`/`workflow_run`/`reactor` can't be
  clobbered (compiled skills pass the agent scope here). `:definition_hash`
  stamps the skill fingerprint computed by the caller (ignored for module
  reactors — those self-compute via `DefinitionFingerprint.for_module/1`);
  `:retry_of_id` records replay provenance (the original run's id).
  `:idempotency_key` opts into launch dedupe (below); absent/nil means
  "always run". `:deadline` is the run-level lateness policy
  (`JidoClaw.Orchestration.Deadline.parse/1` shape) stored normalized in
  `config["deadline"]` — pure read-model evidence; an invalid value is dropped
  with a log, never a launch failure.

  ## Launch idempotency (T2-3)

  A present `:idempotency_key` makes the launch at-most-once per key:
  **read-first → create → unique-violation backstop**. A key that already owns
  a `WorkflowRun` short-circuits to `{:ok, {:existing_run, run.id}, run}`
  before the launch work — it skips runnable build/middleware wiring, run
  creation, replay-inputs encoding, and execution (only the cheap pure opt
  reads before the `with` — `Keyword.get`s, identity/name derivation — still
  run). Notably the hit wins even when the reactor argument would no longer
  build: a duplicate tick whose skill has since been removed or broken still
  resolves to the existing run. On a read miss the run is created with the
  key; if a concurrent launch wins the create race, the `:unique_run_idempotency`
  identity violation is caught and the winner is re-read and returned as the
  same `{:existing_run, _}` envelope. Deliberately not an upsert: the caller
  must know created-vs-existing so the dedupe path skips execution. Today only
  scheduled cron ticks supply a key (`WorkflowRunner`).

  ## Replay provenance (Phase 4)

  Every created run durably carries what `JidoClaw.Orchestration.Replay`
  needs later: `definition_hash` (module reactors self-compute the BEAM md5;
  skill callers pass `definition_hash:` since only they hold the `%Skills{}`
  struct — a compiled `%Reactor{}` can't be hashed, its `id` is a fresh
  `make_ref()` per compile), `config.definition_kind` (`"module" | "skill"`,
  with `config.project_dir` riding along when the caller's `:context` carries
  one, so replay can locate the skills dir without decoding the inputs blob),
  `retry_of_id`, and the AshCloak-encrypted `replay_inputs` blob —
  `term_to_binary({@replay_version, inputs, extra_context})`, encoded in the
  pre-run body so an encode raise lands in the body-level rescue.

  ## Terminal-durability backstop

  `Reactor.Executor.Init` validates inputs *before* the middleware's `init/1`
  runs, so a missing input / bad context returns `{:error, _}` from
  `Reactor.run` without `run_started` or `run_failed` ever firing — which
  would strand the fresh run in `:pending`. `finalize/3` closes this: after
  `Reactor.run` returns, it reloads the run and, if the status is still
  non-terminal, appends `run_failed` (legal from `:pending`/`:running`) and
  broadcasts `{:run_failed, …}` — the one lifecycle broadcast the middleware
  can't have fired (its `error/2` never ran). This one mechanism also covers a
  failed terminal append in the middleware. Boot recovery (`WorkflowRecovery`)
  is the final net.

  ## Never raises

  `run/3` returns a run-carrying envelope and never raises:

    * `{:ok, value, run}` — the reactor's return value plus the reloaded run.
      On a launch-dedupe hit `value` is `{:existing_run, run.id}` and `run` is
      the pre-existing run (nothing was executed).
    * `{:error, reason, run}` — a failure with the reloaded run.
    * `{:error, reason, nil}` — a *pre-run* failure, before any run exists:
      `{:not_a_reactor, mod}` (the module is not a reactor), `:missing_required_opt`
      (no `:tenant`/`:actor`), a `WorkflowRun.create` failure, or
      `{:exception, msg}` from malformed `opts` (e.g. a non-keyword list) or a
      data-layer raise during run creation.

  Two rescues cover the whole body. A body-level `try/rescue` (mirroring
  `WorkflowRunner.run/1`) normalizes any raise in the *pre-run* path — the
  `Keyword.get`/`Keyword.fetch` opt reads or `WorkflowRun.create` — into
  `{:error, {:exception, msg}, nil}`, since no run exists yet. Once the run is
  created, the `try/rescue` in `execute/6` wraps **both** `Reactor.run/4` and
  `finalize/3`, so a raise anywhere in run-or-finalize is caught (not skipped):
  the rescue calls the non-raising `ensure_failed/3` and returns the in-memory
  run without reloading (avoiding a second raise if the DB is the cause).

  ## Gate pause (human approval)

  A gate-bearing reactor's `GateStep` returns `{:halt, _}`, so `Reactor.run`
  returns `{:halted, reactor}`. `finalize/3` treats a halt as a **legitimate
  gate pause iff the reloaded run is `:awaiting_approval`** (only the gate's
  in-transaction `approval_requested` reaches that status). On a legit pause it
  persists the serialized halted reactor as the run's durable
  `resume_checkpoint`, looks up the pending `AgentCase`, broadcasts
  `{:gate_requested, …}` (only *after* the checkpoint exists — closing the
  approve-before-checkpoint race), and returns `{:ok, {:paused, case_id}, run}`
  — the same 3-element envelope, with `{:paused, id}` as the value (Decision 4).
  Any other halt (status unchanged, or `{:halted}` from `max_iterations`) stays
  a defensive failure via `ensure_failed/3`.

  `finalize/3` is the **shared finalizer**: `JidoClaw.Orchestration.GateResume`
  reuses it so the initial run and every resume complete/fail/re-pause through
  one path. The terminal-clears-checkpoint rule lives in the projection
  (Decision 7), so the runner never clears a checkpoint by hand.
  """

  # run/3 is a never-raises seam (mirrors WorkflowRunner): a body-level rescue
  # normalizes any pre-run raise (malformed opts, a WorkflowRun.create raise),
  # and the rescue in execute/6 normalizes any reactor/finalize raise into the
  # error envelope; reload/ensure_failed rescue their own internal errors.
  # Narrowing the rescues would mean enumerating the open set of reactor/Ash
  # exceptions.
  # reach:disable-for-this-file bare_rescue

  require Logger

  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Deadline
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorMiddleware
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias Reactor.Builder

  # Statuses from which a `run_failed` transition is legal — i.e. the run has
  # not yet reached a terminal state (mirrors `Projection`'s non-terminal set).
  @non_terminal [:pending, :running, :awaiting_approval]

  # Checkpoint envelope version. The encoded blob is
  # `term_to_binary({@checkpoint_version, module_string, inner_binary})` — an
  # all-builtin outer tuple so `GateResume` can decode it with `[:safe]`
  # *before* the gate-reactor module's atoms are loaded. Bump on any envelope
  # shape change; `GateResume` rejects unknown versions.
  @checkpoint_version 1

  # Replay-inputs envelope version. The encoded blob is
  # `term_to_binary({@replay_version, inputs, extra_context})` — all-data and
  # `[:safe]`-decodable (after `Replay` re-resolves the definition, interning
  # its atoms). Bump on any envelope shape change; `Replay` rejects unknown
  # versions.
  @replay_version 1

  # Cancellation reason stamped on a pending case when a gate pause fails to
  # persist; also the human-facing `run_failed` error context.
  @gate_pause_reason "gate pause failed"

  # On a launch-dedupe hit the ok-value is `{:existing_run, run_id}` and the
  # run slot carries the pre-existing run — same envelope, nothing executed.
  @type run_result ::
          {:ok, term(), WorkflowRun.t()}
          | {:error, term(), WorkflowRun.t() | nil}

  @doc """
  Run `reactor` (a reactor module or a compiled `%Reactor{}` struct) with
  `inputs` under a fresh `WorkflowRun`.

  Required opts: `:tenant` (a tenant id) and `:actor`. Optional `:name`
  overrides the run name (defaults to `inspect(reactor)`), `:async?` (default
  `false`) is threaded into `Reactor.run/4`, and `:context` is an extra map
  merged into the base Reactor context (base wins). Returns the never-raises
  envelope described in the moduledoc.
  """
  @spec run(module() | Reactor.t(), map(), keyword()) :: run_result()
  def run(reactor, inputs, opts) do
    reactor_module = if is_atom(reactor), do: reactor, else: nil
    identity = reactor_identity(reactor, opts)
    name = Keyword.get(opts, :name, identity)
    async? = Keyword.get(opts, :async?, false)
    extra_context = Keyword.get(opts, :context) || %{}
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with {:ok, tenant} <- Keyword.fetch(opts, :tenant),
         {:ok, actor} <- Keyword.fetch(opts, :actor),
         # Dedupe read BEFORE build_runnable: a key hit must short-circuit even
         # when the definition no longer resolves/builds (a duplicate tick must
         # never become an error just because the skill changed underneath it).
         :miss <- existing_for_key(idempotency_key, tenant, actor),
         {:ok, runnable} <- build_runnable(reactor),
         {:ok, run} <-
           create_run(
             %{
               name: name,
               workflow_type: "reactor",
               config:
                 run_config(identity, reactor_module, extra_context, Keyword.get(opts, :deadline)),
               definition_hash: definition_hash(reactor_module, opts),
               # Encoded here — BELOW the dedupe read — so a key hit never
               # reaches the encode; a term_to_binary raise (a non-serializable
               # input, e.g. a local fun) still lands in the body-level rescue
               # → {:error, {:exception, msg}, nil}, preserving never-raises.
               replay_inputs: :erlang.term_to_binary({@replay_version, inputs, extra_context}),
               retry_of_id: Keyword.get(opts, :retry_of_id),
               idempotency_key: idempotency_key
             },
             idempotency_key,
             tenant,
             actor
           ) do
      # Build the merged context (run-identity base wins over the caller's
      # extra `:context`) and the finalizer opts here, so `execute/6` stays
      # within the arity budget.
      context =
        Map.merge(extra_context, %{
          tenant: tenant,
          actor: actor,
          workflow_run: run,
          reactor: identity
        })

      finalize_opts = [
        tenant: tenant,
        actor: actor,
        inputs: inputs,
        reactor_module: reactor_module
      ]

      execute(run, runnable, inputs, context, finalize_opts, async?)
    else
      # Launch dedupe: the key already owns a run (read-first hit, or the
      # create race's winner re-read by create_run). Nothing was executed.
      {:hit, %WorkflowRun{} = run} -> {:ok, {:existing_run, run.id}, run}
      # Module is not a reactor — no run created yet.
      {:error, :not_a_reactor} -> {:error, {:not_a_reactor, reactor}, nil}
      # Missing :tenant / :actor opt — no run created yet.
      :error -> {:error, :missing_required_opt, nil}
      # build_runnable / WorkflowRun.create failed — no run created yet.
      {:error, reason} -> {:error, reason, nil}
    end
  rescue
    # A raise in the pre-run path (non-keyword opts -> Keyword.get/fetch raises;
    # or a data-layer exception escaping WorkflowRun.create) is normalized to
    # the pre-run envelope — no usable run exists yet, so the run slot is nil.
    # Raises *inside* execute/6 are caught by its own rescue, which carries the
    # in-memory run.
    error -> {:error, {:exception, Exception.message(error)}, nil}
  end

  # -- Internal --

  # Finding 1: the runner is the envelope authority — it guarantees
  # ReactorMiddleware is wired, so a successful run can never strand the
  # WorkflowRun in :pending. Dedup via an *explicit membership check* (not by
  # swallowing an add_middleware/2 error): a reactor that already declares the
  # middleware (e.g. ProjectRegistration) runs its original struct, while a
  # genuine add_middleware/2 failure surfaces as a pre-run {:error, reason, nil}
  # rather than silently running an un-augmented, strand-prone reactor.
  @spec build_runnable(module() | Reactor.t()) :: {:ok, Reactor.t()} | {:error, term()}
  defp build_runnable(reactor) when is_atom(reactor) do
    if Spark.Dsl.is?(reactor, Reactor) do
      ensure_middleware(reactor.reactor())
    else
      {:error, :not_a_reactor}
    end
  end

  # A compiled-skill struct is passed through as-is (struct path skips the
  # `Spark.Dsl.is?` module check); middleware is added via the same dedup check.
  defp build_runnable(%Reactor{} = reactor), do: ensure_middleware(reactor)

  defp build_runnable(_reactor), do: {:error, :not_a_reactor}

  defp ensure_middleware(base) do
    if ReactorMiddleware in base.middleware do
      {:ok, base}
    else
      Builder.add_middleware(base, ReactorMiddleware)
    end
  end

  # Identity string for the run name / config / context `reactor:` key: a module
  # inspects to its name; a compiled struct uses the caller-supplied `:name`.
  defp reactor_identity(reactor, _opts) when is_atom(reactor), do: inspect(reactor)
  defp reactor_identity(_struct, opts), do: Keyword.get(opts, :name, "reactor")

  # Module reactors self-compute the fingerprint (build_runnable has already
  # confirmed the module is a loaded reactor by the time this evaluates in the
  # `with`); a compiled skill struct can't be fingerprinted here — only the
  # caller holds the `%Skills{}` — so the struct branch takes the opt as-is.
  defp definition_hash(nil, opts), do: Keyword.get(opts, :definition_hash)
  defp definition_hash(module, _opts), do: DefinitionFingerprint.for_module(module)

  # Launch dedupe, read-first leg: a present key that already owns a run
  # short-circuits the launch via the `with`'s else (`{:hit, run}` →
  # `{:ok, {:existing_run, id}, run}`). A read error (not just not-found)
  # also falls to :miss — the create's unique-violation backstop still
  # guarantees at-most-one run per key.
  defp existing_for_key(nil, _tenant, _actor), do: :miss

  defp existing_for_key(key, tenant, actor) do
    case WorkflowRun.by_idempotency_key(key, tenant: tenant, actor: actor) do
      {:ok, %WorkflowRun{} = run} -> {:hit, run}
      _ -> :miss
    end
  end

  # Launch dedupe, create leg + race backstop. Deliberately NOT an upsert:
  # the caller must distinguish created (execute) from existing (skip), and
  # an upsert would hand back the winner indistinguishably. When two launches
  # race past the read, the loser's create violates `:unique_run_idempotency`
  # (an `%Ash.Error.Invalid{}` on field `:idempotency_key` — the declared
  # identity makes Ash return the tuple instead of raising); re-read the
  # winner and return it as `{:hit, run}`, which the `with` else maps to the
  # existing-run envelope. Any other create failure propagates unchanged.
  defp create_run(attrs, key, tenant, actor) do
    case WorkflowRun.create(attrs, tenant: tenant, actor: actor) do
      {:ok, run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{} = error} when not is_nil(key) ->
        if unique_key_violation?(error) do
          recover_race_winner(key, tenant, actor, error)
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique_key_violation?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %{field: :idempotency_key} -> true
      _ -> false
    end)
  end

  # The winner must exist (its create committed before ours failed); if the
  # re-read still misses (e.g. a read error), surface the original create
  # error rather than inventing a state.
  defp recover_race_winner(key, tenant, actor, original_error) do
    case existing_for_key(key, tenant, actor) do
      {:hit, run} -> {:hit, run}
      :miss -> {:error, original_error}
    end
  end

  # The replay-facing run config (string-keyed jsonb on read): the reactor
  # identity, which kind of definition to re-resolve (`"module"` →
  # allowlisted module lookup, `"skill"` → fresh-disk YAML lookup), and — when
  # the caller's scope carries one — the `project_dir` for that skill lookup,
  # so `Replay` can locate the skills dir WITHOUT first decoding the encrypted
  # inputs blob (its resolve-before-decode ordering depends on this). The
  # run-level `deadline` policy (T2-1) rides here too.
  defp run_config(identity, reactor_module, extra_context, deadline) do
    kind = if reactor_module, do: "module", else: "skill"
    config = %{reactor: identity, definition_kind: kind}

    config =
      case Map.get(extra_context, :project_dir) do
        dir when is_binary(dir) -> Map.put(config, :project_dir, dir)
        _missing -> config
      end

    put_deadline(config, deadline)
  end

  # Store the NORMALIZED `Deadline.parse/1` policy, not the raw input — a
  # stable config shape across atom/string-keyed YAML/test inputs. Invalid
  # values are dropped with a log rather than failing the run: the compiler
  # already rejects invalid skill declarations, so this only guards direct
  # runner callers.
  defp put_deadline(config, nil), do: config

  defp put_deadline(config, deadline) do
    case Deadline.parse(deadline) do
      {:ok, policy} ->
        Map.put(config, :deadline, policy)

      :none ->
        Logger.warning("[ReactorRunner] dropping invalid :deadline opt: #{inspect(deadline)}")
        config
    end
  end

  # One try/rescue around BOTH Reactor.run AND finalize, so a raise can't skip
  # finalization. `context` is the merged Reactor context (run-identity base
  # already won over the caller's extra `:context`); `finalize_opts` carries
  # `inputs` + `reactor_module` so the halted clause can serialize a checkpoint
  # (for a compiled struct `reactor_module` is nil — a halt is out of scope and
  # defensively fails via finalize/3's :unexpected_halt clause).
  defp execute(run, runnable, inputs, context, finalize_opts, async?) do
    runnable
    |> Reactor.run(inputs, context,
      run_id: run.id,
      async?: async?,
      timeout: :infinity,
      max_iterations: :infinity
    )
    |> finalize(run, finalize_opts)
  rescue
    error ->
      reason = {:exception, Exception.message(error)}
      ensure_failed(run, reason, finalize_opts)
      # In-memory run; do not reload here — a fresh read could raise again if
      # the DB is the cause of the rescue.
      {:error, reason, run}
  end

  @doc false
  # The shared finalizer: the initial `run/3` and every `GateResume.resume/2`
  # route their `Reactor.run` result through here, so completion, failure, and
  # gate-pause are handled identically. `opts` carries `:tenant`, `:actor`,
  # `:inputs`, and `:reactor_module`.
  @spec finalize(
          {:ok, term()} | {:ok, term(), Reactor.t()} | {:error, term()} | {:halted, Reactor.t()},
          WorkflowRun.t(),
          keyword()
        ) :: run_result()
  def finalize({:ok, value}, run, opts), do: {:ok, value, reload(run, opts)}
  def finalize({:ok, value, _reactor}, run, opts), do: {:ok, value, reload(run, opts)}

  def finalize({:error, reason}, run, opts) do
    ensure_failed(run, reason, opts)
    {:error, reason, reload(run, opts)}
  end

  # A halt is a legitimate gate pause iff the reloaded run is
  # `:awaiting_approval` — only the gate step's in-transaction
  # `approval_requested` flips it there. Any other halt (status unchanged, or
  # `{:halted}` from `max_iterations`) is defensively failed so a run never
  # strands non-terminal.
  def finalize({:halted, reactor}, run, opts) do
    reloaded = reload(run, opts)

    if reloaded.status == :awaiting_approval do
      handle_gate_pause(reactor, reloaded, opts)
    else
      ensure_failed(run, :unexpected_halt, opts)
      {:error, :unexpected_halt, reload(run, opts)}
    end
  end

  # Persist the durable checkpoint, capture the pending case id *before*
  # broadcasting (so the broadcast→approve→resume race can't clear the case out
  # from under the lookup), then announce the gate now that its checkpoint
  # exists.
  defp handle_gate_pause(reactor, run, opts) do
    with {:ok, checkpoint} <- safe_encode_checkpoint(reactor, opts),
         {:ok, updated} <-
           WorkflowRun.set_checkpoint(run, %{resume_checkpoint: checkpoint},
             tenant: Keyword.get(opts, :tenant, run.tenant_id),
             actor: Keyword.get(opts, :actor)
           ),
         {:ok, case_id} <- pending_case_id(updated, opts) do
      RunPubSub.broadcast_gate(
        {:gate_requested, updated.id, %{tenant_id: updated.tenant_id, agent_case_id: case_id}}
      )

      {:ok, {:paused, case_id}, updated}
    else
      {:error, reason} ->
        # Checkpoint encode/write failed, or the (just-committed) pending case
        # vanished — none should happen. Cancel the pending case AND fail the run
        # in one transaction so a terminal run never leaves a stale :pending case
        # in the inbox.
        cancel_pending_and_fail(run, reason, opts)
        {:error, {:gate_pause_failed, reason}, reload(run, opts)}
    end
  end

  # Fold the checkpoint serialization into the gate-pause `with` so a
  # `term_to_binary` raise (the 4th, otherwise-leaking failure path — it would
  # escape to execute/6's rescue → ensure_failed → stale :pending case) takes
  # the same cancellation path as a checkpoint-write or pending-case failure.
  # The rescue here is covered by the file-level bare_rescue pragma.
  defp safe_encode_checkpoint(reactor, opts) do
    {:ok,
     encode_checkpoint(
       reactor,
       Keyword.get(opts, :inputs, %{}),
       Keyword.fetch!(opts, :reactor_module)
     )}
  rescue
    error -> {:error, {:encode_failed, Exception.message(error)}}
  end

  # On any gate-pause failure, cancel the pending case(s) AND fail the run in one
  # transaction (the shared WorkflowLog helper), so a terminal run never leaves a
  # stale :pending case behind. The cancellation MUST be in the terminal's
  # transaction: failing the run alone while leaving the case :pending is
  # strictly worse than today, because a terminal run is never re-scanned by
  # recovery → permanent orphan.
  defp cancel_pending_and_fail(run, reason, opts) do
    case WorkflowLog.terminate_cancelling_cases(
           run,
           [{:run_failed, %{error: Reason.format({:gate_pause_failed, reason})}}],
           @gate_pause_reason,
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, _} ->
        :ok

      {:error, cleanup_error} ->
        # Cleanup transaction rolled back. Do NOT fall back to a run-only
        # ensure_failed — a terminal run + still-:pending case is never
        # re-scanned. Leaving the run :awaiting_approval (no checkpoint, or
        # checkpoint-but-no-case) lets recovery's dangling-gate / parked-orphan
        # branch reap it on the next boot.
        Logger.warning(
          "[ReactorRunner] gate-pause cleanup failed for run #{run.id}: " <>
            "#{inspect(cleanup_error)} — leaving for recovery"
        )

        :ok
    end
  end

  defp pending_case_id(run, opts) do
    case AgentCase.pending_for_run(run.id,
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, [%AgentCase{id: id} | _]} -> {:ok, id}
      {:ok, []} -> {:error, :pending_case_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  # Two-layer envelope: the outer tuple is all-builtin
  # (`{integer, string, binary}`) so `GateResume` can `binary_to_term/[:safe]`
  # it without the gate-reactor module's atoms loaded; the inner binary holds
  # the halted `%Reactor{}` + the original inputs and is decoded only once the
  # module is confirmed loaded.
  defp encode_checkpoint(reactor, inputs, module) do
    inner = :erlang.term_to_binary({reactor, inputs})
    :erlang.term_to_binary({@checkpoint_version, Atom.to_string(module), inner})
  end

  # Appends `run_failed` only when the reloaded run is still non-terminal (else
  # the middleware already recorded the terminal — no-op). Strictly
  # non-raising: rescues its own reload/append errors so a fresh failure can't
  # escape into the caller's already-entered try/rescue.
  defp ensure_failed(run, reason, opts) do
    reloaded = reload(run, opts)

    if reloaded.status in @non_terminal do
      append_failed(reloaded, reason, opts)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("[ReactorRunner] ensure_failed crashed for run #{run.id}: #{inspect(error)}")
      :ok
  end

  defp append_failed(run, reason, opts) do
    formatted = Reason.format(reason)

    case WorkflowLog.append(run, :run_failed, %{error: formatted},
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, event} ->
        # Backstop broadcast: fires ONLY when this actually writes the terminal,
        # i.e. the run was still non-terminal (the middleware's error/2 never
        # fired — e.g. an input-validation failure before init/1). Mutually
        # exclusive with the middleware's run_failed broadcast, so no double-fire.
        RunPubSub.broadcast(
          run.id,
          {:run_failed, run.id,
           %{
             tenant_id: run.tenant_id,
             name: run.name,
             workflow_type: run.workflow_type,
             status: :failed,
             error: formatted,
             completed_at: event.occurred_at
           }}
        )

        :ok

      {:error, append_error} ->
        Logger.warning(
          "[ReactorRunner] backstop run_failed append failed for run #{run.id}: #{inspect(append_error)}"
        )

        :ok
    end
  end

  # Tenant-scoped reload; falls back to the in-memory run on any failure so the
  # envelope always carries a non-nil run and this never raises.
  defp reload(run, opts) do
    case WorkflowRun.by_id(run.id,
           tenant: Keyword.get(opts, :tenant),
           actor: Keyword.get(opts, :actor)
         ) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _ -> run
    end
  rescue
    _error -> run
  end
end
