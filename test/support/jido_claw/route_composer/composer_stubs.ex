defmodule JidoClaw.RouteComposer.TestSupport.StubStore do
  @moduledoc """
  A public named ETS table mapping `request_id => canned request map`, shared
  between the two halves of the route-composer worker stub (`StubWorker.ask/3`
  writes, `StubAgentServer.await_completion/2` reads).

  Request-id keying — not a FIFO queue — is what lets the two reviewer steps that
  run concurrently in W3 each get *their* canned output without racing. The
  integration test owns the table (created in `setup/0`, auto-deleted when the
  test process dies).
  """

  @table :route_composer_stub_store

  @doc "Create (or clear) the shared table. Call from test setup."
  @spec setup() :: :ok
  def setup do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Stamp `canned` under `request_id`."
  @spec put(term(), term()) :: true
  def put(request_id, canned), do: :ets.insert(@table, {request_id, canned})

  @doc "Fetch the canned request map for `request_id`."
  @spec fetch(term()) :: {:ok, term()} | :error
  def fetch(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, canned}] -> {:ok, canned}
      [] -> :error
    end
  end

  @doc """
  Atomically increment and return the integer counter at `key` (default 0 →
  first call returns 1). Used by `SystemLoopWorker` to make the
  `system_verifier`'s verdict change across the AR-8c reverse-verify re-fires.
  """
  @spec bump(term()) :: integer()
  def bump(key) do
    ensure_table()
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _tid -> :ok
    end
  end
end

defmodule JidoClaw.RouteComposer.TestSupport.StubWorker do
  @moduledoc """
  A Phase-1 composer worker stub — one shared `Jido.Agent` module wired in as
  every template via `:agent_templates_override`.

  Exports `ask/3` so `JidoClaw.Skills.Steps.AgentRunner` routes through the async
  typed-output path (`function_exported?(module, :ask, 3)`). It picks its canned
  typed output by the `:agent_template` on the `tool_context` it is handed,
  stamps `request_id => canned` into `StubStore`, and returns `{:ok, %{id:
  request_id}}` so the runner's `{:ok, %{id: ^request_id}}` match succeeds. The
  paired `StubAgentServer` reads that request back. No LLM — precommit stays
  hermetic.
  """

  use Jido.Agent,
    name: "route_composer_stub_worker",
    description: "Phase-1 route-composer stub worker (exports ask/3)"

  alias JidoClaw.RouteComposer.TestSupport.StubStore

  @spec ask(pid(), term(), keyword()) :: {:ok, %{id: term()}}
  def ask(_pid, task, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    tool_context = Keyword.fetch!(opts, :tool_context)
    template = Map.fetch!(tool_context, :agent_template)

    maybe_capture(:route_composer_capture_context, {:wave_context, template, tool_context})
    maybe_capture(:route_composer_capture_task, {:wave_task, template, task})

    outputs = Application.fetch_env!(:jido_claw, :route_composer_stub_outputs)
    typed = lookup_output!(outputs, template, task)

    StubStore.put(request_id, %{
      status: :completed,
      result: typed,
      meta: %{output: %{status: :validated, schema_kind: :map}}
    })

    {:ok, %{id: request_id}}
  end

  # AR-9 per-STAGE override: `tool_context` carries `:agent_template` but not
  # the stage name, so two stages over one template are told apart by a task
  # fragment — `{template, fragment}` tuple keys beside the plain template
  # keys. Matching is deterministic and LOUD: when any tuple keys exist for the
  # resolved template, exactly ONE fragment must match the assembled task —
  # zero or several matches raise (a silent fallback or arbitrary pick would
  # feed the wrong canned plan to the mapper and quietly weaken the e2e). Only
  # a template with NO tuple keys falls back to the plain template key, so
  # plain-keyed existing fixtures are untouched.
  defp lookup_output!(outputs, template, task) do
    case for {{^template, fragment}, _out} <- outputs, do: fragment do
      [] ->
        Map.fetch!(outputs, template)

      fragments ->
        case Enum.filter(fragments, &String.contains?(task, &1)) do
          [fragment] ->
            Map.fetch!(outputs, {template, fragment})

          matched ->
            raise "expected exactly one {#{inspect(template)}, fragment} stub to match the " <>
                    "task, got #{inspect(matched)} from fragments #{inspect(fragments)} " <>
                    "for task: #{inspect(task)}"
        end
    end
  end

  # Optional capture hooks, one shared sender (env key → message), off by default:
  #   * `:route_composer_capture_context` (AR-2 Phase 3b recovery test) →
  #     `{:wave_context, template, tool_context}` — assert a recovered composer
  #     threaded the persisted-then-re-atomized scope (real `workspace_id`/
  #     `project_dir`/`session_uuid`, not the `wf_<tag>` / `File.cwd!()`
  #     fallback); also carries the AR-9 stage-tier key.
  #   * `:route_composer_capture_task` (AR-9 premises threading) →
  #     `{:wave_task, template, task}` — assert the assembled wave task carries
  #     (or byte-identically omits) the rendered `### Premises` block.
  defp maybe_capture(env_key, message) do
    case Application.get_env(:jido_claw, env_key) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end

defmodule JidoClaw.RouteComposer.TestSupport.StubAgentServer do
  @moduledoc """
  The `:step_agent_server` half of the Phase-1 worker stub — stubs
  `Jido.AgentServer.await_completion/2` by reading the `request_id` from the
  runner's `result_path` opt (`[:requests, request_id]`, `agent_runner.ex:179`)
  and returning **that** request's canned map from `StubStore`, so
  `Output.typed_request_output/1` yields the canned typed output.
  """

  alias JidoClaw.RouteComposer.TestSupport.StubStore
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    request_id = request_id_from(opts)

    case StubStore.fetch(request_id) do
      {:ok, canned} ->
        TerminalSignal.emit_completed(request_id)
        {:ok, %{status: :completed, result: canned}}

      :error ->
        TerminalSignal.emit_failed(request_id)
        {:ok, %{status: :failed, result: {:no_canned_output, request_id}}}
    end
  end

  defp request_id_from(opts) do
    [:requests, request_id | _rest] = Keyword.fetch!(opts, :result_path)
    request_id
  end
end

defmodule JidoClaw.RouteComposer.TestSupport.BlockingAgentServer do
  @moduledoc """
  A `:step_agent_server` stub whose `await_completion/2` blocks for a bounded
  `block_ms` (app env, default 600) — long enough to outlast a short
  `RouteComposer.run_sync/1` timeout (so the timeout always fires), short enough
  that the orphaned (`async_nolink`) wave executor drains quickly within the
  test's sandbox once released by the sleep.
  """
  alias JidoClaw.Test.TerminalSignal

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    Process.sleep(Application.get_env(:jido_claw, :route_composer_block_ms, 600))
    # A *late* terminal run, not a never-completing one: the drained wave still
    # finishes (failed), so its transcript flush deserves the terminal signal.
    TerminalSignal.emit_from_await(opts, "ai.request.failed")
    {:ok, %{status: :failed, result: :blocked}}
  end
end

defmodule JidoClaw.RouteComposer.TestSupport.GatedAgentServer do
  @moduledoc """
  A one-shot gated `:step_agent_server` stub (AR-2 Phase 2c supervised-resume
  tests). The FIRST `await_completion/2` call (the first wave) atomically disarms
  a shared gate, signals the configured test pid with its OWN (wave-executor) pid,
  and blocks until that pid sends `:proceed` — letting a test catch the composer
  mid-wave, kill it, drive the `:transient` restart, and exercise the dedupe-hit
  observe path against a still-`:running` child. Every later call delegates
  straight to `StubAgentServer` (normal canned output). `async: false` + a
  single-stage first wave means no concurrent caller races the gate.
  """
  alias JidoClaw.RouteComposer.TestSupport.StubAgentServer

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(pid, opts) do
    if disarm?() do
      send(Application.fetch_env!(:jido_claw, :route_composer_gate_pid), {:wave_gate, self()})

      receive do
        :proceed -> :ok
      after
        15_000 -> :ok
      end
    end

    StubAgentServer.await_completion(pid, opts)
  end

  defp disarm? do
    if Application.get_env(:jido_claw, :route_composer_gate_armed, false) do
      Application.put_env(:jido_claw, :route_composer_gate_armed, false)
      true
    else
      false
    end
  end
end

defmodule JidoClaw.RouteComposer.TestSupport.SystemLoopWorker do
  @moduledoc """
  AR-8c reverse-verify-loop + AR-4 self-heal worker stub. Like `StubWorker` (one
  shared agent wired in as every templated worker), but three templates are
  **driven**, not static:

    * `system_verifier` (AR-8c) — **counter-driven**: `request_changes` (→
      `findings:system`) for the first `:route_composer_system_verify_fails`
      invocations (default 1), then `approve` (→ `clean:system`).
    * `reviewer` (AR-4) — **per-lens** verdict, deterministic and race-free: the
      lens is derived from the reviewer's task (it names its `clean:<lens>`
      target), and a per-lens counter + the `:route_composer_review_flag_on`
      config (`%{lens => [call_numbers] | :always}`) decide flag-vs-clean — so two
      same-template reviewers in one parallel wave never race a shared counter.
    * `fixer` (AR-4) — emits `code-written` + `auth-surface` (re-firing the
      touched lenses AND summoning the never-run `security` lens) and produces the
      `fix` artifact.

  Every other template falls back to the static `:route_composer_stub_outputs`
  map. Reuses `TestFixtures.phase1_{findings,clean}_reviewer/0` for the verdict
  bodies (no new verdict literals).
  """

  use Jido.Agent,
    name: "route_composer_system_loop_worker",
    description: "AR-8c/AR-4 reverse-verify + self-heal stub worker (exports ask/3)"

  alias JidoClaw.RouteComposer.TestFixtures
  alias JidoClaw.RouteComposer.TestSupport.StubStore

  @spec ask(pid(), term(), keyword()) :: {:ok, %{id: term()}}
  def ask(_pid, task, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    tool_context = Keyword.fetch!(opts, :tool_context)
    template = Map.fetch!(tool_context, :agent_template)

    StubStore.put(request_id, %{
      status: :completed,
      result: output_for(template, task),
      meta: %{output: %{status: :validated, schema_kind: :map}}
    })

    {:ok, %{id: request_id}}
  end

  # The verifier verdict flips from findings → clean once the per-test fail count
  # is exhausted. `StubStore.bump/1` is atomic; the verifier runs one wave at a
  # time (sequential), so no race.
  defp output_for("system_verifier", _task) do
    n = StubStore.bump(:system_verifier_calls)
    fails = Application.get_env(:jido_claw, :route_composer_system_verify_fails, 1)

    if n <= fails do
      %{
        "overall" => "request_changes",
        "summary" => "verification failed",
        "action_needed" => "re-apply the change; the machine state is unchanged",
        "findings" => [
          %{
            "severity" => "error",
            "confidence" => "likely",
            "location" => "host:/etc",
            "description" => "the change did not take"
          }
        ]
      }
    else
      %{
        "overall" => "approve",
        "summary" => "change verified on the machine",
        "action_needed" => "none",
        "findings" => []
      }
    end
  end

  # AR-4: a forward-lens reviewer. The lens comes from the task; the per-lens
  # counter + `:route_composer_review_flag_on` decide the verdict (race-free —
  # each lens has its own counter, each reviewer stage names a distinct lens).
  defp output_for("reviewer", task) do
    lens = lens_from_task(task)
    n = StubStore.bump({:reviewer_calls, lens})

    if review_flag?(lens, n),
      do: TestFixtures.phase1_findings_reviewer(),
      else: TestFixtures.phase1_clean_reviewer()
  end

  # AR-4: the self-heal fixer. By default emits `code-written` (re-fire the quality +
  # correctness lenses) AND `auth-surface` (summon the never-run security lens), and
  # produces the `fix` artifact the reviewers read on re-review. The signals are
  # overridable via `:route_composer_fixer_signals` so the P1 regression can drive a
  # fixer that OMITS `code-written` (`["auth-surface"]`) and prove injection re-adds
  # it (mirrors the reviewer/verifier env knobs; counter-free + non-contiguous).
  defp output_for("fixer", _task) do
    %{
      "signals" =>
        Application.get_env(:jido_claw, :route_composer_fixer_signals, [
          "code-written",
          "auth-surface"
        ]),
      "fix" => "FIX: resolved the open findings and touched the auth surface"
    }
  end

  defp output_for(template, _task) do
    :jido_claw
    |> Application.fetch_env!(:route_composer_stub_outputs)
    |> Map.fetch!(template)
  end

  # The reviewer's task names its `clean:<lens>` emit target — a stable, per-stage
  # discriminator (the rendered artifacts never contain a `clean:` topic).
  defp lens_from_task(task) do
    cond do
      String.contains?(task, "clean:quality") -> "quality"
      String.contains?(task, "clean:correctness") -> "correctness"
      String.contains?(task, "clean:security") -> "security"
      String.contains?(task, "clean:architecture") -> "architecture"
      true -> "unknown"
    end
  end

  # `:route_composer_review_flag_on` is `%{lens => [call_numbers] | :always}`; a
  # lens absent from the map never flags (always clean).
  defp review_flag?(lens, n) do
    case Map.get(Application.get_env(:jido_claw, :route_composer_review_flag_on, %{}), lens) do
      :always -> true
      calls when is_list(calls) -> n in calls
      _ -> false
    end
  end
end
