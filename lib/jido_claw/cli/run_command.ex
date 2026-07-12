defmodule JidoClaw.CLI.RunCommand do
  @moduledoc """
  Headless one-shot entry point (osa OS1-5): `mix jidoclaw run "<prompt>"
  [dir] [flags]`, mirrored by the escript. Sends ONE message through
  `JidoClaw.chat/4` (with `composer_ack: :detailed`) and reports a
  machine-readable exit code — the OQ-4 exit contract, extended 0–6 by
  pre-argus Wave A #4 (multica MC3-4, adapted — new tiers get NEW codes;
  their 2=network/3=auth collide with our taken meanings):

    * `0` — success (inline answer with no pending approval, or a launched
      composer run that completed; a `done_with_findings` completion stays
      0 but is marked in the output)
    * `1` — error / failed run / await timeout (launched-run failures stay
      here deliberately — their provenance lives in run telemetry, not the
      exit code)
    * `2` — usage or config error (bad flags, malformed `--session` UUID,
      setup needed, session belonging to another workspace — found but
      invalid for the requested dir — boot failure)
    * `3` — human input needed: an approval gate pending — an inline
      tool-call case (probed via `AgentCase.pending_for_session/1` — the
      gate error is invisible in chat/4's return, the LLM just relays it as
      text) or a composer run-tree gate (`AgentCase.pending_for_run_tree/1`);
      case ids are printed for `/gates approve <id>`. OR a clarify question
      round (`outcome: :clarify_pending`, queue item 8): the ambiguous ask
      parked questions instead of composing — answer them on the same
      session (`--session <id>`) or re-run with "proceed with defaults".
    * `4` — not found: a well-formed `--session` UUID with no row, or
      `--continue` with no open CLI session in the workspace (a genuine
      miss — infrastructure failures reading the row stay `1`)
    * `5` — provider unreachable: the turn failed with a network-class
      provider error (`RunFailure` `agent_provider_network`)
    * `6` — provider auth: the turn failed with an auth/access-class
      provider error (`RunFailure` `agent_provider_auth_or_access`)

  ## Flags

    * `--format text|json` — output mode (default `text`; `json` is a single
      line on stdout — logs go to stderr)
    * `--session <uuid>` — resume a specific session (any kind, closed
      included); restore is `:strict` — history that can't be restored fails
      the run rather than running amnesic. The session must belong to the
      target directory's workspace.
    * `--continue` — resume the workspace's most recent OPEN CLI session
      (`:repl`/`:cli_run` kinds only — never a web `:api` thread); `:strict`
      restore like `--session`
    * `--timeout <seconds>` — composer await budget (default 600). Inline
      turns are bounded by chat/4's own 120s ask timeout instead.

  Positionals: the first is the prompt (required, non-empty); the optional
  second is an existing project directory (default: cwd).

  The core is pure — `main/2` returns `{exit_code, output}` and never halts
  or prints; the mix-task/escript wrappers own `IO.puts` + `System.halt` and
  inject the boot function via `opts[:boot]`.

  Fresh runs mint a `:cli_run` session (its own kind, so `--continue` can
  never resume a web `:api` thread); resumed sessions carry their OWN
  `kind`/`external_id` into chat/4 — the session identity includes kind, so
  hardcoding one for a resumed `:repl` row would mint a different row.
  """

  defmodule Result do
    @moduledoc """
    The one-shot outcome contract: the exit code plus every envelope field
    the text/JSON renderers read. One construction vocabulary for every
    outcome path (usage, boot, inline, composer await).
    """

    defstruct exit_code: 1,
              outcome: :error,
              route: nil,
              run_id: nil,
              message: nil,
              session_id: nil,
              pending_cases: [],
              disposition: nil,
              findings_deferred_count: nil,
              error: nil

    @type t :: %__MODULE__{
            exit_code: 0 | 1 | 2 | 3 | 4 | 5 | 6,
            outcome: atom(),
            route: :inline | :composer | :clarify | nil,
            run_id: String.t() | nil,
            message: String.t() | nil,
            session_id: String.t() | nil,
            pending_cases: [map()],
            disposition: String.t() | nil,
            findings_deferred_count: non_neg_integer() | nil,
            error: term()
          }
  end

  require Logger

  alias JidoClaw.Authorization.Actor
  alias JidoClaw.CLI.RunAwait
  alias JidoClaw.CLI.RunCommand.Result
  alias JidoClaw.CLI.Setup
  alias JidoClaw.Config
  alias JidoClaw.Conversations.Resolver, as: ConversationsResolver
  alias JidoClaw.Conversations.Session
  alias JidoClaw.Conversations.SessionId
  alias JidoClaw.Core.AshErrors
  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.Orchestration.AgentCase
  alias JidoClaw.Orchestration.RunFailure
  alias JidoClaw.Orchestration.Visibility
  alias JidoClaw.Tenants.Tenant
  alias JidoClaw.Workspaces.Resolver, as: WorkspacesResolver
  alias JidoClaw.Workspaces.Workspace

  @tenant_id "default"
  @default_timeout_seconds 600
  @strict_flags [format: :string, session: :string, continue: :boolean, timeout: :integer]

  @usage ~s(usage: mix jidoclaw run "<prompt>" [dir] [--session <uuid> | --continue] [--timeout <seconds>] [--format text|json])

  @type exit_code :: 0 | 1 | 2 | 3 | 4 | 5 | 6

  @doc """
  Parse `argv`, run the one-shot turn, and return `{exit_code, output}`.

  `opts[:boot]` injects the application-boot function (defaults to
  `Application.ensure_all_started/1` with the logger redirected to stderr);
  tests pass a no-op.
  """
  @spec main([String.t()], keyword()) :: {exit_code(), String.t()}
  def main(argv, opts \\ []) when is_list(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @strict_flags)
    format = resolve_format(parsed)

    result =
      case validate(parsed, positional, invalid) do
        {:ok, request} -> execute(request, opts)
        {:usage, message} -> usage_result(message)
      end

    render(format, result)
  end

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  defp resolve_format(parsed) do
    if Keyword.get(parsed, :format) == "json", do: :json, else: :text
  end

  defp validate(parsed, positional, invalid) do
    with :ok <- validate_invalid(invalid),
         :ok <- validate_format(Keyword.get(parsed, :format)),
         {:ok, prompt, dir} <- validate_positionals(positional),
         :ok <- validate_session_flags(parsed),
         {:ok, timeout_ms} <- validate_timeout(parsed) do
      {:ok,
       %{
         prompt: prompt,
         dir: dir,
         session: Keyword.get(parsed, :session),
         continue: Keyword.get(parsed, :continue, false),
         timeout_ms: timeout_ms
       }}
    end
  end

  defp validate_invalid([]), do: :ok

  defp validate_invalid(invalid) do
    flags = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
    {:usage, "invalid option(s): #{flags}"}
  end

  defp validate_format(format) when format in [nil, "text", "json"], do: :ok
  defp validate_format(other), do: {:usage, "unknown --format #{other} (use text or json)"}

  defp validate_positionals([]), do: {:usage, "missing prompt"}

  defp validate_positionals([prompt | rest]) do
    cond do
      String.trim(prompt) == "" ->
        {:usage, "empty prompt"}

      rest == [] ->
        {:ok, prompt, File.cwd!()}

      match?([_], rest) ->
        dir = Path.expand(hd(rest))

        if File.dir?(dir) do
          {:ok, prompt, dir}
        else
          {:usage, "#{hd(rest)} is not a directory"}
        end

      true ->
        {:usage, "unexpected extra arguments: #{Enum.join(tl(rest), " ")}"}
    end
  end

  defp validate_session_flags(parsed) do
    if is_binary(Keyword.get(parsed, :session)) and Keyword.get(parsed, :continue, false) do
      {:usage, "--session and --continue are mutually exclusive"}
    else
      :ok
    end
  end

  defp validate_timeout(parsed) do
    case Keyword.get(parsed, :timeout, @default_timeout_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, seconds * 1000}
      other -> {:usage, "--timeout must be a positive number of seconds, got #{inspect(other)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Boot + dispatch
  # ---------------------------------------------------------------------------

  defp execute(request, opts) do
    with :ok <- ensure_configured(request.dir),
         :ok <- boot(request.dir, opts) do
      dispatch(request)
    else
      {:usage, message} -> usage_result(message)
    end
  end

  defp ensure_configured(dir) do
    if Setup.needed?(dir) do
      {:usage, "project not configured — run `mix jidoclaw --setup` first (dir: #{dir})"}
    else
      :ok
    end
  end

  # `:project_dir` must be set BEFORE the app starts — supervision children
  # read it at boot, before the DB is queryable. `:serve_mode` stays unset so
  # the external MCP Consumer + `ensure_attached` keep working.
  defp boot(dir, opts) do
    config = Config.load(dir)
    model = Config.model(config)
    Application.put_env(:jido_ai, :model_aliases, %{fast: model, capable: model})
    Application.put_env(:jido_claw, :mode, :cli)
    Application.put_env(:jido_claw, :skip_discord, true)
    Application.put_env(:jido_claw, :project_dir, dir)

    boot_fn = Keyword.get(opts, :boot, &default_boot/0)

    case boot_fn.() do
      {:error, reason} -> {:usage, "boot failed: #{JidoClaw.format_error(reason)}"}
      _started -> ensure_project_state(dir)
    end

    # A boot raise (e.g. the Embeddings BootGuard's missing-VOYAGE_API_KEY
    # RuntimeError) is a config problem — exit 2 with the message.
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:usage, Exception.message(e)}
  end

  defp default_boot do
    # stdout carries only the result; logs go to stderr.
    JidoClaw.Application.redirect_logger_to_stderr()
    Application.ensure_all_started(:jido_claw)
  end

  defp ensure_project_state(dir) do
    case JidoClaw.Startup.ensure_project_state(dir) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[RunCommand] ensure_project_state: #{inspect(reason)}")
        :ok
    end
  end

  defp dispatch(request) do
    actor = Actor.system(@tenant_id)
    _ = Tenant.ensure(@tenant_id)

    with {:ok, workspace} <- ensure_workspace(request.dir, actor),
         {:ok, session, resumed?} <- resolve_session(request, workspace, actor) do
      run_turn(request, actor, session, resumed?)
    else
      {:usage, message} -> usage_result(message)
      {:not_found, message} -> not_found_result(message)
      {:error, reason} -> error_result(reason)
    end
  end

  defp ensure_workspace(dir, actor) do
    WorkspacesResolver.ensure_workspace(@tenant_id, dir, actor: actor)
  end

  # `--session <uuid>`: resumes anything (closed included) — but only inside
  # its own workspace. chat/4 resolves persistence from the DIRECTORY's
  # workspace, so a foreign UUID would mint/touch a different
  # `(workspace, kind, external_id)` row and run tools in the wrong cwd.
  # Exit-tier split (MC3-4): malformed UUID = caller mistake (2); a
  # well-formed UUID with no row = a genuine miss (4); an infrastructure
  # failure READING the row keeps the generic error lane (1) — a flaky DB
  # must never report "not found".
  defp resolve_session(%{session: uuid} = _request, workspace, actor) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _canonical} -> resolve_session_by_id(uuid, workspace, actor)
      :error -> {:usage, "#{uuid} is not a valid session UUID"}
    end
  end

  defp resolve_session(%{continue: true}, workspace, actor) do
    case Session.most_recent_for_workspace(workspace.id, tenant: @tenant_id, actor: actor) do
      {:ok, session} ->
        {:ok, session, true}

      {:error, reason} ->
        if AshErrors.not_found?(reason) do
          {:not_found,
           "no open CLI session to continue in this workspace — run without --continue"}
        else
          {:error, reason}
        end
    end
  end

  defp resolve_session(request, workspace, actor) do
    external_id = SessionId.new()

    case ConversationsResolver.ensure_session(@tenant_id, workspace.id, :cli_run, external_id,
           actor: actor,
           project_dir: request.dir
         ) do
      {:ok, session} -> {:ok, session, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_session_by_id(uuid, workspace, actor) do
    case Session.by_id(uuid, tenant: @tenant_id, actor: actor) do
      {:ok, session} when session.workspace_id == workspace.id ->
        {:ok, session, true}

      {:ok, session} ->
        {:usage, foreign_workspace_message(session, actor)}

      {:error, reason} ->
        if AshErrors.not_found?(reason) do
          {:not_found, "session #{uuid} not found"}
        else
          {:error, reason}
        end
    end
  end

  defp foreign_workspace_message(session, actor) do
    where =
      case Workspace.by_id(session.workspace_id, tenant: @tenant_id, actor: actor) do
        {:ok, ws} -> "workspace #{ws.path}"
        _ -> "a different workspace"
      end

    "session #{session.id} belongs to #{where} — run from there (or pass that dir)"
  end

  defp run_turn(request, actor, session, resumed?) do
    # Explicit resume must fail loud when history can't be restored; a fresh
    # session has nothing to restore, so best-effort is fine there.
    restore_mode = if resumed?, do: :strict, else: :best_effort
    turn_started_at = DateTime.utc_now()

    # `clarify: :loop` (queue item 8): one-shot INVOCATION, resumable SESSION
    # — a parked question round is answerable via `--session <id>` (printed
    # with the exit-3 output), so parking beats a silent degraded compose.
    chat_result =
      JidoClaw.chat(@tenant_id, session.external_id, request.prompt,
        kind: session.kind,
        external_id: session.external_id,
        workspace_id: request.dir,
        actor: actor,
        composer_ack: :detailed,
        context_restore: restore_mode,
        clarify: :loop
      )

    outcome_for(chat_result, %{
      request: request,
      actor: actor,
      session: session,
      turn_started_at: turn_started_at
    })
  end

  # ---------------------------------------------------------------------------
  # Outcome → exit code
  # ---------------------------------------------------------------------------

  # Inline answers hide a tripped approval gate inside the relayed text, so
  # ANY pending case on the session ⇒ 3 — deliberately NOT filtered by
  # inserted_at: `ToolApprovals` reuses an existing pending case for the same
  # fingerprint without touching it, so a re-triggered gate can predate this
  # run. The `fresh` flag distinguishes them in the output instead.
  defp outcome_for({:ok, %{route: :inline, message: message}}, env) do
    base = %Result{route: :inline, message: message, session_id: env.session.id}

    case pending_session_cases(env) do
      {:ok, []} ->
        %{base | exit_code: 0, outcome: :answered}

      {:ok, cases} ->
        %{base | exit_code: 3, outcome: :gate_pending, pending_cases: cases}

      {:error, reason} ->
        %{base | error: {:gate_probe_failed, reason}}
    end
  end

  defp outcome_for(
         {:ok, %{route: :composer, status: :launched, run_id: run_id, message: message}},
         env
       ) do
    base = %Result{route: :composer, run_id: run_id, message: message, session_id: env.session.id}

    run_id
    |> RunAwait.await(@tenant_id, env.actor, env.request.timeout_ms)
    |> await_outcome(base)
  end

  # A clarify question round (queue item 8): the OQ-4 "human input needed"
  # exit family — no run exists yet; the questions ARE the output. The
  # printed session id is what `--session` needs to answer them.
  defp outcome_for({:ok, %{route: :clarify, message: message}}, env) do
    %Result{
      exit_code: 3,
      outcome: :clarify_pending,
      route: :clarify,
      message: message,
      session_id: env.session.id
    }
  end

  defp outcome_for({:ok, %{route: :composer, status: :failed_to_start, message: message}}, env) do
    %Result{
      route: :composer,
      message: message,
      session_id: env.session.id,
      error: "composer run failed to start"
    }
  end

  defp outcome_for({:error, {:context_restore_failed, reason}}, env) do
    %Result{
      session_id: env.session.id,
      error:
        "session history could NOT be restored — refusing to run the resumed turn amnesic: " <>
          JidoClaw.format_error(reason)
    }
  end

  # Provider tiers (MC3-4): auth/network-class provider failures on the turn
  # get their own exit codes via the RunFailure taxonomy — classified here at
  # the generic error arm only. Everything else keeps exit 1; the launched-run
  # `{:done, :failed, _}` path deliberately stays 1 (run provenance lives in
  # run telemetry, not the exit code).
  defp outcome_for({:error, reason}, env) do
    base = %Result{session_id: env.session.id, error: reason}

    case RunFailure.classify(reason) do
      :agent_provider_auth_or_access -> %{base | exit_code: 6, outcome: :provider_auth}
      :agent_provider_network -> %{base | exit_code: 5, outcome: :provider_unreachable}
      _other -> base
    end
  end

  defp pending_session_cases(env) do
    case AgentCase.pending_for_session(env.session.id, tenant: @tenant_id, actor: env.actor) do
      {:ok, cases} ->
        {:ok,
         Enum.map(cases, fn c ->
           %{
             id: c.id,
             tool: c.tool_name,
             fresh: DateTime.compare(c.inserted_at, env.turn_started_at) != :lt
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Exit 0 for BOTH completed shapes (the pinned OQ-4 0/1/2/3 contract) — but
  # a done-with-findings completion marks the text + JSON envelope with the
  # disposition + deferred count (camus C1-4's "never plain green").
  defp await_outcome({:done, :completed, run}, base) do
    view = Visibility.run_view(run, :operator, DateTime.utc_now())

    %{
      base
      | exit_code: 0,
        outcome: :launched_completed,
        disposition: view.disposition,
        findings_deferred_count: view.findings_deferred_count
    }
  end

  defp await_outcome({:done, status, run}, base)
       when status in [:failed, :cancelled, :abandoned] do
    view = Visibility.run_view(run, :operator, DateTime.utc_now())
    %{base | outcome: status, error: view.error || "run #{status}"}
  end

  defp await_outcome({:gate_pending, case_ids}, base) do
    %{
      base
      | exit_code: 3,
        outcome: :gate_pending,
        pending_cases: Enum.map(case_ids, &%{id: &1, tool: nil, fresh: true})
    }
  end

  defp await_outcome(:timeout, base) do
    %{base | outcome: :timeout, error: "await timed out — run still in progress: #{base.run_id}"}
  end

  defp await_outcome({:error, reason}, base) do
    %{base | error: reason}
  end

  defp usage_result(message) do
    %Result{exit_code: 2, outcome: :usage, error: message}
  end

  defp not_found_result(message) do
    %Result{exit_code: 4, outcome: :not_found, error: message}
  end

  defp error_result(reason) do
    %Result{error: reason}
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render(:json, %Result{} = result) do
    envelope = %{
      "ok" => result.exit_code == 0,
      "exit_code" => result.exit_code,
      "route" => result.route && to_string(result.route),
      "outcome" => to_string(result.outcome),
      "session_id" => result.session_id,
      "run_id" => result.run_id,
      "message" => result.message,
      "disposition" => result.disposition,
      "findings_deferred_count" => result.findings_deferred_count,
      "pending_cases" =>
        Enum.map(result.pending_cases, fn c ->
          %{"id" => c.id, "tool" => c[:tool], "fresh" => c.fresh}
        end),
      "error" => encode_error(result.error)
    }

    {result.exit_code, Jason.encode!(envelope)}
  end

  defp render(:text, %Result{} = result) do
    lines =
      [
        result.message,
        run_line(result),
        pending_block(result.pending_cases),
        error_line(result.error),
        usage_line(result.outcome),
        session_line(result.session_id)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    {result.exit_code, lines}
  end

  defp encode_error(nil), do: nil
  defp encode_error(error) when is_binary(error), do: error
  defp encode_error(error), do: JsonSafe.encode(error)

  defp run_line(%Result{run_id: run_id, outcome: outcome} = result) when is_binary(run_id) do
    case outcome do
      :launched_completed -> "✓ composer run #{run_id} completed#{disposition_suffix(result)}"
      :gate_pending -> "composer run #{run_id} awaiting approval"
      :timeout -> nil
      other when other in [:failed, :cancelled, :abandoned] -> "✗ composer run #{run_id} #{other}"
      _ -> nil
    end
  end

  defp run_line(_result), do: nil

  # Camus C1-4: a done-with-findings completion is never plain green — exit 0
  # holds, but the line carries the disposition + deferred-findings count.
  defp disposition_suffix(%Result{disposition: "done_with_findings"} = result) do
    count = result.findings_deferred_count || 0
    " · done_with_findings (#{count} finding(s) deferred)"
  end

  defp disposition_suffix(_result), do: ""

  defp pending_block([]), do: nil

  defp pending_block(cases) do
    rows =
      Enum.map_join(cases, "\n", fn c ->
        label = if c.fresh, do: "", else: "  (pending since before this run)"
        tool = if c[:tool], do: " #{c[:tool]}", else: ""
        "  #{c.id}#{tool}#{label}"
      end)

    "Approval required — pending case(s):\n" <>
      rows <>
      "\nDecide via `/gates approve <id>` in the REPL or the web /approvals page."
  end

  defp error_line(nil), do: nil
  defp error_line(error) when is_binary(error), do: "error: #{error}"
  defp error_line(error), do: "error: #{JidoClaw.format_error(error)}"

  defp usage_line(:usage), do: @usage
  defp usage_line(_outcome), do: nil

  defp session_line(nil), do: nil
  defp session_line(session_id), do: "session: #{session_id}"
end
