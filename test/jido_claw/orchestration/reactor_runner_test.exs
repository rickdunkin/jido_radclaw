defmodule JidoClaw.Orchestration.ReactorRunnerTest.OkStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_args, _context, _opts), do: {:ok, :done}
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest.NoMiddlewareReactor do
  @moduledoc false
  use Reactor

  step(:only, JidoClaw.Orchestration.ReactorRunnerTest.OkStep)
  return(:only)
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest.ContextEchoStep do
  @moduledoc false
  use Reactor.Step

  # Returns a json-safe projection of the (merged) context so a test can assert
  # the caller's `:context` map reached the step and the run-identity base won.
  @impl true
  def run(_args, context, _opts) do
    {:ok,
     %{tenant: context[:tenant], workspace_id: context[:workspace_id], reactor: context[:reactor]}}
  end
end

defmodule JidoClaw.Orchestration.ReactorRunnerTest do
  @moduledoc """
  Proves the two `ReactorRunner.run/3` review-finding fixes as a reusable seam:

    * Finding 1 — the runner auto-wires `ReactorMiddleware` into a reactor that
      declares none, so a successful run records the full timeline and never
      strands `:pending`. The struct augmentation is per-call (no shared DSL
      state leak across runs) and dedup-safe against a reactor that already
      declares the middleware (no double emission).
    * Finding 2 — the pre-run path honors the never-raises contract: a
      non-reactor module returns `{:error, {:not_a_reactor, mod}, nil}` and
      malformed (non-keyword) opts are normalized to `{:error, _, nil}` by the
      body-level rescue rather than raising to the caller.
  """
  use JidoClaw.TenantCase, async: false

  alias Ash.Resource.Info
  alias JidoClaw.Orchestration.DefinitionFingerprint
  alias JidoClaw.Orchestration.ReactorRunner
  alias JidoClaw.Orchestration.ReactorRunnerTest.ContextEchoStep
  alias JidoClaw.Orchestration.ReactorRunnerTest.NoMiddlewareReactor
  alias JidoClaw.Orchestration.Reactors.ProjectRegistration
  alias JidoClaw.Orchestration.WorkflowEvent
  alias JidoClaw.Orchestration.WorkflowRun
  alias Reactor.Argument
  alias Reactor.Builder

  setup do
    tenant = seed_tenant("reactor-runner")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  describe "middleware auto-wiring (Finding 1)" do
    test "injects ReactorMiddleware for a reactor that declares none", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert run.status == :completed

      # The full timeline proves the runner injected the middleware for a
      # reactor that never declared it.
      assert kinds(run, ctx) ==
               [:run_started, :step_started, :step_completed, :run_completed]
    end

    test "augmentation is per-call: two runs each emit exactly one terminal pair", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run_a} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert {:ok, :done, run_b} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      refute run_a.id == run_b.id

      # Per-call struct augmentation never accumulates middleware across runs.
      for run <- [run_a, run_b] do
        kinds = kinds(run, ctx)
        assert Enum.count(kinds, &(&1 == :run_started)) == 1
        assert Enum.count(kinds, &(&1 == :run_completed)) == 1
      end
    end

    test "dedup: a reactor already declaring the middleware emits no doubles", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, _workspace, run} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(),
                 tenant: tenant,
                 actor: actor
               )

      assert run.status == :completed

      kinds = kinds(run, ctx)
      assert Enum.count(kinds, &(&1 == :run_started)) == 1
      assert Enum.count(kinds, &(&1 == :run_completed)) == 1
    end
  end

  describe "ungated struct support (compiled skills) + :async? / :context opts" do
    test "runs a %Reactor{} struct, threads :context (base wins), captures result", ctx do
      %{tenant: tenant, actor: actor} = ctx

      struct =
        Builder.new()
        |> Builder.add_input!(:extra_context)
        |> Builder.add_step!(
          :echo,
          ContextEchoStep,
          [Argument.from_input(:extra_context, :extra_context)],
          async?: true,
          max_retries: 0
        )
        |> Builder.return!(:echo)

      assert {:ok, value, run} =
               ReactorRunner.run(struct, %{extra_context: "go"},
                 tenant: tenant,
                 actor: actor,
                 name: "my_skill",
                 async?: true,
                 context: %{workspace_id: "ws-123", tenant: "SHOULD_NOT_WIN"}
               )

      # :context reached the step; the run-identity base won the tenant clash;
      # the struct's identity is the :name opt.
      assert value == %{tenant: tenant, workspace_id: "ws-123", reactor: "my_skill"}

      assert run.status == :completed
      assert run.name == "my_skill"
      # json-safe result persisted (round-trips to string keys).
      assert run.result == %{
               "tenant" => tenant,
               "workspace_id" => "ws-123",
               "reactor" => "my_skill"
             }

      assert kinds(run, ctx) == [:run_started, :step_started, :step_completed, :run_completed]
    end

    test "a non-reactor struct value is not a reactor (pre-run envelope)", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:error, {:not_a_reactor, _}, nil} =
               ReactorRunner.run(%WorkflowRun{}, %{}, tenant: tenant, actor: actor)
    end
  end

  describe "replay provenance (Phase 4)" do
    test "a module run self-computes definition_hash, records module kind + inputs blob", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert run.definition_hash == DefinitionFingerprint.for_module(NoMiddlewareReactor)
      assert run.config["definition_kind"] == "module"
      assert is_nil(run.retry_of_id)

      # The inputs blob is present and encrypted at rest: the stored column is
      # ciphertext, NOT the raw term_to_binary envelope.
      assert is_binary(run.encrypted_replay_inputs)

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_term(run.encrypted_replay_inputs, [:safe])
      end
    end

    test "a struct run stores the caller's definition_hash verbatim with skill kind", ctx do
      %{tenant: tenant, actor: actor} = ctx
      original_id = Ash.UUID.generate()

      struct =
        Builder.new()
        |> Builder.add_input!(:extra_context)
        |> Builder.add_step!(
          :echo,
          ContextEchoStep,
          [Argument.from_input(:extra_context, :extra_context)],
          async?: true,
          max_retries: 0
        )
        |> Builder.return!(:echo)

      assert {:ok, _value, run} =
               ReactorRunner.run(struct, %{extra_context: "go"},
                 tenant: tenant,
                 actor: actor,
                 name: "my_skill",
                 definition_hash: "feedface",
                 retry_of_id: original_id,
                 context: %{project_dir: "/tmp/proj"}
               )

      assert run.definition_hash == "feedface"
      assert run.retry_of_id == original_id
      assert run.config["definition_kind"] == "skill"
      # project_dir from the caller's :context rides into config so Replay can
      # locate the skills dir without decoding the inputs blob first.
      assert run.config["project_dir"] == "/tmp/proj"
      assert is_binary(run.encrypted_replay_inputs)
    end

    test "a struct run without a definition_hash opt stores nil (no self-compute)", ctx do
      %{tenant: tenant, actor: actor} = ctx

      struct =
        Builder.new()
        |> Builder.add_input!(:extra_context)
        |> Builder.add_step!(
          :echo,
          ContextEchoStep,
          [Argument.from_input(:extra_context, :extra_context)],
          async?: true,
          max_retries: 0
        )
        |> Builder.return!(:echo)

      assert {:ok, _value, run} =
               ReactorRunner.run(struct, %{extra_context: "go"},
                 tenant: tenant,
                 actor: actor,
                 name: "anon_skill"
               )

      assert is_nil(run.definition_hash)
      assert run.config["definition_kind"] == "skill"
      refute Map.has_key?(run.config, "project_dir")
    end
  end

  describe "run-level deadline opt (T2-1)" do
    test "a valid :deadline opt stores the NORMALIZED policy in config", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{},
                 tenant: tenant,
                 actor: actor,
                 deadline: %{"within" => 600, "due_soon" => 60}
               )

      # Normalized at write (atom-keyed), string-keyed on jsonb read.
      assert run.config["deadline"] == %{"within" => 600, "due_soon" => 60}
    end

    test "an invalid :deadline opt is dropped, never a launch failure", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{},
                 tenant: tenant,
                 actor: actor,
                 deadline: %{"within" => -1}
               )

      refute Map.has_key?(run.config, "deadline")
    end

    test "no :deadline opt stores no config key", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      refute Map.has_key?(run.config, "deadline")
    end
  end

  describe "launch idempotency (T2-3)" do
    test "identity :unique_run_idempotency is declared with nils_distinct?", _ctx do
      identity =
        WorkflowRun
        |> Info.identities()
        |> Enum.find(&(&1.name == :unique_run_idempotency))

      assert %{keys: [:idempotency_key], nils_distinct?: true} = identity
    end

    test "the same key twice resolves to one run; the second call does no launch work", ctx do
      %{tenant: tenant, actor: actor} = ctx
      key = "idem-#{System.unique_integer([:positive])}"

      assert {:ok, :done, run} =
               ReactorRunner.run(NoMiddlewareReactor, %{},
                 tenant: tenant,
                 actor: actor,
                 idempotency_key: key
               )

      assert run.idempotency_key == key
      events_after_first = kinds(run, ctx)

      assert {:ok, {:existing_run, existing_id}, existing} =
               ReactorRunner.run(NoMiddlewareReactor, %{},
                 tenant: tenant,
                 actor: actor,
                 idempotency_key: key
               )

      # Same run, zero new events — the dedupe hit never reached Reactor.run.
      assert existing_id == run.id
      assert existing.id == run.id
      assert kinds(run, ctx) == events_after_first
    end

    test "the dedupe read precedes build work: a key hit wins over a junk reactor arg", ctx do
      %{tenant: tenant, actor: actor} = ctx
      key = "idem-prebuild-#{System.unique_integer([:positive])}"

      {:ok, seeded} =
        WorkflowRun.create(%{name: "seeded", idempotency_key: key},
          tenant: tenant,
          actor: actor
        )

      # 42 is neither a reactor module nor a struct — build_runnable would
      # reject it. The key hit must short-circuit FIRST: a duplicate launch
      # whose definition no longer resolves/builds still dedupes to the
      # existing run instead of erroring.
      assert {:ok, {:existing_run, existing_id}, existing} =
               ReactorRunner.run(42, %{}, tenant: tenant, actor: actor, idempotency_key: key)

      assert existing_id == seeded.id
      assert existing.id == seeded.id
    end

    test "concurrent same-key launches yield exactly one run", ctx do
      %{tenant: tenant, actor: actor} = ctx
      key = "idem-race-#{System.unique_integer([:positive])}"

      launch = fn ->
        ReactorRunner.run(NoMiddlewareReactor, %{},
          tenant: tenant,
          actor: actor,
          idempotency_key: key
        )
      end

      results = [Task.async(launch), Task.async(launch)] |> Task.await_many(15_000)

      # Both callers get an ok-envelope carrying the SAME run id, whichever
      # interleaving (read-hit or create-race backstop) each took.
      assert [{:ok, _value_a, run_a}, {:ok, _value_b, run_b}] = results
      assert run_a.id == run_b.id

      {:ok, runs} = WorkflowRun.list(tenant: tenant, actor: actor)
      assert Enum.count(runs, &(&1.idempotency_key == key)) == 1
    end

    test "no key means no dedupe: repeat launches create distinct nil-key runs", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:ok, :done, run_a} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      assert {:ok, :done, run_b} =
               ReactorRunner.run(NoMiddlewareReactor, %{}, tenant: tenant, actor: actor)

      refute run_a.id == run_b.id
      assert is_nil(run_a.idempotency_key)
      assert is_nil(run_b.idempotency_key)
    end
  end

  describe "never-raises pre-run path (Finding 2)" do
    test "a non-reactor module returns the pre-run envelope with no run", ctx do
      %{tenant: tenant, actor: actor} = ctx

      assert {:error, {:not_a_reactor, Enum}, nil} =
               ReactorRunner.run(Enum, %{}, tenant: tenant, actor: actor)
    end

    test "malformed (non-keyword) opts are normalized, not raised", ctx do
      %{tenant: tenant, actor: actor} = ctx

      # A map, not a keyword list: Keyword.get/fetch would raise, but the
      # body-level rescue normalizes it to the pre-run envelope. The match
      # itself proves no exception escaped.
      assert {:error, _reason, nil} =
               ReactorRunner.run(ProjectRegistration, valid_inputs(), %{
                 tenant: tenant,
                 actor: actor
               })
    end
  end

  defp valid_inputs do
    uniq = System.unique_integer([:positive])

    %{
      github_full_name: "o/r-#{uniq}",
      project_name: "proj-#{uniq}",
      workspace_name: "ws-#{uniq}",
      workspace_path: "/tmp/ws-#{uniq}"
    }
  end

  defp kinds(run, %{tenant: tenant, actor: actor}) do
    {:ok, events} = WorkflowEvent.for_run(run.id, tenant: tenant, actor: actor)
    Enum.map(events, & &1.kind)
  end
end
