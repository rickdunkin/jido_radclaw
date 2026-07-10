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
  with a log, never a launch failure. `:parent_run_id` (AR-2 Phase 2a) links
  the created run to a parent `WorkflowRun` (a composer wave passes its
  composer parent); absent/nil → a root run. It is cross-tenant-guarded by
  `WorkflowRun`'s `:create` change. `:omit_replay_inputs` (AR-2 Phase 2b,
  default `false`) drops the at-rest `replay_inputs` copy entirely — composer
  waves pass `true` (the wave inputs hold the decrypted `:extra_context`, and
  the parent log is the replay unit, not the wave). `:sanitize_sensitive_context`
  (AR-2 Phase 2b, default `false`) is injected into the base reactor context so
  the subagent scope boundary and the inline middleware sanitize the wave's
  derived durable output. `:execution_timeout` (ms | `:infinity`, default
  `:infinity`) is the per-wave kill deadline threaded into
  `RunExecution.run_killable/4`'s bounded yield — `:infinity` leaves every
  non-composer caller unchanged.

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
  pre-run body so an encode raise lands in the body-level rescue. The blob is
  size-guarded (`:workflow_replay_inputs_max_bytes`, default 1 MB): an
  over-cap blob is omitted with a warning — the launch proceeds, and the run
  later refuses replay as `{:not_replayable, :no_inputs}`.

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

  ## Killable execution

  `execute/6` runs the reactor through
  `JidoClaw.Orchestration.RunExecution.run_killable/4` — a registered task
  `JidoClaw.Orchestration.Cancellation` can find and kill (see RunExecution's
  moduledoc for the orphaned-async-work and caller-death semantics). The
  caller-side mapping: a killed executor whose reloaded run is `:cancelled`
  returns the clean `{:error, :cancelled, run}`; any other executor death is
  a crash (`ensure_failed` + `{:error, {:exit, reason}, run}`); a registration
  conflict returns `{:error, {:already_running, pid}, run}` **without**
  `ensure_failed` — the run has a live, healthy executor and terminal-izing
  it would wrongly fail a running workflow. A cancelled run can also surface
  as `{:error, _}` from `Reactor.run` itself (a late `run_started`/
  `run_completed` append fails as an illegal transition and propagates via
  the middleware's `init`/`complete`), so the shared error finalize reloads
  first and maps a `:cancelled` run to the same clean envelope.

  ## Never raises

  `run/3` returns a run-carrying envelope and never raises:

    * `{:ok, value, run}` — the reactor's return value plus the reloaded run.
      On a launch-dedupe hit `value` is `{:existing_run, run.id}` and `run` is
      the pre-existing run (nothing was executed).
    * `{:error, reason, run}` — a failure with the reloaded run.
    * `{:error, :cancelled, run}` — the run was cancelled mid-flight
      (`Cancellation.cancel/2`); the durable status is the truth.
    * `{:error, {:already_running, pid}, run}` — a live executor already owns
      this run id (resume race); nothing was executed and the run's status is
      untouched.
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

  WS1 fence A guards the halt path too. The `{:halted, _}` clause is a `cond`
  ordered like `handle_exit/3` and `finalize({:error, _})`: `:cancelled` first
  (a run cancelled during the halt keeps the cancellation vocabulary), then a
  `fenced?` check — a halt under a **rotated** token (a reclaimer took the run
  between the gate's `approval_requested` commit and the checkpoint write, or the
  reclaimer itself parked it at the gate) returns the clean `{:error, :fenced,
  run}` with **no checkpoint** — and only then the `:awaiting_approval` pause.
  No-op when the tokens match ⇒ byte-identical for single-node and every legit
  pause.

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

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.Deadline
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorMiddleware
  alias JidoClaw.Orchestration.Reason
  alias JidoClaw.Orchestration.RunExecution
  alias JidoClaw.Orchestration.RunPubSub
  alias JidoClaw.Orchestration.WorkflowLease
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Security.SensitiveScrub
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

  # Default size guard on the persisted replay_inputs blob (1 MB). Every
  # launch funnels through run/3, and Replay re-decodes + re-persists the
  # blob — without a cap an oversized input is loopable amplification.
  @default_replay_inputs_cap 1_048_576

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
             # Replay inputs are encoded here — BELOW the dedupe read — so a
             # key hit never reaches the encode; a term_to_binary raise (a
             # non-serializable input, e.g. a local fun) still lands in the
             # body-level rescue → {:error, {:exception, msg}, nil},
             # preserving never-raises. An over-cap blob OMITS the key
             # (see replay_inputs_attrs/3) — the launch itself never fails.
             Map.merge(
               %{
                 name: name,
                 workflow_type: "reactor",
                 config:
                   run_config(
                     identity,
                     reactor_module,
                     extra_context,
                     Keyword.get(opts, :deadline)
                   ),
                 definition_hash: definition_hash(reactor_module, opts),
                 retry_of_id: Keyword.get(opts, :retry_of_id),
                 idempotency_key: idempotency_key,
                 # Composer lineage (AR-2 Phase 2a): a composer wave passes its
                 # parent run id so the child WorkflowRun links to it. nil for
                 # an ordinary reactor run → a root run. The cross-tenant guard
                 # on WorkflowRun's :create refuses a parent in another tenant.
                 parent_run_id: Keyword.get(opts, :parent_run_id)
               },
               replay_inputs_attrs(
                 name,
                 inputs,
                 extra_context,
                 Keyword.get(opts, :omit_replay_inputs, false)
               )
             ),
             idempotency_key,
             tenant,
             actor
           ) do
      # WS1 lease: generate a fresh fencing token in the CALLER and thread it
      # into both the reactor context (the sidecar + the in-txn terminal fence
      # B read it) and `finalize_opts` (the runner-side fence A reads it). The
      # row STAMP happens later, in `WorkflowLease.Middleware.init/1` inside
      # `Reactor.run` — reached only after this run wins `RunRegistry`
      # registration — as a CAS on the prior token. Generation here ≠ ownership;
      # only the execution winner rotates the token.
      claim_token = Ash.UUID.generate()

      # Build the merged context (run-identity base wins over the caller's
      # extra `:context`) and the finalizer opts here, so `execute/7` stays
      # within the arity budget.
      context =
        Map.merge(extra_context, %{
          tenant: tenant,
          actor: actor,
          workflow_run: run,
          reactor: identity,
          # WS1 lease fencing token (base map ⇒ wins over the caller's `:context`).
          claim_token: claim_token,
          # AR-2 Phase 2b marker, in the base map so it wins over the caller's
          # `:context` and reaches both the AgentRunner scope boundary and the
          # inline `ReactorMiddleware` sanitize read.
          sanitize_sensitive_context: Keyword.get(opts, :sanitize_sensitive_context, false)
        })

      finalize_opts = [
        tenant: tenant,
        actor: actor,
        inputs: inputs,
        reactor_module: reactor_module,
        # WS1 lease: the held token for fence A's reload-first compare and for
        # `append_failed/2`'s in-txn fence assertion (fence B).
        claim_token: claim_token,
        # AR-2 Phase 2b (P1b): a marked run's terminal-backstop `run_failed`
        # (pre-`init/1` validation / `{:exit, _}` kill, where the middleware's
        # `error/2` never fired) scrubs its reason in `append_failed/2`. Default
        # `false` ⇒ byte-identical for every non-composer caller.
        sanitize_sensitive_context: Keyword.get(opts, :sanitize_sensitive_context, false)
      ]

      execute(run, runnable, inputs, context, finalize_opts, async?, execution_timeout(opts))
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
      normalize_middleware(reactor.reactor())
    else
      {:error, :not_a_reactor}
    end
  end

  # A compiled-skill struct is passed through as-is (struct path skips the
  # `Spark.Dsl.is?` module check); middleware is normalized via the same seam.
  defp build_runnable(%Reactor{} = reactor), do: normalize_middleware(reactor)

  defp build_runnable(_reactor), do: {:error, :not_a_reactor}

  @doc """
  Normalize `base`'s middleware list to
  `[WorkflowLease.Middleware | rest] ++ [ReactorMiddleware]`, idempotently (both are stripped first, so a
  reactor that already declares either runs with exactly one of each).

  The order is load-bearing in BOTH directions: `init/1` and `complete/2` run
  in list order. `Lease.init` stamps the claim at `:pending` before anything
  else. `ReactorMiddleware` runs last, so `run_started` follows every custom
  init and the durable `run_completed` follows every custom completion hook.
  A later hook can therefore never return an error after the run was already
  committed completed. `GateResume` reuses this so a checkpoint written before
  WS1 still re-establishes the lease on resume. No-raise (a
  `with`, not a `{:ok, _} = …` match): an `add_middleware/2` failure returns
  `{:error, reason}` → the runner's `{:error, reason, nil}` pre-run path.
  """
  @spec normalize_middleware(Reactor.t()) :: {:ok, Reactor.t()} | {:error, term()}
  def normalize_middleware(base) do
    rest = Enum.reject(base.middleware, &(&1 in [ReactorMiddleware, WorkflowLease.Middleware]))

    # Use Builder for both validation paths, then install the deliberate final
    # order. Builder only prepends and cannot express "lease first, recorder
    # last" directly.
    with {:ok, with_recorder} <-
           Builder.add_middleware(%{base | middleware: rest}, ReactorMiddleware),
         {:ok, validated} <- Builder.add_middleware(with_recorder, WorkflowLease.Middleware) do
      {:ok, %{validated | middleware: [WorkflowLease.Middleware | rest] ++ [ReactorMiddleware]}}
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

  # Per-wave kill deadline (ms) or `:infinity` (default — no kill, byte-
  # identical to pre-2b callers). A non-positive / non-integer value other than
  # `:infinity` degrades to `:infinity` rather than failing the launch.
  defp execution_timeout(opts) do
    case Keyword.get(opts, :execution_timeout, :infinity) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms > 0 -> ms
      _invalid -> :infinity
    end
  end

  # `%{replay_inputs: blob}` when the encoded blob is within the cap; `%{}`
  # when over. The key must be OMITTED, not set to nil: AshCloak's Encrypt
  # change encrypts any PRESENT argument — including nil — so
  # `replay_inputs: nil` would persist ciphertext-of-nil instead of SQL NULL
  # and break Replay's presence check. An absent blob surfaces through the
  # existing refusal vocabulary ({:not_replayable, :no_inputs}); the warning
  # here records why. The run id doesn't exist yet, so the log carries `name`.
  # `omit_replay_inputs: true` (composer waves, A3) bypasses the encode
  # entirely so the create attrs carry NO `replay_inputs` key — not
  # `replay_inputs: nil` (AshCloak would encrypt a present nil into
  # ciphertext-of-nil; the omit-key rule). Same `%{}` shape as the over-cap
  # branch, so the run surfaces `{:not_replayable, :no_inputs}` later.
  defp replay_inputs_attrs(_name, _inputs, _extra_context, true), do: %{}

  defp replay_inputs_attrs(name, inputs, extra_context, false) do
    blob = :erlang.term_to_binary({@replay_version, inputs, extra_context})
    cap = replay_inputs_cap()

    if byte_size(blob) > cap do
      Logger.warning(
        "[ReactorRunner] replay_inputs for #{inspect(name)} dropped: " <>
          "#{byte_size(blob)} bytes exceeds cap #{cap} — the run will not be replayable"
      )

      %{}
    else
      %{replay_inputs: blob}
    end
  end

  # Positive integer or the default — a nil cap would make
  # `byte_size(blob) > nil` false (the guard never trips); a negative one
  # would strip replayability from every run.
  defp replay_inputs_cap do
    case Application.get_env(
           :jido_claw,
           :workflow_replay_inputs_max_bytes,
           @default_replay_inputs_cap
         ) do
      cap when is_integer(cap) and cap > 0 -> cap
      _invalid -> @default_replay_inputs_cap
    end
  end

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

    %{reactor: identity, definition_kind: kind}
    |> put_project_dir(extra_context)
    |> put_deadline(deadline)
  end

  defp put_project_dir(config, extra_context) do
    case Map.get(extra_context, :project_dir) do
      dir when is_binary(dir) -> Map.put(config, :project_dir, dir)
      _missing -> config
    end
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

  # One try/rescue around BOTH the killable run AND finalize, so a raise can't
  # skip finalization. `context` is the merged Reactor context (run-identity
  # base already won over the caller's extra `:context`); `finalize_opts`
  # carries `inputs` + `reactor_module` so the halted clause can serialize a
  # checkpoint (for a compiled struct `reactor_module` is nil — a halt is out
  # of scope and defensively fails via finalize/3's :unexpected_halt clause).
  # `tenant_id:` is RunExecution-local registry metadata, popped there —
  # it never reaches Reactor.run (whose executor state is struct!-strict).
  defp execute(run, runnable, inputs, context, finalize_opts, async?, execution_timeout) do
    execution =
      RunExecution.run_killable(runnable, inputs, context,
        run_id: run.id,
        tenant_id: run.tenant_id,
        async?: async?,
        timeout: :infinity,
        max_iterations: :infinity,
        # Per-wave kill deadline (AR-2 Phase 2b C3). Default `:infinity` ⇒
        # `Task.yield` never times out, so this is a no-op for non-composer
        # callers; an elapsed bound kills the executor → `{:exit, :timeout}` →
        # `handle_exit` → `ensure_failed` terminalizes the wave `:failed`.
        yield_timeout: execution_timeout
      )

    case execution do
      {:reactor, result} ->
        finalize(result, run, finalize_opts)

      {:exit, reason} ->
        handle_exit(run, reason, finalize_opts)

      # A live executor already owns this run id (resume race). NO
      # ensure_failed: the run is healthy and running — terminal-izing it
      # would wrongly fail a live workflow.
      {:duplicate, pid} ->
        {:error, {:already_running, pid}, reload(run, finalize_opts)}
    end
  rescue
    error ->
      reason = {:exception, Exception.message(error)}
      ensure_failed(run, reason, finalize_opts)
      # In-memory run; do not reload here — a fresh read could raise again if
      # the DB is the cause of the rescue.
      {:error, reason, run}
  end

  # The executor task died. A reloaded `:cancelled` means Cancellation killed
  # it — the clean cancellation envelope, not a crash. Anything else is a
  # crash: `ensure_failed` appends the terminal iff the run is still
  # non-terminal (a run that reached some *other* terminal in the
  # append-then-kill gap no-ops there — durable status stays the truth).
  defp handle_exit(run, reason, opts) do
    reloaded = reload(run, opts)

    cond do
      reloaded.status == :cancelled ->
        {:error, :cancelled, reloaded}

      # WS1 fence A: a rotated token means a reclaimer (the sidecar's kill, or a
      # WS3 reclaim) owns the run — stop with NO terminal; the new owner is the
      # truth. Covers the sidecar-kill `{:exit, :killed}` path.
      fenced?(reloaded, opts) ->
        {:error, :fenced, reloaded}

      true ->
        formatted = {:exit, Reason.format(reason)}
        ensure_failed(reloaded, formatted, opts)
        {:error, formatted, reload(run, opts)}
    end
  end

  # WS1 fence A: a terminal-writing path is fenced when the reloaded row carries
  # a DIFFERENT non-nil token than the one we hold — a reclaimer rotated it.
  # When the token matches (every non-fenced case, all of single-node) this is a
  # no-op, so the terminal paths stay byte-identical. A nil held token
  # (legacy/degraded) or a nil reloaded token (never stamped) is never fenced.
  defp fenced?(reloaded, opts) do
    case Keyword.get(opts, :claim_token) do
      held when is_binary(held) ->
        is_binary(reloaded.claim_token) and reloaded.claim_token != held

      _ ->
        false
    end
  end

  @doc """
  GateResume's exit seam: route a resumed executor's death
  (`RunExecution.run_killable/4`'s `{:exit, reason}`) through the same
  cancelled-vs-crash mapping as the initial run's — a reloaded `:cancelled`
  run returns the clean `{:error, :cancelled, run}`, anything else fails via
  the `run_failed` backstop.
  """
  @spec finalize_exit(WorkflowRun.t(), term(), keyword()) :: run_result()
  def finalize_exit(run, reason, opts), do: handle_exit(run, reason, opts)

  @doc """
  The shared finalizer: the initial `run/3` and every `GateResume.resume/2`
  route their `Reactor.run` result through here, so completion, failure, and
  gate-pause are handled identically (see the moduledoc's "Gate pause" and
  "Killable execution" sections). `opts` carries `:tenant`, `:actor`,
  `:inputs`, and `:reactor_module`.
  """
  @spec finalize(
          {:ok, term()} | {:ok, term(), Reactor.t()} | {:error, term()} | {:halted, Reactor.t()},
          WorkflowRun.t(),
          keyword()
        ) :: run_result()
  def finalize({:ok, value}, run, opts), do: {:ok, value, reload(run, opts)}
  def finalize({:ok, value, _reactor}, run, opts), do: {:ok, value, reload(run, opts)}

  # WS1 fence A — the CAS-lost `Lease.init` abort ("I don't own it"): write NO
  # terminal in any branch. The reloaded row's token is the WINNER's, so a
  # `:cancelled`/`:failed`/`:completed` that landed first is the clean truth
  # (`:cancelled` keeps its own vocab; any other terminal → `:already_terminal`),
  # and a still-non-terminal row means a live owner is running it (`:fenced`).
  # Scoped to the `{:lease_lost, _}` reason — placed BEFORE the generic clause —
  # so a real step error still surfaces its own reason rather than being swallowed
  # into `:already_terminal`. The other lease aborts (`{:lease_sidecar, _}` /
  # `{:lease_claim, _}`) flow through the generic clause below, whose disposition
  # depends on the reloaded token: when it equals the held token — a sidecar-fail,
  # or a genesis cluster stamp-error where the row was never stamped — `fenced?/2`
  # is false and the run it owns is failed; but a re-stamp `{:lease_claim, _}` (a
  # `GateResume`/recovery resume) leaves the row on the PRIOR token ≠ the fresh held
  # token → `fenced?/2` true → NO terminal, left `:running` for reclaim/boot.
  def finalize({:error, {:lease_lost, _id}}, run, opts) do
    reloaded = reload(run, opts)

    cond do
      reloaded.status == :cancelled -> {:error, :cancelled, reloaded}
      reloaded.status in @non_terminal -> {:error, :fenced, reloaded}
      true -> {:error, :already_terminal, reloaded}
    end
  end

  # Reload-first: a cancelled run's late `run_started`/`run_completed` append
  # fails as an illegal transition and PROPAGATES out of `Reactor.run` as
  # `{:error, %Ash.Error.Invalid{}}` via the middleware's `init`/`complete` —
  # when the durable status already says `:cancelled`, that error is the
  # cancellation surfacing, not a recording failure. GateResume inherits this
  # for free via the shared finalizer.
  def finalize({:error, reason}, run, opts) do
    reloaded = reload(run, opts)

    cond do
      reloaded.status == :cancelled ->
        {:error, :cancelled, reloaded}

      # WS1 fence A: a fenced `complete/2` (rejected by Allocate's fence B) or a
      # step-error-while-fenced reloads a rotated token — stop clean, no terminal.
      fenced?(reloaded, opts) ->
        {:error, :fenced, reloaded}

      true ->
        ensure_failed(reloaded, reason, opts)
        {:error, reason, reload(run, opts)}
    end
  end

  # A halt is a legitimate gate pause iff the reloaded run is
  # `:awaiting_approval` — only the gate step's in-transaction
  # `approval_requested` flips it there. Any other halt (status unchanged, or
  # `{:halted}` from `max_iterations`) is defensively failed so a run never
  # strands non-terminal. The branch order mirrors `handle_exit/3` /
  # `finalize({:error, _})`.
  def finalize({:halted, reactor}, run, opts) do
    reloaded = reload(run, opts)

    cond do
      # A run cancelled during the halt keeps the cancellation vocabulary (placed
      # ahead of fenced? so it surfaces the clean {:error, :cancelled, run} rather
      # than :fenced/:unexpected_halt), consistent with the other two fence paths.
      reloaded.status == :cancelled ->
        {:error, :cancelled, reloaded}

      # WS1 fence A on the halt path: a rotated token means a reclaimer owns the
      # run — stop with NO checkpoint and NO terminal. Closes the
      # append→checkpoint TOCTOU (the token rotates after a legit
      # `approval_requested` commits but before the checkpoint write) and the case
      # where the reclaimer itself parked the run at the gate. No-op when tokens
      # match ⇒ byte-identical for every legit pause.
      fenced?(reloaded, opts) ->
        {:error, :fenced, reloaded}

      reloaded.status == :awaiting_approval ->
        handle_gate_pause(reactor, reloaded, opts)

      true ->
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
           WorkflowLog.persist_gate_checkpoint(run, checkpoint,
             tenant: Keyword.get(opts, :tenant, run.tenant_id),
             actor: Keyword.get(opts, :actor),
             claim_fence_token: Keyword.get(opts, :claim_token)
           ),
         {:ok, case_id} <- pending_case_id(updated, opts) do
      RunPubSub.broadcast_gate_requested(updated.id, updated.tenant_id, case_id)

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
    formatted = format_failure(reason, opts)

    case WorkflowLog.append(run, :run_failed, %{error: formatted},
           tenant: Keyword.get(opts, :tenant, run.tenant_id),
           actor: Actor.system(run.tenant_id),
           # WS1 fence B: assert our ownership at the DB level. We only reach the
           # backstop for runs we own (fence A short-circuits fenced runs first),
           # so this normally matches; if a fenced executor ever reached here, the
           # in-txn guard rejects the terminal rather than failing a live run.
           claim_fence_token: Keyword.get(opts, :claim_token)
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

  # A marked run (AR-2 Phase 2b, P1b) replaces the formatted reason with the
  # type-preserving placeholder so the backstop's durable `error` column AND its
  # PubSub broadcast carry no artifact-derived content. Default `false` ⇒
  # byte-identical `Reason.format/1` for every non-composer caller.
  defp format_failure(reason, opts) do
    if Keyword.get(opts, :sanitize_sensitive_context, false),
      do: SensitiveScrub.redacted_text(),
      else: Reason.format(reason)
  end

  # Tenant-scoped reload; falls back to the in-memory run on any failure so the
  # envelope always carries a non-nil run and this never raises.
  defp reload(run, opts) do
    case WorkflowRun.by_id(run.id,
           tenant: Keyword.get(opts, :tenant),
           actor: Actor.system(run.tenant_id)
         ) do
      {:ok, %WorkflowRun{} = reloaded} -> reloaded
      _ -> run
    end
  rescue
    _error -> run
  end
end
