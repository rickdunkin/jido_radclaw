defmodule JidoClaw.RouteComposer.TestFixtures do
  @moduledoc """
  Shared builders and assertion helpers for the route-composer suite — the
  Elixir analogue of Alp River `test_route.py`'s `S()` factory, `CATALOG`, and
  `_lock_catalog`.

  Every fixture routes through `stage/1` and the named catalog builders so the
  port stays structurally DRY (one builder, no duplicated stage literals across
  test files).
  """

  import ExUnit.Assertions

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.RouteComposer
  alias JidoClaw.RouteComposer.Commit
  alias JidoClaw.RouteComposer.Router
  alias JidoClaw.RouteComposer.Stage

  @doc """
  Builds a `%Stage{}` from `S()`-style keyword opts. Unspecified fields take
  their struct defaults; `:req` / `:opt` populate `input.required` /
  `input.optional`, and `:sub` / `:pub` populate `subscribes` / `publishes`.
  `:model` / `:effort` / `:emit` pass straight through to the same-named struct
  fields (defaulting to `nil` / `nil` / `:default` — i.e. the struct defaults).
  """
  @spec stage(keyword()) :: Stage.t()
  def stage(opts) do
    %Stage{
      name: Keyword.get(opts, :name),
      unit: Keyword.get(opts, :unit),
      task: Keyword.get(opts, :task),
      lens: Keyword.get(opts, :lens),
      reverse_verify: Keyword.get(opts, :reverse_verify, false),
      guard: Keyword.get(opts, :guard),
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort),
      emit: Keyword.get(opts, :emit, :default),
      routes: Keyword.get(opts, :routes, []),
      input: %{required: Keyword.get(opts, :req, []), optional: Keyword.get(opts, :opt, [])},
      output: Keyword.get(opts, :out, []),
      subscribes: Keyword.get(opts, :sub, []),
      publishes: Keyword.get(opts, :pub, []),
      lock: Keyword.get(opts, :lock, [])
    }
  end

  @doc """
  The 8-stage synthetic catalog from `test_route.py` (`CATALOG`). Names are
  stamped from the map keys so the catalog is self-consistent; the router never
  reads `name`, and this catalog is intentionally **not** validator-clean
  (`scan` triggers on the raw path topic `code`).
  """
  @spec synthetic_catalog() :: %{String.t() => Stage.t()}
  def synthetic_catalog do
    key_named(%{
      "scan" =>
        stage(
          routes: ["code", "talk"],
          req: ["intent"],
          out: ["reuse-map"],
          sub: ["code"],
          pub: ["missing-infra", "scope-shift"]
        ),
      "impl" =>
        stage(
          routes: ["code"],
          req: ["plan", "tests"],
          out: ["diff"],
          sub: ["plan-ready"],
          pub: ["code-written", "scope-shift"]
        ),
      "sec" =>
        stage(
          routes: ["code", "sketch"],
          req: ["diff"],
          out: ["findings"],
          sub: ["auth-surface"],
          pub: ["findings:security", "scope-shift"],
          guard: :sticky
        ),
      "proto" =>
        stage(
          routes: ["code"],
          req: ["intent"],
          out: ["tracer"],
          sub: ["missing-infra"],
          pub: ["scope-shift"]
        ),
      "plan" =>
        stage(
          routes: ["code"],
          req: ["intent"],
          opt: ["reuse-map"],
          out: ["blueprint"],
          sub: ["plan-needed"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "codeonly" => stage(routes: ["code"], sub: ["ping"], pub: ["scope-shift"]),
      "sketchonly" => stage(routes: ["sketch"], sub: ["ping"], pub: ["scope-shift"]),
      "both" => stage(routes: ["code", "sketch"], sub: ["ping"], pub: ["scope-shift"])
    })
  end

  @doc """
  A minimal catalog with a single lockable `impl` stage (`test_route.py`'s
  `_lock_catalog`). Options: `:lock` (the lock list, default `[]`) and `:extra`
  (a map of additional stages to merge). Not required to be validator-clean.
  """
  @spec lock_catalog(keyword()) :: %{String.t() => Stage.t()}
  def lock_catalog(opts \\ []) do
    lock = Keyword.get(opts, :lock, [])
    extra = Keyword.get(opts, :extra, %{})

    base = %{
      "impl" =>
        stage(
          routes: ["code"],
          req: ["plan"],
          out: ["diff"],
          sub: ["plan-ready"],
          pub: ["code-written", "scope-shift"],
          lock: lock
        )
    }

    key_named(Map.merge(base, extra))
  end

  @doc """
  Drives `Router.compose_route/4` from list inputs. Options: `:available` and
  `:ran` (both lists, default `[]`). Live signals are the second argument.
  """
  @spec compose(%{String.t() => Stage.t()}, [String.t()], keyword()) :: Router.result()
  def compose(catalog, live, opts \\ []) do
    available = Keyword.get(opts, :available, [])
    ran = Keyword.get(opts, :ran, [])
    Router.compose_route(catalog, MapSet.new(live), MapSet.new(available), MapSet.new(ran))
  end

  @doc "Asserts `name` is in the composed route."
  @spec assert_in_route(Router.result(), String.t()) :: true
  def assert_in_route(result, name) do
    assert name in result.route, "expected #{name} in route, got #{inspect(result.route)}"
  end

  @doc """
  Asserts `name` is held and its unmet-until list contains every signal in
  `expected_untils`.
  """
  @spec assert_held(Router.result(), String.t(), [String.t()]) :: true
  def assert_held(result, name, expected_untils) do
    assert Map.has_key?(result.held, name),
           "expected #{name} held, got #{inspect(Map.keys(result.held))}"

    unmet = Map.fetch!(result.held, name)

    Enum.each(expected_untils, fn until ->
      assert until in unmet, "expected #{until} in held[#{name}]=#{inspect(unmet)}"
    end)

    true
  end

  # ---------------------------------------------------------------------------
  # Phase-1 loop fixtures (AR-2 §14 — the single-run loop spike)
  # ---------------------------------------------------------------------------

  @doc """
  The validator-clean, gate-free Phase-1 catalog mirroring the real code-path
  shape: `planner → {approver, implementer(held by lock)} → implementer →
  {quality-reviewer, security-reviewer}`. `planner` subscribes the **seed**
  `request-received` (no triage stage in Phase 1); the reviewers declare both
  `clean:<lens>` and `findings:<lens>`.
  """
  @spec phase1_catalog() :: %{String.t() => Stage.t()}
  def phase1_catalog do
    key_named(%{
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft an implementation plan from the request; emit plan-ready.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "approver" =>
        stage(
          unit: {:worker_template, "verifier"},
          task: "Approve the plan; emit plan-approved with the approved-plan.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["approved-plan"],
          pub: ["plan-approved", "scope-shift"]
        ),
      "implementer" =>
        stage(
          unit: {:worker_template, "coder"},
          task: "Implement the approved plan; emit code-written and auth-surface.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          opt: ["approved-plan"],
          out: ["diff"],
          pub: ["code-written", "auth-surface", "scope-shift"],
          lock: [%{while: "plan-ready", until: "plan-approved"}]
        ),
      "quality-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          task: "Review the diff for quality; flag findings, else emit clean:quality.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:quality", "findings:quality", "scope-shift"]
        ),
      "security-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "security",
          task: "Review the diff for auth-surface; flag findings, else emit clean:security.",
          routes: ["code"],
          sub: ["auth-surface"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:security", "findings:security", "scope-shift"]
        )
    })
  end

  @doc "The Phase-1 seed live signals: the seed signal + the `code` path."
  @spec phase1_seed_live() :: [String.t()]
  def phase1_seed_live, do: ["request-received", "code"]

  @doc "The Phase-1 seed artifact store (provenance shape from the start)."
  @spec phase1_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def phase1_seed_artifacts, do: %{"request" => %{"seed" => "Build the auth feature"}}

  @doc "Canned reviewer typed output — clean (approve, no findings)."
  @spec phase1_clean_reviewer() :: %{String.t() => term()}
  def phase1_clean_reviewer,
    do: %{
      "overall" => "approve",
      "summary" => "looks correct",
      "action_needed" => "none",
      "findings" => []
    }

  @doc """
  Canned reviewer typed output — INFRA (camus C1-3): the `overall` drifted out
  of enum, so the normalizer refuses it (`{:infra, {:invalid_overall, _}}`)
  rather than folding it as a verdict.
  """
  @spec phase1_infra_reviewer() :: %{String.t() => term()}
  def phase1_infra_reviewer,
    do: %{
      "overall" => "maybe",
      "summary" => "the judge drifted out of enum",
      "action_needed" => "n/a",
      "findings" => []
    }

  @doc "Canned reviewer typed output — findings (request_changes)."
  @spec phase1_findings_reviewer() :: %{String.t() => term()}
  def phase1_findings_reviewer do
    %{
      "overall" => "request_changes",
      "summary" => "found a defect",
      "action_needed" => "add the nil check before the deref",
      "findings" => [
        %{
          "severity" => "error",
          "confidence" => "likely",
          "location" => "lib/auth.ex:42",
          "description" => "missing nil check"
        }
      ]
    }
  end

  @doc """
  The `template => canned typed output` map the stub workers serve. Producers
  carry `signals` + their output artifact; the reviewer carries the supplied
  verdict (default clean).
  """
  @spec phase1_stub_outputs(map()) :: %{String.t() => map()}
  def phase1_stub_outputs(reviewer \\ phase1_clean_reviewer()) do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: build the auth feature"},
      "verifier" => %{
        "signals" => ["plan-approved"],
        "approved-plan" => "APPROVED: build the auth feature"
      },
      "coder" => %{
        "signals" => ["code-written", "auth-surface"],
        "diff" => "DIFF: +def authenticate(user), do: ..."
      },
      "reviewer" => reviewer
    }
  end

  @doc """
  The `:agent_templates_override` map pointing every Phase-1 template at `module`
  (a single shared stub worker; the stub picks its canned output by
  `agent_template`). Includes the AR-4 `fixer` template so the same override
  drives the self-heal fixture (`self_heal_fixture_catalog/0`); the extra entry is
  harmless for catalogs without a fixer stage.
  """
  @spec phase1_template_override(module()) :: %{String.t() => map()}
  def phase1_template_override(module) do
    Map.new(~w(researcher verifier coder reviewer fixer), fn name ->
      {name, stub_template(module, "phase-1 stub")}
    end)
  end

  # ---------------------------------------------------------------------------
  # AR-4 self-heal fixtures (review → fix → re-review → converge)
  # ---------------------------------------------------------------------------

  @doc """
  A validator-clean, gate-free catalog mirroring the real `code` path's self-heal
  shape: `planner → implementer → {quality,correctness,security}-reviewer` with a
  `fixer` closing the loop. The reviewers optional-input `fix` and subscribe
  `code-written` (security subscribes `auth-surface` — initially quiet, SUMMONED
  when the fixer emits it); the fixer subscribes the `findings` family, reads
  `diff` + the loop-injected `review-feedback`/`review-action`, and re-emits
  `code-written` + the touched-domain signals. Findings ride the SIGNAL, not a
  data input, so the data graph stays acyclic.

  Driven with `self_heal_seed_*`, a flagged review wave loops review → fix →
  re-review until every lens is clean (`:route_converged`).
  """
  @spec self_heal_fixture_catalog() :: %{String.t() => Stage.t()}
  def self_heal_fixture_catalog do
    key_named(%{
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft an implementation plan from the request; emit plan-ready.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "implementer" =>
        stage(
          unit: {:worker_template, "coder"},
          task: "Implement the plan; emit code-written.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"]
        ),
      "quality-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          task: "Review the diff for quality; flag findings, else emit clean:quality.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          opt: ["fix"],
          out: ["findings", "action_needed"],
          pub: ["clean:quality", "findings:quality", "scope-shift"]
        ),
      "correctness-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "correctness",
          task: "Review the diff for correctness; flag findings, else emit clean:correctness.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          opt: ["fix"],
          out: ["findings", "action_needed"],
          pub: ["clean:correctness", "findings:correctness", "scope-shift"]
        ),
      "security-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "security",
          task: "Review the diff for auth-surface; flag findings, else emit clean:security.",
          routes: ["code"],
          sub: ["auth-surface"],
          req: ["diff"],
          opt: ["fix"],
          out: ["findings", "action_needed"],
          pub: ["clean:security", "findings:security", "scope-shift"]
        ),
      "fixer" =>
        stage(
          unit: {:worker_template, "fixer"},
          task:
            "Resolve the open review findings against the diff; emit code-written and the " <>
              "touched-domain signals (auth-surface) for re-review.",
          routes: ["code"],
          sub: ["findings"],
          req: ["diff"],
          opt: ["review-feedback", "review-action"],
          out: ["fix"],
          pub: ["code-written", "scope-shift", "auth-surface", "significant-build"]
        )
    })
  end

  @doc "The self-heal seed live signals: the seed signal + the `code` path."
  @spec self_heal_seed_live() :: [String.t()]
  def self_heal_seed_live, do: ["request-received", "code"]

  @doc "The self-heal seed artifact store (the seed `request`)."
  @spec self_heal_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def self_heal_seed_artifacts, do: %{"request" => %{"seed" => "Build the auth feature"}}

  @doc """
  The static `template => canned typed output` map for the self-heal loop: the
  `researcher` (planner) emits `plan-ready` + `plan`; the `coder` (implementer)
  emits `code-written` + `diff`. The `reviewer` + `fixer` outputs are NOT here —
  they are driven by `SystemLoopWorker` (per-lens flag schedule + the fixer's
  domain signals).
  """
  @spec self_heal_stub_outputs() :: %{String.t() => map()}
  def self_heal_stub_outputs do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: build the auth feature"},
      "coder" => %{"signals" => ["code-written"], "diff" => "DIFF: +def authenticate(user)"}
    }
  end

  # ---------------------------------------------------------------------------
  # Phase-3 triage-seeded fixtures (AR-2 §8/§14 — the Option-A front-door seed)
  # ---------------------------------------------------------------------------

  @doc """
  A **gate-free**, validator-clean catalog mirroring `phase1_catalog/0`, but with
  a non-executable `{:seed, "triage"}` stage and a `planner` that subscribes
  `plan-needed` / requires the `intent` artifact (triage's declared outputs) — the
  shape the front-door Option-A seed reconciles against. The built-in catalog
  can't converge until Phase 4 (it halts at `plan-gate`), so end-to-end seeding /
  reconciliation tests run on THIS catalog instead.

  Driven with the Option-A seed (`triage ∈ ran`, `intent`/`plan-needed`/path
  seeded), the route is `planner → approver → implementer(held) → {reviewers}` and
  converges; `triage` is in `ran` so it is never dispatched.
  """
  @spec triage_seeded_fixture_catalog() :: %{String.t() => Stage.t()}
  def triage_seeded_fixture_catalog do
    key_named(%{
      "triage" =>
        stage(
          unit: {:seed, "triage"},
          routes: ["talk", "sketch", "code", "system"],
          sub: ["request-received"],
          req: ["request"],
          out: ["intent"],
          pub: ["plan-needed", "code", "system", "scope-shift"]
        ),
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft an implementation plan from the intent; emit plan-ready.",
          routes: ["code", "system"],
          sub: ["plan-needed"],
          req: ["intent"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "approver" =>
        stage(
          unit: {:worker_template, "verifier"},
          task: "Approve the plan; emit plan-approved with the approved-plan.",
          routes: ["code", "system"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["approved-plan"],
          pub: ["plan-approved", "scope-shift"]
        ),
      "implementer" =>
        stage(
          unit: {:worker_template, "coder"},
          task: "Implement the approved plan; emit code-written and auth-surface.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          opt: ["approved-plan"],
          out: ["diff"],
          pub: ["code-written", "auth-surface", "scope-shift"],
          lock: [%{while: "plan-ready", until: "plan-approved"}]
        ),
      "quality-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          task: "Review the diff for quality; flag findings, else emit clean:quality.",
          routes: ["code"],
          sub: ["code-written"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:quality", "findings:quality", "scope-shift"]
        ),
      "security-reviewer" =>
        stage(
          unit: {:worker_template, "reviewer"},
          lens: "security",
          task: "Review the diff for auth-surface; flag findings, else emit clean:security.",
          routes: ["code"],
          sub: ["auth-surface"],
          req: ["diff"],
          out: ["findings"],
          pub: ["clean:security", "findings:security", "scope-shift"]
        )
    })
  end

  @doc """
  The triage-seeded live signals (Option A): the seed signal + the `code` path +
  triage's `plan-needed` publish. `request-received` stays in the seed (the honest
  durable record); `triage ∈ ran` is what makes it inert (rejected alternative B
  omitted it and worked only by accident).
  """
  @spec triage_seed_live() :: [String.t()]
  def triage_seed_live, do: ["request-received", "code", "plan-needed"]

  @doc """
  The triage-seeded artifact store: the seed `request` plus the triage-produced
  `intent` (non-empty — `planner` requires it and the router is key-presence based,
  so a nil intent would falsely satisfy the requirement).
  """
  @spec triage_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def triage_seed_artifacts do
    %{
      "request" => %{"seed" => "Build the auth feature"},
      "intent" => %{"triage" => "Build the auth feature"}
    }
  end

  @doc "The Option-A `ran` seed — `triage` pre-marked as already-run."
  @spec triage_seed_ran() :: [String.t()]
  def triage_seed_ran, do: ["triage"]

  # ---------------------------------------------------------------------------
  # Phase-4 gate fixtures (AR-2 §9/§14 — the human plan gate in the composer)
  # ---------------------------------------------------------------------------

  @doc """
  A validator-clean, **gate-bearing** catalog: `planner → plan-gate →
  implementer`, the implementer locked `while: plan-ready until: plan-approved`.

  `plan-gate` is a real `{:gate, "plan"}` unit (driven by
  `JidoClaw.Orchestration.Reactors.PlanGate`), so the route holds the implementer
  until the gate is approved (then releases it) and converges; reject/abandon
  take the route terminal. Smaller than the built-in catalog (no reviewers), so
  the park/wake/reject/abandon integration tests drive a 3-wave route
  (`planner → plan-gate(park) → implementer`).
  """
  @spec gate_fixture_catalog() :: %{String.t() => Stage.t()}
  def gate_fixture_catalog do
    key_named(%{
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft an implementation plan from the request; emit plan-ready.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "plan-gate" =>
        stage(
          unit: {:gate, "plan"},
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["approved-plan"],
          pub: ["plan-approved", "plan-rejected", "plan-abandoned", "scope-shift"]
        ),
      "implementer" =>
        stage(
          unit: {:worker_template, "coder"},
          task: "Implement the approved plan; emit code-written.",
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          opt: ["approved-plan"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"],
          lock: [%{while: "plan-ready", until: "plan-approved"}]
        )
    })
  end

  @doc "The gate-fixture seed live signals: the seed signal + the `code` path."
  @spec gate_fixture_seed_live() :: [String.t()]
  def gate_fixture_seed_live, do: ["request-received", "code"]

  @doc "The gate-fixture seed artifact store (the seed `request`)."
  @spec gate_fixture_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def gate_fixture_seed_artifacts, do: %{"request" => %{"seed" => "Build the auth feature"}}

  @doc """
  The `template => canned typed output` map for the gate fixture: the `researcher`
  (planner) emits `plan-ready` + the `plan` artifact; the `coder` (implementer)
  emits `code-written` + the `diff` artifact. The gate has no worker — it is a
  real `Reactors.PlanGate` driven by `Cases.decide/4` directly.
  """
  @spec gate_fixture_stub_outputs() :: %{String.t() => map()}
  def gate_fixture_stub_outputs do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: build the auth feature"},
      "coder" => %{"signals" => ["code-written"], "diff" => "DIFF: +def authenticate(user)"}
    }
  end

  @doc """
  The gate fixture with the **re-plan opt-in** (Phase 4e §15.8): the planner also
  `subscribes: ["plan-rejected"]`, so a gate reject re-fires the planner and
  re-earns approval (rather than terminating). Same stub outputs as the gate
  fixture (`gate_fixture_stub_outputs/0`).
  """
  @spec gate_replan_fixture_catalog() :: %{String.t() => Stage.t()}
  def gate_replan_fixture_catalog do
    catalog = gate_fixture_catalog()
    planner = %{catalog["planner"] | subscribes: ["request-received", "plan-rejected"]}
    %{catalog | "planner" => planner}
  end

  @doc """
  A gate fixture exercising the Phase-4e **stale-approval** retraction: a
  `rescoper` runs after approval (sub `plan-approved`, requires `approved-plan`)
  and publishes `scope-shift` — a premise break — while the implementer is still
  held (it requires the rescoper's `rescope` output, so it is ordered after).
  Folding that `scope-shift` (with `plan-approved` live + implementer not run)
  retracts `plan-approved` and re-gates; the rescoper stays in `ran` (not
  invalidated), so it does not re-fire, and the route converges after a single
  re-approval.
  """
  @spec stale_approval_fixture_catalog() :: %{String.t() => Stage.t()}
  def stale_approval_fixture_catalog do
    key_named(%{
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft an implementation plan; emit plan-ready.",
          routes: ["code"],
          sub: ["request-received"],
          req: ["request"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "plan-gate" =>
        stage(
          unit: {:gate, "plan"},
          routes: ["code"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["approved-plan"],
          pub: ["plan-approved", "plan-rejected", "plan-abandoned", "scope-shift"]
        ),
      "rescoper" =>
        stage(
          unit: {:worker_template, "verifier"},
          task: "Re-check scope against the approved plan; emit scope-shift on a premise break.",
          routes: ["code"],
          sub: ["plan-approved"],
          req: ["approved-plan"],
          out: ["rescope"],
          pub: ["scope-shift"]
        ),
      "implementer" =>
        stage(
          unit: {:worker_template, "coder"},
          task: "Implement the approved plan; emit code-written.",
          routes: ["code"],
          sub: ["plan-approved"],
          req: ["plan", "rescope"],
          opt: ["approved-plan"],
          out: ["diff"],
          pub: ["code-written", "scope-shift"],
          lock: [%{while: "plan-ready", until: "plan-approved"}]
        )
    })
  end

  @doc """
  Stub outputs for `stale_approval_fixture_catalog/0`: the `verifier` (rescoper)
  emits `scope-shift` + the `rescope` artifact (the premise break, fired once);
  `researcher`/`coder` as in the gate fixture.
  """
  @spec stale_approval_stub_outputs() :: %{String.t() => map()}
  def stale_approval_stub_outputs do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: build the auth feature"},
      "verifier" => %{
        "signals" => ["scope-shift"],
        "rescope" => "RESCOPE: tighten the auth scope"
      },
      "coder" => %{"signals" => ["code-written"], "diff" => "DIFF: +def authenticate(user)"}
    }
  end

  # ---------------------------------------------------------------------------
  # AR-8c system-path fixtures (the reverse-verify loop)
  # ---------------------------------------------------------------------------

  @doc """
  A validator-clean catalog mirroring the AR-8c **system** path:
  `triage(seed) → planner → safety-gate → system-executor(held) →
  system-verifier(reverse_verify)`. The verifier subscribes the `system` path
  signal (published by triage, so the catalog validates) and depends on
  `system-change` via `input.required` (the data edge that orders it after the
  executor). A `findings:system` re-fires `{system-executor, system-verifier}`;
  the executor is held until `safety-approved` and never re-gated on retry.
  """
  @spec system_verify_loop_fixture_catalog() :: %{String.t() => Stage.t()}
  def system_verify_loop_fixture_catalog do
    key_named(%{
      "triage" =>
        stage(
          unit: {:seed, "triage"},
          routes: ["talk", "sketch", "code", "system"],
          sub: ["request-received"],
          req: ["request"],
          out: ["intent"],
          pub: ["plan-needed", "system", "scope-shift"]
        ),
      "planner" =>
        stage(
          unit: {:worker_template, "researcher"},
          task: "Draft a plan for the machine change from the intent; emit plan-ready.",
          routes: ["system"],
          sub: ["plan-needed"],
          req: ["intent"],
          out: ["plan"],
          pub: ["plan-ready", "scope-shift"]
        ),
      "safety-gate" =>
        stage(
          unit: {:gate, "safety"},
          routes: ["system"],
          sub: ["plan-ready"],
          req: ["plan"],
          out: ["approved-change"],
          pub: ["safety-approved", "scope-shift"]
        ),
      "system-executor" =>
        stage(
          unit: {:worker_template, "system_executor"},
          task: "Apply the approved change to the machine; report what changed.",
          routes: ["system"],
          sub: ["plan-ready"],
          req: ["plan"],
          opt: ["verify-feedback"],
          out: ["system-change"],
          pub: ["scope-shift"],
          lock: [%{while: "plan-ready", until: "safety-approved"}]
        ),
      "system-verifier" =>
        stage(
          unit: {:worker_template, "system_verifier"},
          lens: "system",
          reverse_verify: true,
          task: "Verify the change took; emit clean:system, else findings:system.",
          routes: ["system"],
          sub: ["system"],
          req: ["system-change"],
          out: ["findings"],
          pub: ["clean:system", "findings:system", "scope-shift"]
        )
    })
  end

  @doc "The system-loop seed live: the seed signal + the `system` path + triage's `plan-needed`."
  @spec system_loop_seed_live() :: [String.t()]
  def system_loop_seed_live, do: ["request-received", "system", "plan-needed"]

  @doc "The system-loop seed artifact store: the seed `request` + triage's `intent`."
  @spec system_loop_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def system_loop_seed_artifacts do
    %{
      "request" => %{"seed" => "Update the nginx config and reload"},
      "intent" => %{"triage" => "Update the nginx config and reload"}
    }
  end

  @doc "The system-loop Option-A `ran` seed — `triage` pre-marked as already-run."
  @spec system_loop_seed_ran() :: [String.t()]
  def system_loop_seed_ran, do: ["triage"]

  @doc """
  The `:agent_templates_override` map pointing the system-loop templates
  (`researcher` planner + `system_executor` + `system_verifier`) at `module` (the
  `SystemLoopWorker` stub — the gate has no worker).
  """
  @spec system_loop_template_override(module()) :: %{String.t() => map()}
  def system_loop_template_override(module) do
    Map.new(~w(researcher system_executor system_verifier), fn name ->
      {name, stub_template(module, "system-loop stub")}
    end)
  end

  @doc """
  The static `template => canned typed output` map for the system loop: the
  `researcher` (planner) emits `plan-ready` + the `plan` artifact; the
  `system_executor` produces the `system-change` artifact (NO signals — ordered
  by the data edge). The `system_verifier` output is NOT here — it is
  counter-driven by `SystemLoopWorker` (findings:system then clean:system).
  """
  @spec system_loop_stub_outputs() :: %{String.t() => map()}
  def system_loop_stub_outputs do
    %{
      "researcher" => %{"signals" => ["plan-ready"], "plan" => "PLAN: update nginx + reload"},
      "system_executor" => %{"system-change" => "CHANGE: wrote nginx.conf, reloaded the service"}
    }
  end

  # ---------------------------------------------------------------------------
  # AR-9 armed multi-plan fixtures (the judge-panel wave on the REAL catalog)
  # ---------------------------------------------------------------------------

  @doc """
  The armed front-door seed (mimics `FrontDoor.seed_live/2` for an armed `code`
  verdict): `multi-plan` INSTEAD OF `plan-needed`, plus the mapped
  `significant-build` early signal — the arming conjunction's other half.
  """
  @spec armed_seed_live() :: [String.t()]
  def armed_seed_live, do: ["request-received", "code", "multi-plan", "significant-build"]

  @doc "The armed seed artifact store (the Option-A `request` + `intent`)."
  @spec armed_seed_artifacts() :: %{String.t() => %{String.t() => String.t()}}
  def armed_seed_artifacts do
    %{
      "request" => %{"seed" => "Build the orchestration subsystem"},
      "intent" => %{"triage" => "Build the orchestration subsystem"}
    }
  end

  @doc """
  The `:agent_templates_override` for an armed run on the REAL catalog: the
  phase-1 override (researcher/verifier/coder/reviewer/fixer) plus the three
  AR-9 plan-wave templates, all pointed at `module`.
  """
  @spec armed_template_override(module()) :: %{String.t() => map()}
  def armed_template_override(module) do
    Map.merge(
      phase1_template_override(module),
      Map.new(~w(plan_drafter plan_challenger plan_arbiter), fn name ->
        {name, stub_template(module, "armed stub")}
      end)
    )
  end

  @doc """
  The armed stub outputs — FULLY schema-shaped (the stub path stamps
  `:validated`, bypassing Zoi, so each map carries exactly the fields the real
  schema produces): NO dynamic artifact keys (every `plan:<lens>` /
  `critique:<lens>` / `decision-memo` / `plan` / `diff` artifact resolves via
  the summary fallback — the path a real run takes, since Zoi drops unknown
  keys) and NO canned `signals` anywhere (`scope-shift` IS declared on all
  seven new stages, so a canned one would trigger real rescope behavior
  mid-e2e; the finalizer's `plan-ready` and the implementer's `code-written`
  are loop-injected). The three per-stage drafter overrides MERGE the base
  drafter stub with a distinct summary — fully schema-shaped by construction —
  so the finalizer-context assertion can prove three meaningfully different
  plans arrive. `arbiter` swaps the memo map (adopt / revise_first variants).
  """
  @spec armed_stub_outputs(map()) :: map()
  def armed_stub_outputs(arbiter \\ armed_adopt_arbiter()) do
    drafter_stub = %{
      "summary" => "PLAN (lens draft): a competing plan.",
      "status" => "completed",
      "confidence" => "high",
      "artifacts" => %{}
    }

    %{
      # The finalizer planner (researcher) — full researcher shape; `plan`
      # resolves to THIS summary via the fallback.
      "researcher" => %{
        "summary" => "PLAN (final): adopt Plan A, smallest-shippable.",
        "status" => "completed",
        "confidence" => "high",
        "findings" => [],
        "artifacts" => %{}
      },
      # Template-key fallback for any drafter stage a fragment doesn't cover.
      "plan_drafter" => drafter_stub,
      {"plan_drafter", "smallest-shippable"} =>
        Map.put(drafter_stub, "summary", "PLAN A: minimal viable slice."),
      {"plan_drafter", "risk-first"} =>
        Map.put(drafter_stub, "summary", "PLAN B: de-risk the hard part first."),
      {"plan_drafter", "reuse-first"} =>
        Map.put(drafter_stub, "summary", "PLAN C: reuse the existing pipeline."),
      # One challenger map serves all three challenger stages.
      "plan_challenger" => %{
        "summary" => "CRITIQUE: blockers/concerns/strengths.",
        "status" => "completed",
        "confidence" => "high",
        "blockers" => [],
        "concerns" => ["over-scoped"],
        "strengths" => ["reuses tested code"],
        "artifacts" => %{}
      },
      "plan_arbiter" => arbiter,
      # The post-gate half: a coder-schema-shaped implementer (`diff` = summary
      # fallback; `code-written` loop-injected) + clean reviewers.
      "coder" => %{
        "summary" => "DIFF: implemented the adopted plan.",
        "status" => "completed",
        "files_changed" => ["lib/feature.ex"],
        "notes" => "n/a",
        "artifacts" => %{}
      },
      "reviewer" => phase1_clean_reviewer()
    }
  end

  @doc "The armed ADOPT arbiter memo (fully schema-shaped)."
  @spec armed_adopt_arbiter() :: %{String.t() => term()}
  def armed_adopt_arbiter do
    %{
      "summary" =>
        "DECISION MEMO — verdict: adopt. Selected Plan A (smallest-shippable). " <>
          "Tie-break: correctness.",
      "status" => "completed",
      "confidence" => "high",
      "assessments" => [],
      "tie_break_rung" => "correctness",
      "selection" => "smallest-shippable",
      "verdict" => "adopt",
      "revision_directive" => "none",
      "artifacts" => %{}
    }
  end

  @doc """
  The REVISE_FIRST arbiter variant — differs from `armed_adopt_arbiter/0` ONLY
  in summary/verdict/directive (the assertion that pins "no verdict-driven
  routing": the route is identical on every verdict).
  """
  @spec armed_revise_first_arbiter() :: %{String.t() => term()}
  def armed_revise_first_arbiter do
    armed_adopt_arbiter()
    |> Map.put(
      "summary",
      "DECISION MEMO — verdict: revise_first. No plan is safe as written; " <>
        "resolve the rollback blocker, then redraft."
    )
    |> Map.put("verdict", "revise_first")
    |> Map.put("revision_directive", "resolve the rollback blocker before implementation")
  end

  # ===========================================================================
  # Crash-recovery / WS3-reclaim crafting fixtures (shared by composer_durable_test
  # + reclaim_pooler_test). DB-touching: they create real parent/child runs and
  # drive them through the durable event log. Extracted from composer_durable_test
  # for cross-suite reuse; `ctx` is the test context (`%{tenant:, actor:, context:}`).
  # ===========================================================================

  @doc """
  The base composer-launch opts for the phase-1 catalog — catalog + seed
  live/artifacts + tenant/actor/context + `max_waves: 10`.
  """
  @spec base_opts(map()) :: keyword()
  def base_opts(ctx) do
    [
      catalog: phase1_catalog(),
      live: phase1_seed_live(),
      artifacts: phase1_seed_artifacts(),
      tenant: ctx.tenant,
      actor: ctx.actor,
      context: ctx.context,
      max_waves: 10
    ]
  end

  @doc """
  A recoverable composer parent: `create_parent_run` with the full `base_opts/1`, so
  `config` carries the serialized catalog + bounds and genesis records the seed
  live/artifacts events. `extra_opts` adds e.g. premises / the sensitive marker.
  """
  @spec recoverable_parent(map(), keyword()) :: WorkflowRun.t()
  def recoverable_parent(ctx, extra_opts \\ []) do
    {:ok, parent} = RouteComposer.create_parent_run(Keyword.merge(base_opts(ctx), extra_opts))
    parent
  end

  @doc """
  Create a wave child under the deterministic `composer:<parent>:<wave>` launch key
  and drive it to `status` via its own event log.
  """
  @spec craft_child(WorkflowRun.t(), map(), non_neg_integer(), atom()) :: WorkflowRun.t()
  def craft_child(parent, ctx, wave_index, status) do
    {:ok, child} =
      WorkflowRun.create(
        %{
          name: "wave-#{wave_index}",
          workflow_type: "reactor",
          parent_run_id: parent.id,
          idempotency_key: "composer:#{parent.id}:#{wave_index}"
        },
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    drive_child(child, status, ctx)
  end

  @doc """
  Commit wave 0's durable fold (the dropped-fold recovery shape): store the plan as a
  `:pending` row that `Commit.commit_wave` activates, alongside `wave_completed` + the
  content deltas.
  """
  @spec commit_wave0(WorkflowRun.t(), WorkflowRun.t(), map()) :: :ok
  def commit_wave0(parent, child, ctx) do
    # Route through the single production construction site for the wave-artifact
    # create-attrs shape (`child.parent_run_id == parent.id`, so semantics are
    # identical to the former inline `store_pending`) so the fixture is NOT a third
    # copy of that 7-key map (`.reach.exs` `fixed_shape_map`).
    {:ok, plan_ref} =
      ComposerArtifact.store_wave_artifact(
        "plan",
        "planner",
        "PLAN: build the auth feature",
        child,
        0,
        tenant: ctx.tenant,
        actor: ctx.actor
      )

    deltas = %{
      stages: ["planner"],
      signals_published: ["plan-ready"],
      signals_retracted: [],
      artifacts_produced: [%{name: "plan", producer: "planner", ref: plan_ref}]
    }

    :ok = Commit.commit_wave(parent, 0, deltas, tenant: ctx.tenant, actor: ctx.actor)
  end

  defp drive_child(child, :pending, _ctx), do: child

  defp drive_child(child, :running, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    reload(child.id, ctx)
  end

  defp drive_child(child, :completed, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :run_completed, %{result: %{}}, ctx)
    reload(child.id, ctx)
  end

  defp drive_child(child, :cancelled, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :run_cancelled, %{}, ctx)
    reload(child.id, ctx)
  end

  # `run_abandoned` is legal only from :awaiting_approval (projection guard), so park
  # the child via approval_requested first.
  defp drive_child(child, :abandoned, ctx) do
    {:ok, _} = append_event(child, :run_started, %{}, ctx)
    {:ok, _} = append_event(child, :approval_requested, %{}, ctx)
    {:ok, _} = append_event(child, :run_abandoned, %{}, ctx)
    reload(child.id, ctx)
  end

  defp append_event(run, kind, payload, ctx),
    do: WorkflowLog.append(run, kind, payload, tenant: ctx.tenant, actor: ctx.actor)

  defp reload(run_id, ctx) do
    {:ok, run} = WorkflowRun.by_id(run_id, tenant: ctx.tenant, actor: ctx.actor)
    run
  end

  # Stamp each stage's `name` from its catalog key.
  defp key_named(map) do
    Map.new(map, fn {name, stage} -> {name, %{stage | name: name}} end)
  end

  # The ONE construction site for a stub template-override entry — the three
  # override builders share it so the map shape exists once (reach
  # `fixed_shape_map` counts shape repeats across test/support).
  defp stub_template(module, description) do
    %{module: module, description: description, model: :fast, max_iterations: 1}
  end
end
