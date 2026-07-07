defmodule JidoClaw.Skills.Steps.ForgeExecutor do
  @moduledoc """
  The `{:forge, :fake | :shell}` executor arm of
  `JidoClaw.Skills.Steps.AgentRunner` (item 7 / camus C1-1 PR-1 — the executor
  seam): runs one skill/composer step through a REAL minimal Forge session
  instead of an in-process `Jido.AI` worker.

  Plain ephemeral sessions only: `claim: false`, `sandbox: :local` (HostShell —
  a per-run tmp working dir; deliberately ignoring a prod `FORGE_SANDBOX=docker`
  so PR-1 executors never spin a microVM per stage), no MCP deposit endpoint /
  workspace mount / vendor creds (all PR-2). Lifecycle per step: mint a session
  id → `Forge.start_session_ready/3` asserting the HostShell backend (ReadyStart
  tears down its own partial session on failure) → one `Forge.run_iteration/2` →
  map to a `%StepResult{}` → always `Forge.stop_session/2` (`try/after` — the
  result is captured before teardown, and a genuine raise propagates to
  `AgentRunner`'s `run_recorded` boundary; the facade returns tagged tuples).
  Single-shot in PR-1: `:needs_input` (the PR-4 gate mapping), `:blocked` and
  `:continue` map to step errors.

    * `{:forge, :shell}` runs the template's operator-declared
      `executor_config.command` (the `verify_cmd` trust class — never the stage
      task) through `JidoClaw.Forge.Runners.Shell`. The command reaches the
      runner via `runner_config` (= `runner_state`); the `run_iteration` opts
      carry only `timeout:` — never `:command`, which the runner reads first.
    * `{:forge, :fake}` serves a caller-armed fixture from
      `Application.get_env(:jido_claw, :executor_fake_outputs)` through
      `JidoClaw.Forge.Runners.StaticFake` — the eval harness's deterministic
      fake-backed stage, armed by app-env alone.

  Fixture keys carry DISTINCT shapes so a stage key can never double as a
  fragment: `{:stage, template, step_name}` (exact step match, checked first) →
  `{:fragment, template, fragment}` (exactly ONE fragment must contain-match
  the task; zero or several fail closed) → the plain template name — with ANY
  tuple key for the template disabling the plain fallback (an unkeyed sibling
  stage of a keyed template is a fixture-authoring oversight — the composer
  StubWorker's no-silent-fallback rule, as lib code). Resolution happens before
  provisioning, so no session starts on a resolution failure.

  Both arms soft-validate the forge output against the template module's
  declared output schema (`strategy_opts()[:output]` via `Jido.AI.Output.parse/2`
  — binaries JSON-decode, so shell stdout gets the same validation): `{:ok, _}`
  ⇒ `typed_output`, anything else ⇒ `nil`, live-faithfully mirroring a live
  worker whose output validation failed (a lens stage with `typed: nil` rides
  the Verdict infra lane; a producer falls back to its result text) — never a
  fabricated verdict.
  """

  alias JidoClaw.Forge
  alias JidoClaw.Forge.Runner.HostShell
  alias JidoClaw.Forge.Runners.StaticFake
  alias JidoClaw.Reasoning.Output
  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Workflows.StepResult

  # Mirrors AgentRunner's @step_timeout_ms.
  @forge_step_timeout_ms 180_000

  @doc """
  Run one `{:forge, :fake | :shell}` step through a fresh ephemeral Forge
  session. `template` is the hydrated map from `Templates.get/1` (its
  `:executor` selects the kind); `context` is the Reactor context (tenant /
  workspace scope for the session spec). Returns the `AgentRunner` step
  contract: `{:ok, %StepResult{}}` or `{:error, binary()}`.
  """
  @spec run(String.t(), map(), String.t(), String.t() | nil, map()) ::
          {:ok, StepResult.t()} | {:error, binary()}
  def run(template_name, template, task, step_name, context) do
    {:forge, kind} = template.executor

    result =
      with {:ok, spec} <- build_spec(kind, template, template_name, task, step_name, context) do
        run_session(spec, template, template_name, step_name)
      end

    JidoClaw.Telemetry.emit_executor(kind, outcome(result))
    result
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, _}), do: :error

  # ---------------------------------------------------------------------------
  # Spec build — fail closed BEFORE any session starts.
  # ---------------------------------------------------------------------------

  defp build_spec(:shell, template, _template_name, _task, _step_name, context) do
    {:ok, session_spec(context, :shell, %{command: template.executor_config.command})}
  end

  defp build_spec(:fake, _template, template_name, task, step_name, context) do
    outputs = Application.get_env(:jido_claw, :executor_fake_outputs, %{})

    with {:ok, fixture} <- resolve_fixture(outputs, template_name, task, step_name) do
      {:ok, session_spec(context, StaticFake, %{fake_output: fixture})}
    end
  end

  # Plain ephemeral session spec, both kinds: `claim: false`, `sandbox: :local`
  # (→ HostShell). Tenant per the `resolve_scope` precedence; the REAL
  # `workspace_uuid` (never the runtime `workspace_id` string — the front-door
  # `forge_exec_spec/3` precedent: `Persistence.scope_from_spec/1` casts it to
  # the Session's `:uuid` attribute, so a synthetic id would fail the cast).
  defp session_spec(context, runner, runner_config) do
    %{
      runner: runner,
      runner_config: runner_config,
      sandbox: :local,
      claim: false,
      tenant_id: context[:tenant] || context[:tenant_id],
      workspace_uuid: context[:workspace_uuid]
    }
  end

  # ---------------------------------------------------------------------------
  # Fixture resolution (`:executor_fake_outputs`) — the composer StubWorker's
  # loud deterministic lookup (`composer_stubs.ex` `lookup_output!/3`), extended
  # with the step-name key the bridge (unlike the StubWorker) actually receives.
  # ---------------------------------------------------------------------------

  defp resolve_fixture(outputs, template_name, task, step_name) do
    stage_key = {:stage, template_name, step_name}
    fragments = for {{:fragment, ^template_name, fragment}, _out} <- outputs, do: fragment

    cond do
      Map.has_key?(outputs, stage_key) ->
        {:ok, Map.fetch!(outputs, stage_key)}

      fragments != [] ->
        resolve_fragment(outputs, fragments, template_name, task)

      tuple_keyed?(outputs, template_name) ->
        {:error,
         "Step #{template_name} failed: no fake output armed for stage " <>
           "'#{step_name}' — tuple keys for '#{template_name}' disable the plain " <>
           "template fallback (:executor_fake_outputs)"}

      Map.has_key?(outputs, template_name) ->
        {:ok, Map.fetch!(outputs, template_name)}

      true ->
        {:error,
         "Step #{template_name} failed: no fake output armed for " <>
           "'#{template_name}' (:executor_fake_outputs)"}
    end
  end

  # When fragment keys exist, exactly ONE must contain-match the task — zero or
  # several fail closed (the lib-code analogue of the StubWorker's raise),
  # never an arbitrary pick or a silent plain-key fallback.
  defp resolve_fragment(outputs, fragments, template_name, task) do
    case Enum.filter(fragments, &String.contains?(task, &1)) do
      [fragment] ->
        {:ok, Map.fetch!(outputs, {:fragment, template_name, fragment})}

      matched ->
        {:error,
         "Step #{template_name} failed: expected exactly one " <>
           "{:fragment, #{inspect(template_name)}, _} fake output to match the task, " <>
           "got #{inspect(matched)} from fragments #{inspect(fragments)}"}
    end
  end

  defp tuple_keyed?(outputs, template_name) do
    Enum.any?(Map.keys(outputs), fn
      {:stage, ^template_name, _} -> true
      {:fragment, ^template_name, _} -> true
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # Session lifecycle + result mapping.
  # ---------------------------------------------------------------------------

  defp run_session(spec, template, template_name, step_name) do
    session_id = Ecto.UUID.generate()

    case Forge.start_session_ready(session_id, spec, expected_backend: HostShell) do
      {:ok, ^session_id} ->
        # The result is captured BEFORE teardown (the consolidator run_server
        # precedent); the bridge owns the stop.
        try do
          session_id
          |> Forge.run_iteration(timeout: @forge_step_timeout_ms)
          |> map_result(template, template_name, step_name)
        after
          Forge.stop_session(session_id, :normal)
        end

      {:error, reason} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}
    end
  end

  defp map_result({:ok, %{status: :done, output: output}}, template, template_name, step_name) do
    build_step_result(output, template, template_name, step_name)
  end

  defp map_result({:ok, %{status: :error, error: error}}, _template, template_name, _step_name) do
    {:error, "Step #{template_name} failed: #{inspect(error)}"}
  end

  defp map_result({:ok, %{status: :needs_input, question: q}}, _tpl, template_name, _step_name) do
    {:error, "Step #{template_name} failed: needs input (gate mapping lands in PR-4): #{q}"}
  end

  defp map_result({:ok, %{status: status}}, _template, template_name, _step_name)
       when status in [:blocked, :continue] do
    {:error, "Step #{template_name} failed: runner returned #{inspect(status)} (single-shot)"}
  end

  defp map_result({:error, reason}, _template, template_name, _step_name) do
    {:error, "Step #{template_name} failed: #{inspect(reason)}"}
  end

  defp map_result(other, _template, template_name, _step_name) do
    {:error, "Step #{template_name} failed: unexpected iteration reply: #{inspect(other)}"}
  end

  defp build_step_result(output, template, template_name, step_name) do
    typed = parse_typed_output(Map.get(template, :module), output)
    raw_text = Output.extract_result(output)

    text =
      case typed do
        %{} = m -> Output.extract_result(m)
        _ -> raw_text
      end

    {:ok,
     %StepResult{
       name: step_name,
       template: template_name,
       result: text,
       typed_output: typed,
       artifacts: AgentRunner.step_artifacts(raw_text, typed)
     }}
  end

  # Soft validation, live-faithful: `{:ok, map}` ⇒ typed, anything else ⇒ nil
  # (the same consequence a live worker's failed output validation gets).
  defp parse_typed_output(module, output) do
    case worker_output_schema(module) do
      nil -> nil
      schema -> validated(Jido.AI.Output.parse(schema, output))
    end
  end

  defp validated({:ok, typed}), do: typed
  defp validated(_other), do: nil

  # The template module's declared output schema, or nil when it declares none
  # — or does not export `strategy_opts/0` at all (test overrides can pair a
  # non-worker module with an explicit `max_iterations`; the forge arm must
  # stay as tolerant as hydration is).
  defp worker_output_schema(nil), do: nil

  defp worker_output_schema(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :strategy_opts, 0) do
      Keyword.get(module.strategy_opts(), :output)
    else
      nil
    end
  end
end
