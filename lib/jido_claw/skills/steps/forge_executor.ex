defmodule JidoClaw.Skills.Steps.ForgeExecutor do
  @moduledoc """
  The `{:forge, _}` executor arm of `JidoClaw.Skills.Steps.AgentRunner`
  (item 7 / camus C1-1 — the executor seam): runs one skill/composer step
  through a REAL minimal Forge session instead of an in-process `Jido.AI`
  worker.

  Plain ephemeral sessions, every kind: `claim: false`. The `:shell`/`:fake`
  arms and LOCAL vendor plans run `sandbox: :local` (HostShell — a per-run tmp
  working dir; deliberately ignoring a prod `FORGE_SANDBOX=docker` so executor
  steps never spin a microVM per stage). The template `executor_config` knobs
  `access:`/`session_sandbox:` are LIVE (the docker write build):
  `session_sandbox: :docker` dispatches a vendor session into an sbx microVM
  via the `:executor_docker_backend` seam, and `access: :write` (which forces
  `:docker` at hydration) mounts the run's repo same-path **rw** so the CLI's
  edits land directly in the real working tree — the runner gets its vendors'
  `:full` arms; the microVM + workspace mount mode is the boundary (camus
  sketch (d)). `:read_only`+docker keeps the read-only CLI flags AND a `:ro`
  mount (defense in depth). Lifecycle per step: mint a session
  id → `Forge.start_session_ready/3` asserting the plan's backend (HostShell
  for local; the seam-resolved docker MODULE — `expected_backend/1` — for
  docker; ReadyStart tears down its own partial session on failure) → one
  `Forge.run_iteration/2` → map to a `%StepResult{}` → always
  `Forge.stop_session/2` (`try/after` — the result is captured before
  teardown, and a genuine raise propagates to `AgentRunner`'s `run_recorded`
  boundary; the facade returns tagged tuples).
  Single-shot: `:blocked` and `:continue` map to plain step errors;
  `:needs_input` ALSO maps to a step error (the run rides its existing
  failure lanes — no composer park) but first raises a durable
  `:needs_input` `AgentCase` via `JidoClaw.Orchestration.NeedsInput`
  (best-effort), whose operator-approved answer the stage's NEXT attempt
  claims single-use — the vendor arm claims LAST in its spec build (after
  every refusal, so a refused dispatch never burns the answer) and injects
  it into the prompt; the session arms raise but never claim.

  ## PR-1 kinds

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

  Both PR-1 arms soft-validate the forge output against the template module's
  declared output schema (`strategy_opts()[:output]` via `Jido.AI.Output.parse/2`
  — binaries JSON-decode, so shell stdout gets the same validation): `{:ok, _}`
  ⇒ `typed_output`, anything else ⇒ `nil`, live-faithfully mirroring a live
  worker whose output validation failed (a lens stage with `typed: nil` rides
  the Verdict infra lane; a producer falls back to its result text) — never a
  fabricated verdict.

  ## PR-2 vendor kinds (`{:forge, :codex | :claude_code}`)

  A vendor step runs a competing CLI against a per-step scoped MCP deposit
  endpoint — the engine owns both ends of the result channel (camus C1-1's
  thesis vs. the hallucination-prone stdout relay). Per step: a linked
  `Deposit` box + `ScopedEndpoint` (Bandit on loopback, fronting
  `DepositServer` through `DepositPlug`) + MCP client config — a host-tmp
  file for local plans, an in-VM write (`mcp_config_json`, checked at runner
  init) for docker plans — acquired through a total unwinding reducer (a
  partial acquisition tears down exactly what it acquired — the box never
  leaks), then a real session whose runner posture derives from the plan's
  single resolved `access`: `:read_only` ⇒ codex `-s read-only` / claude
  restricted `--tools` (+ isolated `CLAUDE_CONFIG_DIR` via
  `config_sync: :auth_only`, both postures); `:write` (docker-only by
  hydration) ⇒ the runners' `:full` arms, with the microVM + rw same-path
  repo mount as the boundary. A docker session reaches the deposit endpoint
  through `host.docker.internal` under a per-sandbox `allow_network` policy
  rule (both `host.docker.internal:<port>` and `localhost:<port>` forms);
  claude additionally pins `--strict-mcp-config` in write mode so a mounted
  repo's `.mcp.json` cannot shadow/expand the deposit surface.

  **Single-channel deposit** (camus OQ-1(c)): `typed_output` comes ONLY from a
  schema-valid `submit_structured_output` deposit (validated in the box,
  last-valid-wins; an invalid deposit is an in-session `isError` retry). No
  deposit ⇒ `typed_output: nil` — the same live-faithful consequences as the
  PR-1 arms. CLI stdout is kept for `ARTIFACTS:` extraction and as fallback
  result text, never parsed into typed.

  `executor_config.workspace` (vendor kinds only, hydration-defaulted `:repo`):
  `:repo` points the CLI at the run's real `project_dir` (codex `-C`, claude
  `--add-dir` + the path named in the prompt; on docker additionally a
  same-path workspace mount + `--workdir`, rw only under `access: :write`) —
  required present-non-blank or the step fails loudly BEFORE any session;
  `:scratch`/`:none` expose no repo — the CLI runs from its per-session
  throwaway dir (no mount, no workdir on docker), and the two differ only in
  the prompt note.

  Vendor creds reuse the runners' host config sync (`~/.claude` — the shared
  dotted-file → legacy-file → macOS-Keychain source — / `~/.codex` +
  `{:error, :no_credentials}`) — the operator's own CLI auth, the same trust
  class as running the CLI by hand; a missing-creds session start surfaces as
  a clean step error (Lane B infra for lens cohorts). Prompt egress is
  redacted in the runners (`PromptRedaction.redact` on the full argv prompt +
  `context.md`, ANSI-stripped first since PR-3 — the redaction root's
  pre-pass), so the P1a subagent-contract sections pass the redaction root
  before leaving for a second vendor.
  """

  alias JidoClaw.Forge
  alias JidoClaw.Forge.Runner.HostShell
  alias JidoClaw.Forge.Runners.StaticFake
  alias JidoClaw.MCP.ScopedEndpoint
  alias JidoClaw.Orchestration.NeedsInput
  alias JidoClaw.Reasoning.Output
  alias JidoClaw.Skills.Steps.AgentRunner
  alias JidoClaw.Skills.Steps.ForgeExecutor.Deposit
  alias JidoClaw.Skills.Steps.ForgeExecutor.DepositPlug
  alias JidoClaw.Workflows.StepResult

  # Mirrors AgentRunner's @step_timeout_ms.
  @forge_step_timeout_ms 180_000

  # Vendor-step timeout default/clamp: 240s default — deliberately under the
  # composer's @default_wave_timeout_ms 300_000, so a default vendor step never
  # races the wave kill (raising one means raising the other; see AGENTS.md).
  @vendor_timeout_default_ms 240_000
  @vendor_timeout_min_ms 30_000
  @vendor_timeout_max_ms 600_000
  @vendor_max_turns_default 40

  @deposit_server_name "jido_deposit"
  @deposit_tool "submit_structured_output"

  @doc """
  Run one `{:forge, _}` step through a fresh ephemeral Forge session.
  `template` is the hydrated map from `Templates.get/1` (its `:executor`
  selects the kind); `context` is the Reactor context (tenant / workspace
  scope for the session spec, `project_dir` for `workspace: :repo`). `opts`
  carries `system_prompt:` — the gated subagent contract `AgentRunner`
  computes for vendor kinds (P1a). Returns the `AgentRunner` step contract:
  `{:ok, %StepResult{}}` or `{:error, binary()}`.
  """
  @spec run(String.t(), map(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, StepResult.t()} | {:error, binary()}
  def run(template_name, template, task, step_name, context, opts \\ []) do
    {:forge, kind} = template.executor
    ni = needs_input_scope(context, template_name, step_name, kind)

    result =
      case build_spec(kind, template, template_name, task, step_name, context, opts, ni) do
        {:ok, {:session, spec}} -> run_session(spec, template, template_name, step_name, ni)
        {:ok, {:vendor, plan}} -> run_vendor(plan, template_name, step_name, ni)
        {:error, _} = err -> err
      end

    JidoClaw.Telemetry.emit_executor(kind, outcome(result))
    result
  end

  # The NeedsInput producer scope, built ONCE per step (PR-4). Keys per the
  # ReactorRunner context seeding: tenant (`:tenant` precedence), BOTH
  # `session_uuid` (the Session-FK resolution input) and `session_id` (the
  # composite fingerprint identity's fallback half — the ToolApprovals
  # precedent), the run id EXTRACTED from the `%WorkflowRun{}` the Reactor
  # context carries (provenance FK, never the struct), and the executor
  # kind's vendor-ness (feeds the `injectable` surface promise: only a
  # vendor arm can inject an answer).
  defp needs_input_scope(context, template_name, step_name, kind) do
    %{
      tenant_id: context[:tenant] || context[:tenant_id],
      actor: context[:actor],
      session_uuid: context[:session_uuid],
      session_id: context[:session_id],
      workflow_run_id: run_id(context[:workflow_run]),
      template_name: template_name,
      step_name: step_name,
      vendor?: kind in [:codex, :claude_code]
    }
  end

  defp run_id(%{id: id}) when is_binary(id), do: id
  defp run_id(_no_run), do: nil

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, _}), do: :error

  # ---------------------------------------------------------------------------
  # Spec build — fail closed BEFORE any session/box/endpoint starts.
  # ---------------------------------------------------------------------------

  defp build_spec(:shell, template, _template_name, _task, _step_name, context, _opts, _ni) do
    {:ok, {:session, session_spec(context, :shell, %{command: template.executor_config.command})}}
  end

  defp build_spec(:fake, _template, template_name, task, step_name, context, _opts, _ni) do
    outputs = Application.get_env(:jido_claw, :executor_fake_outputs, %{})

    with {:ok, fixture} <- resolve_fixture(outputs, template_name, task, step_name) do
      {:ok, {:session, session_spec(context, StaticFake, %{fake_output: fixture})}}
    end
  end

  defp build_spec(kind, template, template_name, task, _step_name, context, opts, ni)
       when kind in [:codex, :claude_code] do
    config = Map.get(template, :executor_config, %{})
    workspace = Map.get(config, :workspace, :repo)
    # Resolved ONCE, threaded through the plan: the workspace mount mode AND
    # the runner posture both derive from this single `access` (divergence =
    # opaque in-VM write failures). Hydration guarantees write ⇒ docker; the
    # defaults here mirror hydration's for direct-call (test) templates.
    access = Map.get(config, :access, :read_only)
    session_sandbox = Map.get(config, :session_sandbox, :local)

    with {:ok, project_dir} <- resolve_workspace_dir(workspace, context, template_name) do
      # Claim LAST — after every refusal above — so a refused dispatch never
      # burns the single-use operator answer (the PR-4 answer-loop). The
      # session arms (`:shell`/`:fake`) never claim, structurally: the claim
      # call exists only in this vendor clause. A docker infra failure AFTER
      # this point (backend create, policy rule, runner init) can still burn
      # the answer — the same pre-existing class as a local :no_credentials
      # at init; accepted, not new machinery.
      operator_answer = claim_operator_answer(ni)
      output = worker_output_schema(Map.get(template, :module))

      {:ok,
       {:vendor,
        %{
          kind: kind,
          output: output,
          workspace: workspace,
          access: access,
          session_sandbox: session_sandbox,
          config: config,
          context: context,
          project_dir: project_dir,
          prompt:
            vendor_prompt(
              Keyword.get(opts, :system_prompt),
              task,
              workspace,
              project_dir,
              output,
              operator_answer,
              access == :write and session_sandbox == :docker
            )
        }}}
    end
  end

  defp claim_operator_answer(ni) do
    case NeedsInput.claim_answer(ni) do
      {:ok, answer} -> answer
      :none -> nil
    end
  end

  # `:repo` requires a usable project_dir BEFORE any resource is acquired.
  # ToolContext present-nil coercion: a present-nil key must not read as set.
  defp resolve_workspace_dir(:repo, context, template_name) do
    case context[:project_dir] do
      pd when is_binary(pd) and pd != "" ->
        {:ok, pd}

      _ ->
        {:error,
         "Step #{template_name} failed: executor workspace: :repo requires a " <>
           "project_dir in the run context"}
    end
  end

  defp resolve_workspace_dir(_scratch_or_none, _context, _template_name), do: {:ok, nil}

  # Plain ephemeral session spec, every kind: `claim: false`, `sandbox: :local`
  # (→ HostShell) — the `:shell`/`:fake` arms and LOCAL vendor plans, byte-
  # identical to PR-2 (no `sandbox_spec` key, ever — a present-nil would
  # defeat downstream `Map.get` defaults). Tenant per the `resolve_scope`
  # precedence; the REAL `workspace_uuid` (never the runtime `workspace_id`
  # string — the front-door `forge_exec_spec/3` precedent:
  # `Persistence.scope_from_spec/1` casts it to the Session's `:uuid`
  # attribute, so a synthetic id would fail the cast).
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

  # The docker vendor session spec (the write build): same base, backend from
  # the `:executor_docker_backend` seam, `sandbox_spec` knobs conditionally-
  # put — a workspace-less plan carries neither `workdir` nor `extra_mounts`;
  # `allow_network` is always present (the deposit endpoint must be reachable
  # from the microVM via host.docker.internal AND localhost — both forms
  # required by the sbx proxy).
  defp docker_session_spec(plan, runner, runner_config, res) do
    plan.context
    |> session_spec(runner, runner_config)
    |> Map.put(:sandbox, executor_docker_backend())
    |> Map.put(:sandbox_spec, docker_sandbox_spec(plan, res))
  end

  defp docker_sandbox_spec(plan, res) do
    port = res.endpoint.port
    # Vendor executors consume repository-controlled prompts and code. They must
    # never inherit operator-global mounts or OneCLI proxy credentials from the
    # Docker backend; only the explicit repository/deposit capabilities below
    # belong in this sandbox.
    base = %{
      allow_network: ["host.docker.internal:#{port}", "localhost:#{port}"],
      isolate_global_config: true
    }

    if plan.workspace == :repo do
      # The pinned OQ-1(a) materialization: a direct same-path repo mount,
      # rw ONLY for the write posture — read_only keeps a :ro mount besides
      # the runner's read-only CLI flags (defense in depth).
      mode = if plan.access == :write, do: "rw", else: "ro"

      base
      |> Map.put(:workdir, plan.project_dir)
      |> Map.put(:extra_mounts, [{plan.project_dir, plan.project_dir, mode}])
    else
      base
    end
  end

  defp executor_docker_backend do
    Application.get_env(:jido_claw, :executor_docker_backend, :docker_sandbox)
  end

  @doc """
  The `expected_backend:` module for a vendor session's `session_sandbox`.
  Public so precommit pins the `:docker_sandbox → Docker` MODULE mapping:
  `Harness.resolve_client/1` stores the resolved MODULE in `sandbox_module`
  and `ReadyStart.usable_status/2` compares it to `expected_backend`, so
  passing the wire ATOM through would tear down every real docker session as
  `{:wrong_backend, Docker}` — a hole stub-armed tests alone cannot see. An
  armed stub Behaviour module (the `:executor_docker_backend` seam) passes
  through as itself.
  """
  @spec expected_backend(:local | :docker) :: module()
  def expected_backend(:docker) do
    case executor_docker_backend() do
      :docker_sandbox -> JidoClaw.Forge.Sandbox.Docker
      module when is_atom(module) -> module
    end
  end

  def expected_backend(_local), do: HostShell

  # ---------------------------------------------------------------------------
  # Vendor prompt assembly (P1a order): subagent system prompt (the same
  # contract in-process workers get — when the doctrine gate supplies one) →
  # stage task → workspace note → operator answer (PR-4, when claimed) →
  # deposit instruction LAST (nearest to action).
  # ---------------------------------------------------------------------------

  defp vendor_prompt(
         system_prompt,
         task,
         workspace,
         project_dir,
         output,
         operator_answer,
         writable?
       ) do
    [
      valid_system_prompt(system_prompt),
      task,
      workspace_note(workspace, project_dir, writable?),
      operator_answer_block(operator_answer),
      deposit_instruction(output)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp valid_system_prompt(prompt) when is_binary(prompt) and prompt != "", do: prompt
  defp valid_system_prompt(_), do: nil

  # PR-4 answer injection: nil ⇒ the prompt is byte-identical to the
  # answer-less build. Argv/context redaction rides the runners'
  # PromptRedaction root, like every other prompt section.
  defp operator_answer_block(nil), do: nil

  defp operator_answer_block(answer) do
    "An operator answered an earlier request you made for input. Use this " <>
      "answer to proceed; do not ask again:\n\n" <> answer
  end

  # Writability rides the note (the write build): a write+docker session's
  # edits land directly in the real working tree — the CLI must know it, or
  # it hedges into patch-emitting behavior; every other combination keeps the
  # read-only wording.
  defp workspace_note(:repo, project_dir, true = _writable?) do
    "You are working in the repository at #{project_dir} (writable this session — " <>
      "your changes land directly in the working tree)."
  end

  defp workspace_note(:repo, project_dir, _read_only) do
    "You are working in the repository at #{project_dir} (read-only this session)."
  end

  defp workspace_note(:scratch, _project_dir, _writable?) do
    "You have no repository access; your working directory is a throwaway session scratch dir."
  end

  defp workspace_note(:none, _project_dir, _writable?) do
    "You have no repository access."
  end

  # The expected shape rides the prompt (`Jido.AI.Output.json_schema/1` renders
  # both a Zoi contract and an embedded :json_schema map) because the MCP tool
  # itself advertises only {"type": "object"} — the single-static-server model.
  defp deposit_instruction(nil) do
    """
    When you are done, call the `#{@deposit_tool}` MCP tool (server \
    `#{@deposit_server_name}`) exactly once with your final result object as \
    the `output` argument. The tool call is the ONLY accepted result channel — \
    plain text output is not read as your result. If the tool returns a \
    validation error, fix the object and call the tool again.\
    """
  end

  defp deposit_instruction(%Jido.AI.Output{} = output) do
    schema_json =
      output
      |> Jido.AI.Output.json_schema()
      |> Jason.encode!(pretty: true)

    """
    When you are done, call the `#{@deposit_tool}` MCP tool (server \
    `#{@deposit_server_name}`) exactly once, passing your final result as the \
    `output` argument — a single JSON object matching this JSON Schema:

    #{schema_json}

    The tool call is the ONLY accepted result channel — plain text output is \
    not read as your result. If the tool returns a validation error, fix the \
    object and call the tool again with the corrected object.\
    """
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
  # PR-1 session lifecycle + result mapping.
  # ---------------------------------------------------------------------------

  defp run_session(spec, template, template_name, step_name, ni) do
    session_id = Ecto.UUID.generate()

    # HostShell asserted: the `:shell`/`:fake` session arms are
    # `sandbox: :local` by construction (`session_spec/3`); only vendor plans
    # can carry `session_sandbox: :docker` (see `run_vendor/4`).
    case Forge.start_session_ready(session_id, spec, expected_backend: HostShell) do
      {:ok, ^session_id} ->
        # The result is captured BEFORE teardown (the consolidator run_server
        # precedent); the bridge owns the stop.
        try do
          session_id
          |> Forge.run_iteration(timeout: @forge_step_timeout_ms)
          |> map_result(template, template_name, step_name, ni)
        after
          Forge.stop_session(session_id, :normal)
        end

      {:error, reason} ->
        {:error, "Step #{template_name} failed: #{inspect(reason)}"}
    end
  end

  defp map_result(
         {:ok, %{status: :done, output: output}},
         template,
         template_name,
         step_name,
         _ni
       ) do
    build_step_result(output, template, template_name, step_name)
  end

  defp map_result(other, _template, template_name, _step_name, ni) do
    map_error_result(other, template_name, ni)
  end

  # The shared non-done iteration mapping, both executor arms.
  defp map_error_result({:ok, %{status: :error, error: error}}, template_name, _ni) do
    {:error, "Step #{template_name} failed: #{inspect(error)}"}
  end

  # PR-4: raise the durable needs-input case (best-effort), then STILL return
  # the step error — the run rides its existing failure lanes; the case is
  # the answer channel for the stage's next attempt. The step error is its
  # own persisted sink (subagent terminal transcript, route-failure
  # formatting), so it carries the same REDACTED question as
  # `details["question"]`, never the raw text.
  defp map_error_result({:ok, %{status: :needs_input, question: q}}, template_name, ni) do
    question = NeedsInput.redact_question(q)

    case NeedsInput.raise_case(ni, q) do
      {:ok, agent_case} ->
        {:error,
         "Step #{template_name} failed: needs operator input " <>
           "(gate #{agent_case.id}): #{question}"}

      :error ->
        {:error, "Step #{template_name} failed: needs operator input: #{question}"}
    end
  end

  defp map_error_result({:ok, %{status: status}}, template_name, _ni)
       when status in [:blocked, :continue] do
    {:error, "Step #{template_name} failed: runner returned #{inspect(status)} (single-shot)"}
  end

  defp map_error_result({:error, reason}, template_name, _ni) do
    {:error, "Step #{template_name} failed: #{inspect(reason)}"}
  end

  defp map_error_result(other, template_name, _ni) do
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

  # ---------------------------------------------------------------------------
  # PR-2 vendor lifecycle: acquire (unwinding) → session → iterate → take
  # deposit → map, with teardown on EVERY path.
  # ---------------------------------------------------------------------------

  defp run_vendor(plan, template_name, step_name, ni) do
    ref = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    forge_home = vendor_forge_home(plan, session_id)

    case acquire_vendor_resources(ref, plan, forge_home) do
      {:ok, res} ->
        try do
          runner_config = build_runner_config(plan, res)
          runner = vendor_runner(plan.kind)

          spec =
            case plan.session_sandbox do
              :docker -> docker_session_spec(plan, runner, runner_config, res)
              _local -> session_spec(plan.context, runner, runner_config)
            end

          # Backend asserted per the plan's session_sandbox: HostShell for
          # local, the seam-resolved docker MODULE for docker (see
          # `expected_backend/1`).
          case Forge.start_session_ready(session_id, spec,
                 expected_backend: expected_backend(plan.session_sandbox)
               ) do
            {:ok, ^session_id} ->
              try do
                iter = Forge.run_iteration(session_id, timeout: runner_config.timeout_ms)
                deposit = Deposit.take(ref)
                map_vendor_result(iter, deposit, template_name, step_name, ni)
              after
                Forge.stop_session(session_id, :normal)
              end

            {:error, reason} ->
              {:error, "Step #{template_name} failed: #{inspect(reason)}"}
          end
        after
          teardown(res)
        end

      {:error, msg} ->
        {:error, "Step #{template_name} failed: #{msg}"}
    end
  end

  # Docker plans pin the forge home under an in-VM user-writable base — the
  # configured `/var/local/forge` may not be creatable in-VM (the runner
  # `mkdir -p`s it as the sandbox user); local plans keep the configured base
  # byte-identical.
  defp vendor_forge_home(%{session_sandbox: :docker}, session_id),
    do: Path.join("/tmp/jidoclaw_forge_exec", session_id)

  defp vendor_forge_home(_local_plan, session_id) do
    base = Application.get_env(:jido_claw, :forge_home, "/var/local/forge")
    Path.join(base, session_id)
  end

  # Explicit accumulator/reducer, not `try`-scope rebindings (a rebound var
  # inside `try` is not reliably visible to `rescue`): each step is a non-bang
  # tuple step by construction (`safe_step` converts any raise/exit), the acc
  # IS the teardown manifest, and the first failure tears down exactly what
  # was acquired — the box never leaks past a partial acquisition (P2b).
  defp acquire_vendor_resources(ref, plan, forge_home) do
    steps =
      [
        &acquire_box(&1, ref, plan.output),
        &acquire_endpoint(&1, ref),
        &acquire_forge_home(&1, forge_home)
      ] ++ client_config_steps(plan, ref)

    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, acc} ->
      case safe_step(fn -> step.(acc) end) do
        {:ok, next} ->
          {:cont, {:ok, next}}

        {:error, msg} ->
          teardown(acc)
          {:halt, {:error, msg}}
      end
    end)
  end

  # The host-tmp client config is LOCAL-only (review P3): a docker session
  # reads its config from the in-VM write (`mcp_config_json` at runner init)
  # — it must not carry a host /tmp write failure surface for a file it
  # never reads.
  defp client_config_steps(%{session_sandbox: :docker}, _ref), do: []
  defp client_config_steps(_local_plan, ref), do: [&acquire_client_config(&1, ref)]

  defp safe_step(fun) do
    fun.()
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:error, "resource acquisition raised: #{Exception.message(e)}"}
  catch
    kind, payload -> {:error, "resource acquisition #{kind}: #{inspect(payload)}"}
  end

  defp acquire_box(acc, ref, output) do
    case Deposit.start_link(ref: ref, output: output) do
      {:ok, _pid} -> {:ok, Map.put(acc, :box_ref, ref)}
      {:error, reason} -> {:error, "deposit box start failed: #{inspect(reason)}"}
    end
  end

  defp acquire_endpoint(acc, ref) do
    case ScopedEndpoint.start_link(plug: DepositPlug, scope_id: ref, path_prefix: "/deposit") do
      {:ok, endpoint} -> {:ok, Map.put(acc, :endpoint, endpoint)}
      {:error, reason} -> {:error, "deposit endpoint start failed: #{inspect(reason)}"}
    end
  end

  defp acquire_forge_home(acc, forge_home) do
    case File.mkdir_p(forge_home) do
      :ok -> {:ok, Map.put(acc, :forge_home, forge_home)}
      {:error, reason} -> {:error, "forge home mkdir failed: #{inspect(reason)}"}
    end
  end

  defp acquire_client_config(acc, ref) do
    case ScopedEndpoint.write_client_config(
           @deposit_server_name,
           acc.endpoint.url,
           "executor-deposit-#{ref}.json"
         ) do
      {:ok, path} -> {:ok, Map.put(acc, :cfg_path, path)}
      {:error, reason} -> {:error, "mcp client config write failed: #{inspect(reason)}"}
    end
  end

  # Idempotent/tolerant over a PARTIAL acc — only keys that were acquired are
  # present, and every stopper tolerates already-gone resources.
  defp teardown(res) do
    if endpoint = res[:endpoint], do: ScopedEndpoint.stop(endpoint)
    if path = res[:cfg_path], do: File.rm(path)
    if home = res[:forge_home], do: File.rm_rf(home)
    if ref = res[:box_ref], do: Deposit.stop(ref)
    :ok
  end

  # The runner posture derives from the plan's single resolved `access`
  # (the write build): `:write` ⇒ the runners' existing `:full` arms — the
  # microVM + workspace mount mode is the boundary (camus sketch (d)) —
  # `:read_only` keeps the restricted CLI flag sets. Invariant-preserving for
  # local plans: hydration refuses write+local, so a local plan is always
  # `:read_only` here. `config_sync` is not a knob at all.
  defp build_runner_config(plan, res) do
    config = plan.config
    repo? = plan.workspace == :repo

    %{
      prompt: plan.prompt,
      forge_home: res.forge_home,
      codex_home: Path.join(res.forge_home, ".codex"),
      mcp_server_name: @deposit_server_name,
      allowed_mcp_tools: ["mcp__#{@deposit_server_name}__#{@deposit_tool}"],
      access: if(plan.access == :write, do: :full, else: :read_only),
      config_sync: :auth_only,
      cwd: if(repo?, do: plan.project_dir, else: res.forge_home),
      add_dirs: if(repo?, do: [plan.project_dir], else: []),
      max_turns: Map.get(config, :max_turns, @vendor_max_turns_default),
      timeout_ms: clamp_vendor_timeout(Map.get(config, :timeout_ms, @vendor_timeout_default_ms))
    }
    |> Map.merge(mcp_client_keys(plan, res))
    |> maybe_put(:model, Map.get(config, :model))
    |> maybe_put(:thinking_effort, Map.get(config, :thinking_effort))
  end

  # Local: the host-tmp cfg written at acquisition + the loopback URL —
  # byte-identical to PR-2. Docker: the URL host is rewritten to
  # host.docker.internal (the in-VM name for host loopback; codex consumes it
  # via the `-c` inline override — URL translation is all codex needs), the
  # config path points INTO the VM (claude writes `mcp_config_json` there at
  # runner init — the host-tmp file doesn't exist in-VM), and `strict_mcp`
  # pins claude's MCP surface to that file alone (a mounted repo's
  # `.mcp.json` must not shadow/expand the deposit surface).
  defp mcp_client_keys(%{session_sandbox: :docker}, res) do
    url = String.replace(res.endpoint.url, "127.0.0.1", "host.docker.internal")

    %{
      mcp_config_path: Path.join(res.forge_home, "mcp-config.json"),
      mcp_server_url: url,
      mcp_config_json: ScopedEndpoint.client_config_json(@deposit_server_name, url),
      strict_mcp: true
    }
  end

  defp mcp_client_keys(_local_plan, res) do
    %{mcp_config_path: res.cfg_path, mcp_server_url: res.endpoint.url}
  end

  defp clamp_vendor_timeout(ms),
    do: min(max(ms, @vendor_timeout_min_ms), @vendor_timeout_max_ms)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Prod resolves the CLI runner atoms through the harness `resolve_runner`
  # (per-runner cap 10); tests arm a module double (the `:executor_fake_outputs`
  # pattern — the double reads its deposit script from its OWN app-env key, so
  # no test-only keys ride prod runner_config).
  defp vendor_runner(kind) do
    Application.get_env(:jido_claw, :executor_vendor_runners, %{})[kind] || kind
  end

  # P3a — the PR-1/in-process typed projection: transcripts show the typed
  # deposit's summary, not raw stream-json; the raw CLI text still feeds
  # `ARTIFACTS:` block extraction.
  defp map_vendor_result(
         {:ok, %{status: :done, output: cli_out}},
         deposit,
         template_name,
         step_name,
         _ni
       ) do
    raw_text = Output.extract_result(cli_out)

    text =
      case deposit do
        %{} = m -> Output.extract_result(m)
        _ -> raw_text
      end

    {:ok,
     %StepResult{
       name: step_name,
       template: template_name,
       result: text,
       typed_output: deposit,
       artifacts: AgentRunner.step_artifacts(raw_text, deposit)
     }}
  end

  defp map_vendor_result(other, _deposit, template_name, _step_name, ni) do
    map_error_result(other, template_name, ni)
  end
end
