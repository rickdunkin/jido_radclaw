defmodule JidoClaw.Forge.Runners.ClaudeCode do
  @moduledoc """
  Forge runner for the Claude Code CLI (`claude -p`).

  ## Executor knobs (PR-2 — defaults preserve the consolidator byte-for-byte)

    * `config_sync: :full (default) | :auth_only` — `:full` syncs the host
      `~/.claude` whitelist into `forge_home/.claude` and pins an allow-all
      `settings.json` (today's consolidator posture, unchanged). `:auth_only`
      builds an ISOLATED per-run config dir instead: the credential alone
      crosses, resolved through the shared source (host `.credentials.json`
      → legacy `credentials.json` → macOS Keychain via the
      `:claude_keychain_reader` seam) and written to the DOTTED
      `<config_dir>/.credentials.json` — what claude reads under
      `CLAUDE_CONFIG_DIR` — through a CHECKED exec-based base64 write +
      `chmod 600` (`FileSync.write_checked/3`; a failed write fails the init
      CLOSED). A minimal non-allow-all `settings.json` rides the same
      transport (best-effort), and `CLAUDE_CONFIG_DIR` is injected so
      claude's whole config universe is the per-run dir — host
      settings/skills/CLAUDE.md/plugins cannot bleed in (review finding P1b:
      HostShell inherits the allowlisted `HOME`, so without the env override
      claude reads the operator's REAL `~/.claude`; the `forge_home/.claude`
      file writes alone are decorative there). A failed env inject fails the
      init CLOSED — an unisolated session must not start.
    * `access: :full (default) | :read_only` — `:full` keeps
      `--dangerously-skip-permissions`. `:read_only` (the vendor-executor
      posture) replaces it with a restricted `--tools` read set,
      `--allowedTools` (read set + `allowed_mcp_tools`),
      `--permission-mode dontAsk` (auto-deny instead of prompt-hang in
      headless `-p`), and `--strict-mcp-config`.
    * `allowed_mcp_tools` — full `mcp__<server>__<tool>` names appended to
      `--allowedTools` under `:read_only` (the executor passes its deposit
      tool).
    * `add_dirs` — repeated `--add-dir` entries (the executor's
      `workspace: :repo` grant; claude's cwd is the HostShell sandbox dir and
      is not ours to set).
    * `resume: :off (default) | :armed` — native CLI session resume
      (docs/system/forge-session-resume.md). `:off` is byte-identical to
      today: fresh `-p` per iteration, no session flags (PR-3 pin; the
      executor never arms). `:armed` mints a client-owned `--session-id`
      pre-spawn on the first turn and continues a trusted anchor with
      `--resume <id>` + a guidance-only prompt (never the original task,
      never `--continue`). The anchor lifecycle lives in
      `JidoClaw.Forge.ResumeState`; the pre-spawn anchor persist goes
      through the injected `:forge_resume_writer` seam (default
      `Persistence.anchor_session/3`) so a crash mid-attempt can still
      resume.
  """
  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{Persistence, RecoveredSpec, ResumeState, Runner, Sandbox}
  alias JidoClaw.Forge.Runners.{FileSync, ResumePolicy}
  alias JidoClaw.Security.Redaction.Env
  alias JidoClaw.Security.Redaction.PromptRedaction
  require Logger

  # Shared between `init/2` and `materialize_config/1` so the persisted
  # materialized posture can never drift from what a fresh init applies.
  @default_model "claude-sonnet-4-20250514"
  @default_max_turns 200
  @default_timeout_ms 300_000

  # Files/dirs from ~/.claude worth syncing into the sandbox.
  # Excludes logs, telemetry, and other ephemeral data.
  @syncable_entries ~w(settings.json credentials.json skills CLAUDE.md)
  @auth_file "credentials.json"
  # What claude actually READS under CLAUDE_CONFIG_DIR (in-VM Linux and
  # modern macOS write the dotted name; the dotless @auth_file is the legacy
  # host layout the :full sync still mirrors verbatim).
  @dotted_auth_file ".credentials.json"
  @keychain_service "Claude Code-credentials"

  # The built-in read-tool set `access: :read_only` pins (verified against the
  # operator-installed CLI at the PR-2 build-time smoke; PR-3's `.jido/config.yaml`
  # `review: executor:` lane is the first production declarer — operator config,
  # not a committed template).
  @read_only_tools ~w(Read Glob Grep)

  @impl Runner
  def init(client, config) do
    prompt = Map.get(config, :prompt, "")
    model = Map.get(config, :model, @default_model)
    session_name = Map.get(config, :session_name)
    max_turns = Map.get(config, :max_turns, @default_max_turns)
    timeout_ms = Map.get(config, :timeout_ms, @default_timeout_ms)
    mcp_config_path = Map.get(config, :mcp_config_path)
    thinking_effort = Map.get(config, :thinking_effort)
    forge_home = Map.get(config, :forge_home, default_forge_home())
    config_sync = Map.get(config, :config_sync, :full)

    with :ok <- sync_host_claude_config(client, forge_home, config_sync),
         :ok <- write_mcp_config(client, config),
         {:ok, resume_state, resume_cwd} <- init_resume(client, Map.get(config, :resume, :off)) do
      if prompt != "" do
        redacted = PromptRedaction.redact(prompt)
        Sandbox.write_file(client, "#{forge_home}/session/context.md", redacted)
      end

      {:ok,
       %{
         model: model,
         prompt: prompt,
         iteration: 0,
         session_name: session_name,
         max_turns: max_turns,
         timeout_ms: timeout_ms,
         mcp_config_path: mcp_config_path,
         thinking_effort: thinking_effort,
         forge_home: forge_home,
         access: Map.get(config, :access, :full),
         allowed_mcp_tools: Map.get(config, :allowed_mcp_tools, []),
         add_dirs: Map.get(config, :add_dirs, []),
         strict_mcp: Map.get(config, :strict_mcp, false),
         resume: resume_state,
         resume_cwd: resume_cwd
       }}
    end
  end

  # `pwd` workdir capture happens ONLY when armed — a default-off init makes
  # no extra sandbox call and carries no resume machinery (PR-3 pin).
  defp init_resume(_client, :off), do: {:ok, nil, nil}

  defp init_resume(client, :armed) do
    case Sandbox.exec(client, "pwd", []) do
      {output, 0} ->
        cwd = presence(String.trim(output))
        {:ok, ResumeState.new(workdir: cwd), cwd}

      {_output, _code} ->
        # Unknown cwd: stay armed but the cwd-gate can never pass, so every
        # turn resolves fresh-armed — resume-off behavior with anchors.
        {:ok, ResumeState.new(), nil}
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # Docker write build: a docker executor plan carries the deposit client
  # config as CONTENT (`mcp_config_json`) because the host-tmp file the local
  # path writes doesn't exist in-VM — without this in-VM write claude has no
  # deposit server at all. Checked: a session without its deposit config must
  # not start (fail init CLOSED). Absent (local plans, consolidator) ⇒ no-op.
  defp write_mcp_config(client, %{mcp_config_json: json, mcp_config_path: path} = _config)
       when is_binary(json) and is_binary(path) and path != "",
       do: FileSync.write_checked(client, path, json)

  defp write_mcp_config(_client, _config), do: :ok

  # The complete static config, every init/2 default written explicitly and
  # stamped for `RecoveredSpec.runner_config/1` — a recovered session
  # re-inits with exactly this posture, never a re-applied default (the
  # consolidator omits `access`; a defaulting decode would flip recovered
  # sessions off `:full` and drop their MCP tools). Attempt-scoped values
  # (`mcp_config_path`, `mcp_config_json` — per-attempt capability material)
  # are deliberately absent: they ride `run_iteration` opts, never the
  # persisted row. Nil optionals are omitted rather than persisted as null.
  @impl Runner
  def materialize_config(config) do
    materialized = %{
      config_codec: RecoveredSpec.codec_stamp(:claude_code),
      prompt: Map.get(config, :prompt, ""),
      model: Map.get(config, :model, @default_model),
      session_name: Map.get(config, :session_name),
      max_turns: Map.get(config, :max_turns, @default_max_turns),
      timeout_ms: Map.get(config, :timeout_ms, @default_timeout_ms),
      thinking_effort: Map.get(config, :thinking_effort),
      forge_home: Map.get(config, :forge_home, default_forge_home()),
      config_sync: Map.get(config, :config_sync, :full),
      access: Map.get(config, :access, :full),
      allowed_mcp_tools: Map.get(config, :allowed_mcp_tools, []),
      add_dirs: Map.get(config, :add_dirs, []),
      strict_mcp: Map.get(config, :strict_mcp, false),
      resume: Map.get(config, :resume, :off)
    }

    Map.reject(materialized, fn {_key, value} -> is_nil(value) end)
  end

  # The armed-vs-off dispatch is deliberately IDENTICAL in both vendor
  # runners — it's the behaviour's shape, not copied logic (the divergent
  # bodies live below; the shared policy lives in ResumePolicy).
  # ex_dna:disable-for-lines:5
  @impl Runner
  def run_iteration(client, %{resume: %ResumeState{} = rs} = state, opts),
    do: run_armed_iteration(client, attempt_state(state, opts), rs, opts)

  def run_iteration(client, state, opts),
    do: run_default_iteration(client, attempt_state(state, opts), opts)

  # Attempt-scoped endpoint capability: a driver may mint a per-attempt
  # MCP config file (tokenized URL) and pass its path per turn — it rides
  # `run_iteration` opts only, never the persisted config, and the
  # checkpoint codec never serializes it. Absent ⇒ the init-time value
  # stands (byte-identical argv — the PR-3 pin holds).
  defp attempt_state(state, opts) do
    case Keyword.get(opts, :mcp_config_path) do
      path when is_binary(path) and path != "" -> Map.put(state, :mcp_config_path, path)
      _absent -> state
    end
  end

  # Default-off: today's fresh `-p` invocation, byte-identical — no session
  # flags, no resume bookkeeping, no metadata.state (PR-3 pin: the executor
  # relies on fresh-session-per-round structurally).
  defp run_default_iteration(client, state, opts) do
    args = build_args(state, Keyword.get(opts, :prompt, state.prompt), [])

    case dispatch(client, state, args, opts) do
      {output, 0} -> parse_output(output)
      {output, :timeout} -> {:ok, Runner.error("harness_timeout", output)}
      {output, _code} -> {:ok, Runner.error("claude cli failed", output)}
    end
  end

  # Armed: the per-turn mode gate. Only a trusted anchor in THIS
  # incarnation's workdir continues; everything else (unanchored,
  # poisoned, cwd mismatch, unknown cwd) starts fresh-armed. Every path
  # below returns `metadata.state` — error and timeout terminals included —
  # because the pre-spawn mint must reach harness state, and the harness
  # merges runner state only via metadata.
  defp run_armed_iteration(client, state, rs, opts) do
    case ResumeState.resolve_mode(rs, Map.get(state, :resume_cwd)) do
      :continuation ->
        run_continuation(client, state, ResumeState.continuing(rs), opts)

      {:fresh_armed, _reason} ->
        run_fresh_armed(client, state, rs, opts)
    end
  end

  # Fresh-armed: mint the session id CLIENT-side and persist the anchor
  # BEFORE the CLI spawns (`--session-id` makes the id ours to choose;
  # a crash mid-attempt can then still resume). PORT-MC1-1 sign-off Q1.
  # The prompt source is `opts[:prompt]`-else-`state.prompt` — the caller's
  # `:guidance` opt is structurally IGNORED here (it means "continuation
  # guidance"), so a fresh conversation always carries the full task. An
  # inflight parked answer reverts to :pending first (this turn provably
  # never places it on an argv; it redelivers on the next continuation).
  defp run_fresh_armed(client, state, rs, opts) do
    rs = ResumeState.guidance_undelivered(rs)
    minted_id = Ecto.UUID.generate()

    case anchor_fresh(rs, minted_id, Map.get(state, :resume_cwd)) do
      {:ok, anchored} ->
        stamped = stamp_for_mirror(anchored, opts)
        persist_anchor_pre_spawn(stamped, opts)

        args =
          build_args(
            state,
            Keyword.get(opts, :prompt, state.prompt),
            session_flags(:fresh_armed, stamped)
          )

        case dispatch(client, state, args, opts) do
          {output, 0} ->
            finalize_fresh_armed(output, state, stamped, minted_id, opts)

          {output, :timeout} ->
            armed_failure({:known, "harness_timeout"}, output, state, stamped, :fresh_armed, opts)

          {output, _code} ->
            armed_failure(
              {:classify, "claude cli failed"},
              output,
              state,
              stamped,
              :fresh_armed,
              opts
            )
        end

      {:error, reason} ->
        # Effectively unreachable for a generated UUID — run the turn
        # unarmed rather than failing real work on resume bookkeeping.
        Logger.warning("[ClaudeCode] could not establish a fresh anchor: #{inspect(reason)}")
        run_default_iteration(client, state, opts)
    end
  end

  # Continuation: `--resume <anchor>` with a GUIDANCE-ONLY prompt — parked
  # inflight text first, then the caller's `:guidance` opt, then the shared
  # nudge (`ResumePolicy.take_continuation_guidance/2`). `opts[:prompt]` is
  # never read: the original task already lives in the resumed conversation,
  # so it never rides the argv again (CM2-3). Never `--continue`, never
  # `--session-id`.
  defp run_continuation(client, state, rs, opts) do
    {guidance, rs} = ResumePolicy.take_continuation_guidance(rs, opts)
    args = build_args(state, guidance, session_flags(:continuation, rs))

    case dispatch(client, state, args, opts) do
      {output, 0} ->
        finalize_continuation(output, state, rs, opts)

      {output, :timeout} ->
        armed_failure({:known, "harness_timeout"}, output, state, rs, :continuation, opts)

      {output, _code} ->
        armed_failure({:classify, "claude cli failed"}, output, state, rs, :continuation, opts)
    end
  end

  # Fresh anchors from every non-continuable posture: a poisoned id is never
  # reused (`rearm_new_anchor/4` refuses it and resets the retry latch); an
  # anchored-but-not-continuable state (cwd mismatch, no workdir) clears
  # first — the old conversation is unreachable from this workdir.
  defp anchor_fresh(%ResumeState{status: :poisoned} = rs, minted_id, cwd),
    do: ResumeState.rearm_new_anchor(rs, minted_id, cwd, :client)

  defp anchor_fresh(%ResumeState{status: :unanchored} = rs, minted_id, cwd),
    do: ResumeState.mint_client(rs, minted_id, cwd)

  defp anchor_fresh(%ResumeState{} = rs, minted_id, cwd) do
    cleared = ResumeState.clear(rs, :new)
    ResumeState.mint_client(cleared, minted_id, cwd)
  end

  # Session flags derive ONLY from the resolved mode + anchor id;
  # permission/trust flags derive only from `state.access` in
  # `permission_args/1` — the two never mix, and the selectors never
  # combine (CM2-3).
  defp session_flags(:continuation, %ResumeState{session_id: id}) when is_binary(id),
    do: ["--resume", id]

  defp session_flags(:fresh_armed, %ResumeState{session_id: id}) when is_binary(id),
    do: ["--session-id", id]

  defp session_flags(_mode, %ResumeState{}), do: []

  # Stamp {incarnation epoch, next revision} before the pre-spawn persist;
  # the harness's post-iteration mirror bumps onward from this returned copy.
  defp stamp_for_mirror(rs, opts) do
    epoch = Keyword.get(opts, :incarnation_epoch, rs.epoch)
    ResumeState.stamp(rs, epoch, rs.revision + 1)
  end

  # Fresh-armed only: the anchor must be durable BEFORE the CLI exists.
  # Fenced — a stale incarnation's write surfaces :stale_resume_write and is
  # logged + dropped, never blocking the turn. Skips cleanly when the
  # harness didn't thread a claimed session + token (claim: false runs,
  # direct callers).
  defp persist_anchor_pre_spawn(rs, opts) do
    session_id = Keyword.get(opts, :forge_session_id)
    token = Keyword.get(opts, :incarnation_token)

    if is_binary(session_id) and is_binary(token) do
      case resume_writer().(session_id, rs, token) do
        {:error, :stale_resume_write} ->
          Logger.warning(
            "[ClaudeCode] pre-spawn anchor write fenced out (stale incarnation) — dropped"
          )

        _ok_or_best_effort_nil ->
          :ok
      end
    end

    :ok
  end

  # Injectable writer seam (the `:claude_keychain_reader` idiom) so runner
  # unit tests observe the pre-spawn persist without a DB. Anything but a
  # 3-arity fun falls back to the real fenced writer.
  defp resume_writer do
    case Application.get_env(:jido_claw, :forge_resume_writer) do
      fun when is_function(fun, 3) -> fun
      _absent_or_invalid -> &Persistence.anchor_session/3
    end
  end

  # Fresh-armed id-verify: the CLI's "system" init event must echo the id we
  # minted. A mismatch means the conversation is NOT under our anchor —
  # drop it (loudly, via the shared mismatch emitter; runners never
  # auto-retry). A missing echo (older CLI stream shape) trusts the
  # client-owned mint.
  defp finalize_fresh_armed(output, state, rs, minted_id, opts) do
    {:ok, result} = parse_output(output)

    final_rs =
      case echoed_session_id(result) do
        nil ->
          rs

        ^minted_id ->
          rs

        other ->
          ResumePolicy.emit_anchor_mismatch(
            :claude_code,
            :fresh_armed,
            minted_id,
            "session-id verify mismatch: minted #{minted_id}, CLI reported #{inspect(other)} — anchor dropped",
            opts
          )

          ResumeState.clear(rs, :new)
      end

    {:ok, ResumePolicy.attach_runner_state(result, state, final_rs)}
  end

  # Continuation echo-verify: a resumed conversation reports its own id — a
  # different one means the CLI silently started elsewhere; the anchor no
  # longer names the live conversation, so drop it loudly.
  defp finalize_continuation(output, state, rs, opts) do
    {:ok, result} = parse_output(output)

    final_rs =
      case echoed_session_id(result) do
        nil ->
          rs

        sid when sid == rs.session_id ->
          rs

        other ->
          ResumePolicy.emit_anchor_mismatch(
            :claude_code,
            :continuation,
            rs.session_id,
            "continuation echoed session #{inspect(other)} instead of anchor #{rs.session_id} — anchor dropped",
            opts
          )

          ResumeState.clear(rs, :new)
      end

    {:ok, ResumePolicy.attach_runner_state(result, state, final_rs)}
  end

  # Armed terminal failures classify + poison + emit through the shared
  # vendor policy (`ResumePolicy.armed_failure/7`) — one module so the two
  # runners cannot drift.
  defp armed_failure(labeling, output, state, rs, mode, opts),
    do: ResumePolicy.armed_failure(:claude_code, labeling, output, state, rs, mode, opts)

  defp echoed_session_id(result) do
    result.metadata
    |> Map.get(:tool_events, [])
    |> Enum.find_value(fn
      %{"type" => "system", "session_id" => sid} when is_binary(sid) -> sid
      _ -> nil
    end)
  end

  # `--verbose` is REQUIRED alongside `-p --output-format stream-json` on
  # current claude CLIs (≥ ~2.1.19x refuse without it — write-build smoke;
  # PR-2 shipped against an older CLI that tolerated its absence). The
  # verbose stream adds event types `parse_output/1` already drops.
  # `session_flags` land LAST — model/mcp/effort are rebuilt fresh from
  # state every turn regardless of anchor (CM2-3).
  defp build_args(state, prompt, session_flags) do
    redacted_prompt = PromptRedaction.redact(prompt)
    max_turns = Map.get(state, :max_turns) || @default_max_turns

    (["-p", redacted_prompt, "--model", state.model] ++
       permission_args(state) ++
       [
         "--output-format",
         "stream-json",
         "--verbose",
         "--max-turns",
         Integer.to_string(max_turns)
       ])
    |> append_add_dirs(state)
    |> append_mcp_config(state)
    |> append_thinking_effort(state)
    |> Kernel.++(session_flags)
  end

  defp dispatch(client, state, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout, Map.get(state, :timeout_ms) || @default_timeout_ms)
    base_run_opts = [timeout: timeout_ms] ++ teardown_opts(opts)

    run_opts =
      if state.session_name,
        do: [{:name, state.session_name} | base_run_opts],
        else: base_run_opts

    Sandbox.run(client, "claude", args, run_opts)
  end

  # The CLI-runner path opts into GRACEFUL tree teardown (ChildTracker
  # registration in HostShell) when the harness threaded an incarnation
  # key; generic exec stays hard, and docker tiers keep
  # teardown-by-destruction (their backend ignores these opts).
  defp teardown_opts(opts) do
    case Keyword.get(opts, :incarnation_key) do
      nil -> []
      key -> [teardown: :graceful, incarnation_key: key]
    end
  end

  # `:read_only` — never `--dangerously-skip-permissions`: the restricted
  # `--tools` set is the hard floor, `--allowedTools` pre-approves that floor
  # plus the caller's MCP tools, `dontAsk` auto-denies anything else instead
  # of prompt-hanging headless, and `--strict-mcp-config` pins the MCP surface
  # to the passed `--mcp-config` file alone.
  defp permission_args(%{access: :read_only} = state) do
    read_set = Enum.join(@read_only_tools, ",")
    allowed = Enum.join(@read_only_tools ++ state.allowed_mcp_tools, ",")

    [
      "--tools",
      read_set,
      "--allowedTools",
      allowed,
      "--permission-mode",
      "dontAsk",
      "--strict-mcp-config"
    ]
  end

  # The write arm (docker write build): the bypass flag is the runners'
  # existing `:full` posture — the microVM + workspace mount mode is the
  # boundary — and `strict_mcp` still pins the MCP surface to the passed
  # `--mcp-config` alone (orthogonal to permissions: a mounted repo's
  # `.mcp.json` must not shadow/expand the deposit surface). Default absent ⇒
  # the consolidator args stay byte-identical.
  defp permission_args(state),
    do: ["--dangerously-skip-permissions"] ++ strict_mcp_args(state)

  defp strict_mcp_args(%{strict_mcp: true}), do: ["--strict-mcp-config"]
  defp strict_mcp_args(_state), do: []

  defp append_add_dirs(args, %{add_dirs: [_ | _] = dirs}),
    do: args ++ Enum.flat_map(dirs, &["--add-dir", &1])

  defp append_add_dirs(args, _), do: args

  defp append_mcp_config(args, %{mcp_config_path: path}) when is_binary(path) and path != "",
    do: args ++ ["--mcp-config", path]

  defp append_mcp_config(args, _), do: args

  defp append_thinking_effort(args, %{thinking_effort: effort})
       when is_binary(effort) and effort != "",
       do: args ++ ["--effort", effort]

  defp append_thinking_effort(args, _), do: args

  @impl Runner
  def apply_input(client, input, state) do
    forge_home = Map.get(state, :forge_home, default_forge_home())

    Sandbox.write_file(
      client,
      "#{forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  # The shared checkpoint codec (ResumePolicy): {iteration, sanitized
  # resume state}; static config recovers through the materialized-config
  # codec instead. The fresh init's pwd stays `resume_cwd` — the cwd-gate
  # input a restored foreign-workdir anchor fails next turn.
  @impl Runner
  def serialize_state(state), do: ResumePolicy.serialize_state(state)

  @impl Runner
  def restore_state(state, snapshot), do: ResumePolicy.restore_state(state, snapshot)

  defp parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    {events, last_result, turns} =
      Enum.reduce(lines, {[], nil, 0}, fn line, {events_acc, result_acc, turns_acc} ->
        if String.starts_with?(line, "{") do
          case Jason.decode(line) do
            {:ok, %{"type" => "assistant"} = decoded} ->
              {[decoded | events_acc], result_acc, turns_acc + 1}

            {:ok, %{"type" => type} = decoded}
            when type in ["tool_use", "tool_result", "system"] ->
              {[decoded | events_acc], result_acc, turns_acc}

            {:ok, %{"type" => "result"} = result} ->
              {events_acc, result, turns_acc}

            _ ->
              {events_acc, result_acc, turns_acc}
          end
        else
          {events_acc, result_acc, turns_acc}
        end
      end)

    metadata = %{tool_events: Enum.reverse(events), turns: turns}

    base =
      case last_result do
        %{"subtype" => "error_max_turns"} -> Runner.continue(output)
        _ -> Runner.done(output)
      end

    {:ok, %{base | metadata: Map.merge(base.metadata, metadata)}}
  end

  # `:full` — today's consolidator posture, byte-identical: sync the host
  # whitelist into forge_home/.claude, then pin the allow-all settings.json
  # (the sync would have overwritten any existing one).
  defp sync_host_claude_config(client, forge_home, :full) do
    with :ok <- sync_full_whitelist(client, forge_home) do
      settings = Jason.encode!(%{permissions: %{allow: ["*"]}})
      Sandbox.write_file(client, "#{forge_home}/.claude/settings.json", settings)
      :ok
    end
  end

  # `:auth_only` — the isolated per-run config universe (P1b). Everything
  # lands through exec-based writes (`FileSync`), and `CLAUDE_CONFIG_DIR` is
  # what makes it real on HostShell: without it claude reads the operator's
  # host `~/.claude`, so a failed inject fails the init closed. The
  # credential is resolved through the shared source (dotted file → legacy
  # file → macOS Keychain) and lands at the DOTTED in-sandbox name — what
  # claude reads under CLAUDE_CONFIG_DIR — via a CHECKED write (a session
  # without its credential must not start).
  defp sync_host_claude_config(client, forge_home, :auth_only) do
    config_dir = "#{forge_home}/.claude"

    with {:ok, credentials} <- resolve_host_credentials() do
      for dir <- ["#{forge_home}/session", "#{forge_home}/templates", config_dir] do
        Sandbox.exec(client, "mkdir -p #{dir}", [])
      end

      with :ok <-
             FileSync.write_checked(client, "#{config_dir}/#{@dotted_auth_file}", credentials) do
        FileSync.write_content(client, "#{config_dir}/settings.json", "{}")

        case Sandbox.inject_env(client, %{"CLAUDE_CONFIG_DIR" => config_dir}) do
          :ok -> :ok
          {:error, reason} -> {:error, {:config_isolation_failed, reason}}
        end
      end
    end
  end

  # The shared credential source, content-based (an empty source falls
  # through): the DOTTED host file → the legacy dotless file → (darwin) the
  # macOS Keychain. The blob never lands on host disk — it rides the
  # exec-based transport straight into the sandbox. None ⇒ :no_credentials
  # (the existing clean step error). Accepted residuals: an in-VM token
  # refresh can rotate the refresh token while the host Keychain copy goes
  # stale (same class as the existing Linux file sync), and the first
  # Keychain extraction may pop a one-time macOS approval prompt (attended
  # runs OK; unattended runs need pre-authorization).
  defp resolve_host_credentials do
    host_claude = host_claude_dir()

    read_first_regular([
      Path.join(host_claude, @dotted_auth_file),
      Path.join(host_claude, @auth_file)
    ]) || keychain_credentials() || {:error, :no_credentials}
  end

  defp read_first_regular(paths) do
    Enum.find_value(paths, fn path ->
      with true <- File.regular?(path),
           {:ok, content} when content != "" <- File.read(path) do
        {:ok, content}
      else
        _ -> nil
      end
    end)
  end

  defp keychain_credentials do
    case keychain_reader().() do
      {:ok, content} when is_binary(content) and content != "" -> {:ok, content}
      _miss_or_error -> nil
    end
  end

  # Injectable Keychain seam (the `:sbx_finder` app-env idiom) so tests can
  # arm a deterministic hit/miss without shelling out; the default carries
  # the REAL invocation. Anything but a 0-arity fun falls back to the real
  # reader — bad config must not crash a session init.
  defp keychain_reader do
    case Application.get_env(:jido_claw, :claude_keychain_reader) do
      fun when is_function(fun, 0) -> fun
      _absent_or_invalid -> &read_macos_keychain/0
    end
  end

  # darwin only: claude on macOS stores the OAuth blob as the
  # "Claude Code-credentials" generic password, not a file. Scrubbed env;
  # stderr NOT merged (the stdout IS the credential — never mix, never log).
  defp read_macos_keychain do
    with {:unix, :darwin} <- :os.type(),
         security when is_binary(security) <- System.find_executable("security"),
         {output, 0} <-
           System.cmd(security, ["find-generic-password", "-s", @keychain_service, "-w"],
             env: Env.scrubbed_cmd_env()
           ) do
      {:ok, String.trim(output)}
    else
      _ -> :error
    end
  end

  defp sync_full_whitelist(client, forge_home) do
    host_claude = host_claude_dir()
    auth_path = Path.join(host_claude, @auth_file)

    cond do
      not File.dir?(host_claude) ->
        {:error, :no_credentials}

      not File.regular?(auth_path) ->
        {:error, :no_credentials}

      true ->
        for dir <- ["#{forge_home}/session", "#{forge_home}/templates", "#{forge_home}/.claude"] do
          Sandbox.exec(client, "mkdir -p #{dir}", [])
        end

        Enum.each(@syncable_entries, fn entry ->
          source = Path.join(host_claude, entry)
          dest = "#{forge_home}/.claude/#{entry}"

          cond do
            File.regular?(source) ->
              FileSync.sync_file(client, source, dest, @auth_file, "ClaudeCode")

            File.dir?(source) ->
              sync_dir(client, source, dest)

            true ->
              :skip
          end
        end)

        :ok
    end
  end

  defp sync_dir(client, source_dir, dest_dir) do
    Sandbox.exec(client, "mkdir -p #{dest_dir}", [])

    case File.ls(source_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          source = Path.join(source_dir, entry)
          dest = "#{dest_dir}/#{entry}"

          cond do
            File.regular?(source) ->
              FileSync.sync_file(client, source, dest, @auth_file, "ClaudeCode")

            File.dir?(source) ->
              sync_dir(client, source, dest)

            true ->
              :skip
          end
        end)

      {:error, reason} ->
        Logger.debug("[ClaudeCode] Skipping dir #{source_dir}: #{reason}")
    end
  end

  defp default_forge_home,
    do: Application.get_env(:jido_claw, :forge_home, "/var/local/forge")

  defp host_claude_dir,
    do: Path.expand(Application.get_env(:jido_claw, :claude_home_dir, "~/.claude"))
end
