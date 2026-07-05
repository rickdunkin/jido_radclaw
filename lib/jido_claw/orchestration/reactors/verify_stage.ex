defmodule JidoClaw.Orchestration.Reactors.VerifyStage.RunVerify do
  @moduledoc """
  The single step of `JidoClaw.Orchestration.Reactors.VerifyStage`: resolve the
  verify command, run the checks through the engine runner, classify the
  envelope, persist the evidence, and return the WaveCollect-shaped emission
  map the composer folds like any worker wave.

  ## Verdict mapping (law 2 — the engine reads the exit codes itself)

    * **green** (`pass` — captures succeeded by construction) →
      `clean:<lens>` + the encrypted `verify-report` artifact + a bounded
      `certification` (`head`/`tree_digest`/`mode`, strings) the composer
      welds into `:verify_certified`;
    * **red** → `findings:<lens>` + `verify-report` + the `findings` /
      `action_needed` artifacts that ride the existing Hook R fixer re-fire;
    * **tampered** → `outcome: {:tampered, reason}` with NO signals; the
      report ref rides the emission's artifacts map for the composer to weld
      into `:stage_tampered` (never `artifacts_produced` — a tamper report
      must not look routable);
    * **inconclusive** → `outcome: {:inconclusive, reason}` with NO report
      artifact — the bounded reason + remedy ride the emission/Trace only
      (the `:stage_infra` posture), and the composer's infra lane retries.

  **Every config-resolution failure** (invalid shape, shell-syntax scalar,
  unknown-check override, no verifier, missing project_dir) is caught HERE and
  returned as the loud inconclusive envelope — a config mistake rides the
  infra lane with a remedy, never the wave-execution-error lane.
  """

  use Reactor.Step

  alias JidoClaw.Orchestration.ComposerArtifact
  alias JidoClaw.Orchestration.Verify
  alias JidoClaw.Orchestration.Verify.Envelope

  @impl Reactor.Step
  @spec run(Reactor.inputs(), Reactor.context(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(arguments, context, _options) do
    %{
      wave_index: wave_index,
      stage_name: stage_name,
      lens: lens,
      project_dir: project_dir,
      sealed_head: sealed_head,
      verify_override: verify_override
    } = arguments

    envelope = verify_envelope(project_dir, verify_override, sealed_head)
    result = classify(envelope)

    observe(result, envelope, stage_name, wave_index, context)

    with {:ok, artifacts} <- persist(result, envelope, stage_name, wave_index, context) do
      {:ok, wave_envelope(wave_index, emission(result, envelope, stage_name, lens, artifacts))}
    end
  end

  # Config resolution failures become the loud inconclusive refusal envelope
  # (remedy in log_tail), never a raw error — the infra lane handles retries.
  defp verify_envelope(project_dir, verify_override, sealed_head) do
    with {:ok, dir} <- require_project_dir(project_dir),
         {:ok, checks} <- Verify.Config.resolve(dir, verify_override) do
      runner = Verify.runner()

      Verify.build_result(checks,
        repo: dir,
        runner: &runner.run/2,
        sealed_head: sealed_head
      )
    else
      {:error, reason} ->
        Verify.refusal_result(
          refusal_reason(reason),
          Verify.Config.format_error(reason),
          sealed_head: sealed_head
        )
    end
  end

  defp require_project_dir(dir) when is_binary(dir) and dir != "", do: {:ok, dir}
  defp require_project_dir(_dir), do: {:error, :no_project_dir}

  defp refusal_reason(:no_verifier), do: "no_verifier_detected"
  defp refusal_reason(:no_project_dir), do: "no_project_dir"
  defp refusal_reason(:ambiguous_verify_config), do: "ambiguous_verify_config"
  defp refusal_reason({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp refusal_reason({tag, _a, _b}) when is_atom(tag), do: Atom.to_string(tag)
  defp refusal_reason(other), do: inspect(other)

  # Tampered outranks everything (integrity RED); then the camus lanes.
  defp classify(%Envelope{tampered: true}), do: :tampered
  defp classify(%Envelope{pass: true}), do: :green
  defp classify(%Envelope{inconclusive: true}), do: :inconclusive
  defp classify(%Envelope{}), do: :red

  # ---------------------------------------------------------------------------
  # Evidence persistence (green/red/tampered store the report; inconclusive
  # stores NOTHING — bounded reason + remedy ride the emission outcome/Trace)
  # ---------------------------------------------------------------------------

  defp persist(:inconclusive, _envelope, _stage_name, _wave_index, _context), do: {:ok, %{}}

  defp persist(result, envelope, stage_name, wave_index, context) do
    with {:ok, report_ref} <-
           store(context, "verify-report", stage_name, Envelope.to_map(envelope), wave_index) do
      case result do
        :red -> persist_red(envelope, stage_name, wave_index, context, report_ref)
        _green_or_tampered -> {:ok, %{"verify-report" => report_ref}}
      end
    end
  end

  # The red evidence the fixer loop reads: `findings` + `action_needed` ride
  # the existing Hook R feedback mechanics unchanged.
  defp persist_red(envelope, stage_name, wave_index, context, report_ref) do
    with {:ok, findings_ref} <-
           store(context, "findings", stage_name, findings(envelope), wave_index),
         {:ok, action_ref} <-
           store(context, "action_needed", stage_name, action_needed(envelope), wave_index) do
      {:ok,
       %{
         "verify-report" => report_ref,
         "findings" => findings_ref,
         "action_needed" => action_ref
       }}
    end
  end

  defp store(context, name, producer, value, wave_index) do
    ComposerArtifact.store_wave_artifact(
      name,
      producer,
      value,
      Map.fetch!(context, :workflow_run),
      wave_index,
      tenant: Map.fetch!(context, :tenant),
      actor: Map.fetch!(context, :actor)
    )
  end

  defp findings(%Envelope{failures: failures}) do
    for failure <- failures do
      %{
        "severity" => "error",
        "title" => finding_title(failure),
        "location" => failure.stage,
        "description" => failure.log_tail || ""
      }
    end
  end

  defp finding_title(%{kind: kind, exit: exit}) when is_integer(exit),
    do: "verify check failed (#{kind}, exit #{exit})"

  defp finding_title(%{kind: kind}), do: "verify check failed (#{kind})"

  defp action_needed(%Envelope{failures: failures}) do
    names =
      failures
      |> Enum.map(& &1.stage)
      |> Enum.uniq()
      |> Enum.join(", ")

    "make the verify checks pass (failing: #{names}); do not weaken the checks themselves"
  end

  # ---------------------------------------------------------------------------
  # The WaveCollect-shaped emission
  # ---------------------------------------------------------------------------

  defp emission(:green, envelope, stage_name, lens, artifacts) do
    %{
      "stage" => stage_name,
      "signals" => ["clean:#{lens}"],
      "artifacts" => artifacts,
      "certification" => certification(envelope)
    }
  end

  defp emission(:red, _envelope, stage_name, lens, artifacts) do
    %{
      "stage" => stage_name,
      "signals" => ["findings:#{lens}"],
      "artifacts" => artifacts
    }
  end

  defp emission(:tampered, envelope, stage_name, _lens, artifacts) do
    %{
      "stage" => stage_name,
      "signals" => [],
      "artifacts" => artifacts,
      "outcome" => %{"kind" => "tampered", "reason" => tampered_reason(envelope)}
    }
  end

  defp emission(:inconclusive, envelope, stage_name, _lens, _artifacts) do
    %{
      "stage" => stage_name,
      "signals" => [],
      "artifacts" => %{},
      "outcome" => %{"kind" => "inconclusive", "reason" => inconclusive_reason(envelope)}
    }
  end

  # A PASS implies the captures succeeded (build_result downgrades a
  # capture-less green to inconclusive), so head — and tree_digest in
  # working-tree mode — are present by construction; the composer's
  # uncertified-green reclassification is the defensive backstop.
  defp certification(%Envelope{head: head, tree_digest: digest, mode: mode}) do
    %{"head" => head, "tree_digest" => digest, "mode" => Atom.to_string(mode)}
  end

  # Bounded: integrity kinds + check names only — log tails live only inside
  # the encrypted report (redaction posture).
  defp tampered_reason(%Envelope{failures: failures, checks: checks}) do
    names = Enum.map_join(checks, ",", & &1.name)
    bound("tampered: kinds=#{failure_kinds(failures)} checks=#{names}")
  end

  defp failure_kinds(failures) do
    failures
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp inconclusive_reason(%Envelope{failures: failures}) do
    detail =
      failures
      |> Enum.map(fn failure -> failure.reason || failure.kind end)
      |> Enum.uniq()
      |> Enum.join(",")

    bound("verify_inconclusive: #{detail}")
  end

  defp bound(reason), do: String.slice(reason, 0, 240)

  defp wave_envelope(wave_index, emission) do
    %{"wave_index" => wave_index, "emissions" => [emission]}
  end

  # One trace + one counter per verify run (tampered + refusals are loud by
  # carrying their bounded reason; log tails never leave the encrypted report).
  defp observe(result, envelope, stage_name, wave_index, context) do
    child = Map.fetch!(context, :workflow_run)

    JidoClaw.Telemetry.emit_verify(result)

    JidoClaw.Trace.emit(
      :composer,
      %{
        event: :verify_result,
        run_id: child.parent_run_id,
        parent_run_id: child.parent_run_id,
        stage: stage_name,
        result: result,
        mode: envelope.mode,
        checks: Enum.map(envelope.checks, & &1.name),
        kinds: Enum.uniq(Enum.map(envelope.failures, & &1.kind)),
        wave_index: wave_index,
        tenant_id: Map.fetch!(context, :tenant)
      },
      %{count: 1}
    )
  end
end

defmodule JidoClaw.Orchestration.Reactors.VerifyStage do
  @moduledoc """
  The `{:verify, "default"}` composer stage as a runnable single-stage wave
  (next-ten item 5, camus C1-2): a **non-halting** named `Ash.Reactor` module —
  the gate-reactor shape (`Reactors.PlanGate`) minus the park. It runs the
  repo's verify command through the engine (`JidoClaw.Orchestration.Verify`)
  and returns the WaveCollect-shaped emission map, so the composer folds it
  exactly like a worker wave.

  ## Shape

      input(:wave_index)       # the composer wave index this stage occupies
      input(:stage_name)       # the verify stage's catalog name (the producer)
      input(:lens)             # the stage lens ("verify" → clean:verify / findings:verify)
      input(:project_dir)      # the check cwd (from the composer's persisted scope)
      input(:sealed_head)      # the engine-observed sealed sha (nil ⇒ working-tree mode)
      input(:verify_override)  # the per-run command override (nil ⇒ config chain)

  `tenant`/`actor`/`workflow_run` arrive via reactor context (`ReactorRunner`
  seeds them). Dispatched by `JidoClaw.RouteComposer.run_verify_wave/5` under
  the deterministic `composer:<parent>:<wave_index>` idempotency key, so a
  restart re-dispatch dedupes + observes rather than re-running the checks.
  """

  use Ash.Reactor

  alias JidoClaw.Orchestration.Reactors.VerifyStage.RunVerify

  middlewares do
    middleware(JidoClaw.Orchestration.ReactorMiddleware)
  end

  input(:wave_index)
  input(:stage_name)
  input(:lens)
  input(:project_dir)
  input(:sealed_head)
  input(:verify_override)

  step :run_verify, RunVerify do
    argument(:wave_index, input(:wave_index))
    argument(:stage_name, input(:stage_name))
    argument(:lens, input(:lens))
    argument(:project_dir, input(:project_dir))
    argument(:sealed_head, input(:sealed_head))
    argument(:verify_override, input(:verify_override))
    max_retries(0)
  end

  return(:run_verify)
end
