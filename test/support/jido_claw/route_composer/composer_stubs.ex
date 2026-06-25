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
  def ask(_pid, _task, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    tool_context = Keyword.fetch!(opts, :tool_context)
    template = Map.fetch!(tool_context, :agent_template)

    maybe_capture_context(template, tool_context)

    outputs = Application.fetch_env!(:jido_claw, :route_composer_stub_outputs)
    typed = Map.fetch!(outputs, template)

    StubStore.put(request_id, %{
      status: :completed,
      result: typed,
      meta: %{output: %{status: :validated, schema_kind: :map}}
    })

    {:ok, %{id: request_id}}
  end

  # Optional context capture (AR-2 Phase 3b recovery test): when
  # `:route_composer_capture_context` is a pid, report the `tool_context` a wave
  # worker received, so a test can assert a recovered composer threaded the
  # persisted-then-re-atomized scope (real `workspace_id`/`project_dir`/
  # `session_uuid`, not the `wf_<tag>` / `File.cwd!()` fallback). Off by default.
  defp maybe_capture_context(template, tool_context) do
    case Application.get_env(:jido_claw, :route_composer_capture_context) do
      pid when is_pid(pid) -> send(pid, {:wave_context, template, tool_context})
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

  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, opts) do
    request_id = request_id_from(opts)

    case StubStore.fetch(request_id) do
      {:ok, canned} -> {:ok, %{status: :completed, result: canned}}
      :error -> {:ok, %{status: :failed, result: {:no_canned_output, request_id}}}
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
  @spec await_completion(pid(), keyword()) :: {:ok, map()}
  def await_completion(_pid, _opts) do
    Process.sleep(Application.get_env(:jido_claw, :route_composer_block_ms, 600))
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
  AR-8c reverse-verify-loop worker stub. Like `StubWorker` (one shared agent wired
  in as every system-path worker template), but the `system_verifier` template's
  output is **counter-driven**: it returns a `request_changes` (→ `findings:system`)
  verdict for the first `:route_composer_system_verify_fails` invocations (default
  1), then `approve` (→ `clean:system`) — so the reverse-verify loop re-fires the
  executor + verifier and then converges (or, with the cap below the fail count,
  exhausts into `:route_verify_failed`). Every other template falls back to the
  static `:route_composer_stub_outputs` map (the planner + the executor).
  """

  use Jido.Agent,
    name: "route_composer_system_loop_worker",
    description: "AR-8c system reverse-verify-loop stub worker (exports ask/3)"

  alias JidoClaw.RouteComposer.TestSupport.StubStore

  @spec ask(pid(), term(), keyword()) :: {:ok, %{id: term()}}
  def ask(_pid, _task, opts) when is_list(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    tool_context = Keyword.fetch!(opts, :tool_context)
    template = Map.fetch!(tool_context, :agent_template)

    StubStore.put(request_id, %{
      status: :completed,
      result: output_for(template),
      meta: %{output: %{status: :validated, schema_kind: :map}}
    })

    {:ok, %{id: request_id}}
  end

  # The verifier verdict flips from findings → clean once the per-test fail count
  # is exhausted. `StubStore.bump/1` is atomic; the verifier runs one wave at a
  # time (sequential), so no race.
  defp output_for("system_verifier") do
    n = StubStore.bump(:system_verifier_calls)
    fails = Application.get_env(:jido_claw, :route_composer_system_verify_fails, 1)

    if n <= fails do
      %{
        "overall" => "request_changes",
        "findings" => [%{"severity" => "error", "description" => "the change did not take"}]
      }
    else
      %{"overall" => "approve", "findings" => []}
    end
  end

  defp output_for(template) do
    :jido_claw
    |> Application.fetch_env!(:route_composer_stub_outputs)
    |> Map.fetch!(template)
  end
end
