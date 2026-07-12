defmodule JidoClaw.Forge.Runners.Codex do
  @moduledoc """
  Sibling runner to `JidoClaw.Forge.Runners.ClaudeCode` for the
  OpenAI Codex CLI (`codex exec`).

  ## CLI surface differences

  Codex's flag surface differs from Claude Code's:

    * No `--mcp-config FILE`. The host's `$CODEX_HOME/config.toml` is
      synced verbatim into the per-run `$CODEX_HOME` so operator
      provider/profile/proxy settings are preserved. The per-run
      MCP server (name from `runner_config.mcp_server_name`, default
      `"consolidator"`) is injected on the `codex exec` argv as
      an inline-table override — `-c 'mcp_servers.<name> =
      {url="...", default_tools_approval_mode="approve"}'` — which
      replaces the whole server entry rather than merging into one.
      That avoids TOML 1.0's duplicate-table error when the host
      already declares `[mcp_servers.<name>]`, and also avoids Codex's
      reject-mixed-shape check when a host entry uses a stdio-style
      `command = "..."` (a sub-key override would leave that sibling
      in place alongside our `url`). The override stays on the argv,
      so the per-run endpoint never lands on disk; the approve mode is
      load-bearing (see `mcp_override/1`).
    * No `--max-turns`. We rely on `timeout_ms` instead.
    * Auth lives at `$CODEX_HOME/auth.json` (mode 600 on the host).
    * Approvals: codex ≥0.142 defaults `approval_policy` to
      `on-request` (headless `exec` auto-cancels prompts). With the
      default `access: :full` we pass
      `--dangerously-bypass-approvals-and-sandbox` because Forge
      already provides isolation; `access: :read_only` (the
      vendor-executor posture, PR-2) replaces it with `-s read-only` —
      the CLI's own sandbox holds the read floor, verified live to
      leave the loopback MCP connection open.

  ## Per-run isolation

  Both `forge_home` and `codex_home` are read from `runner_config`.
  The consolidator passes per-run paths so concurrent runs do not
  trample each other's `$CODEX_HOME/config.toml` or session files.

  ## Executor knobs (PR-2 — defaults preserve the consolidator byte-for-byte)

    * `config_sync: :full (default) | :auth_only` — `:auth_only` syncs
      `auth.json` alone: the host `config.toml` would carry the operator's
      host MCP servers into a session meant to see only the deposit
      endpoint, past the read-only intent. Under `:auth_only` a failed
      `CODEX_HOME` env inject fails the init CLOSED (the env taking effect
      is the only thing keeping the host `~/.codex` out of the session);
      `:full` stays best-effort.
    * `access: :full (default) | :read_only` — see above.
    * `cwd` — the `-C` working directory (default `forge_home`); the
      executor points it at the run's real `project_dir` for
      `workspace: :repo`.
    * `mcp_server_name` — the injected server's TOML key (default
      `"consolidator"`; the executor passes `"jido_deposit"`).
    * `resume: :off (default) | :armed` — native CLI session resume
      (docs/system/forge-session-resume.md). `:off` is byte-identical to
      today: `--ephemeral` fresh session per iteration (PR-3 pin; the
      executor never arms). `:armed` drops `--ephemeral` so the session
      persists, captures the backend-issued `thread.started` `thread_id`
      as a PROVISIONAL anchor that only a real `turn.completed` terminal
      in the same attempt promotes (CH2-6 — a backend id is not proof the
      session persisted usefully, and a terminal-less exit-0 stream stays
      provisional), and continues a trusted anchor via the `resume`
      subcommand. All
      exec-level opts precede `resume` (codex 0.144.1 rejects `-C`/`-s`
      after it — verified live) and the guidance positional rides behind
      a `--` separator so dash-leading guidance parses as data.
  """

  @behaviour JidoClaw.Forge.Runner
  alias JidoClaw.Forge.{RecoveredSpec, ResumeState, Runner, Sandbox}
  alias JidoClaw.Forge.Runners.{FileSync, ResumePolicy}
  alias JidoClaw.Security.Redaction.PromptRedaction

  # Whitelist trimmed: rules/ is inert under --ignore-rules; AGENTS.md is
  # read from `-C cwd`, not $CODEX_HOME. Auth + config are the only files
  # that actually move the needle.
  @syncable_entries ~w(auth.json config.toml)
  @auth_file "auth.json"

  # Shared between `init/2` and `materialize_config/1` so the persisted
  # materialized posture can never drift from what a fresh init applies.
  @default_model "gpt-5-codex"
  @default_max_turns 60
  @default_timeout_ms 600_000
  @default_mcp_server_name "consolidator"

  @impl Runner
  def init(client, config) do
    forge_home = Map.get(config, :forge_home, default_forge_home())
    codex_home = Map.get(config, :codex_home, "#{forge_home}/.codex")
    mcp_url = Map.get(config, :mcp_server_url)
    prompt = Map.get(config, :prompt, "")
    config_sync = Map.get(config, :config_sync, :full)
    cwd = Map.get(config, :cwd, forge_home)

    with :ok <- sync_host_codex_config(client, codex_home, forge_home, config_sync),
         :ok <- inject_codex_home(client, codex_home, config_sync) do
      if prompt != "" do
        Sandbox.write_file(
          client,
          "#{forge_home}/session/context.md",
          PromptRedaction.redact(prompt)
        )
      end

      {:ok,
       %{
         model: Map.get(config, :model, @default_model),
         prompt: prompt,
         iteration: 0,
         # `max_turns` carried for state symmetry with ClaudeCode; Codex has
         # no flag analogue, so the runner does not pass it to the CLI.
         max_turns: Map.get(config, :max_turns, @default_max_turns),
         timeout_ms: Map.get(config, :timeout_ms, @default_timeout_ms),
         codex_home: codex_home,
         forge_home: forge_home,
         mcp_server_url: mcp_url,
         mcp_server_name: Map.get(config, :mcp_server_name, @default_mcp_server_name),
         access: Map.get(config, :access, :full),
         cwd: cwd,
         session_name: Map.get(config, :session_name),
         resume: init_resume(Map.get(config, :resume, :off), cwd)
       }}
    end
  end

  # Codex's workdir is config-declared (`-C cwd`), so arming needs no pwd
  # capture — the declared cwd IS the anchor workdir and the per-turn
  # cwd-gate input. Default-off carries no resume machinery (PR-3 pin).
  defp init_resume(:armed, cwd), do: ResumeState.new(workdir: cwd)
  defp init_resume(_off, _cwd), do: nil

  # The complete static config, every init/2 default written explicitly and
  # stamped for `RecoveredSpec.runner_config/1` — a recovered session
  # re-inits with exactly this posture, never a re-applied default.
  # Attempt-scoped values (`mcp_server_url` — the tokenized per-attempt
  # endpoint) are deliberately absent: they ride `run_iteration` opts, never
  # the persisted row. Nil optionals are omitted rather than persisted as
  # null.
  @impl Runner
  def materialize_config(config) do
    forge_home = Map.get(config, :forge_home, default_forge_home())

    materialized = %{
      config_codec: RecoveredSpec.codec_stamp(:codex),
      prompt: Map.get(config, :prompt, ""),
      model: Map.get(config, :model, @default_model),
      session_name: Map.get(config, :session_name),
      max_turns: Map.get(config, :max_turns, @default_max_turns),
      timeout_ms: Map.get(config, :timeout_ms, @default_timeout_ms),
      forge_home: forge_home,
      codex_home: Map.get(config, :codex_home, "#{forge_home}/.codex"),
      mcp_server_name: Map.get(config, :mcp_server_name, @default_mcp_server_name),
      config_sync: Map.get(config, :config_sync, :full),
      access: Map.get(config, :access, :full),
      cwd: Map.get(config, :cwd, forge_home),
      resume: Map.get(config, :resume, :off)
    }

    Map.reject(materialized, fn {_key, value} -> is_nil(value) end)
  end

  # Inject CODEX_HOME so codex finds the per-run config.toml + auth.json.
  # Under :auth_only (the vendor-executor posture) the env taking effect is
  # the ONLY thing keeping the operator's real ~/.codex (host config.toml,
  # host MCP servers) out of the session — a refused inject fails the init
  # CLOSED. :full preserves the consolidator's existing best-effort behavior:
  # static config content is a host copy, though mutable session/cache state
  # would land in the host dir.
  defp inject_codex_home(client, codex_home, :auth_only) do
    case Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_isolation_failed, reason}}
    end
  end

  defp inject_codex_home(client, codex_home, _full) do
    _ = Sandbox.inject_env(client, %{"CODEX_HOME" => codex_home})
    :ok
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

  # Attempt-scoped endpoint capability: a driver may mint a tokenized
  # per-attempt MCP URL and pass it per turn — it rides `run_iteration`
  # opts only, never the persisted config (the codec whitelist drops it),
  # and absent opts leave the init-time value standing (byte-identical
  # argv — the PR-3 pin holds).
  defp attempt_state(state, opts) do
    case Keyword.get(opts, :mcp_server_url) do
      url when is_binary(url) and url != "" -> Map.put(state, :mcp_server_url, url)
      _absent -> state
    end
  end

  # Default-off: today's `--ephemeral` fresh session, byte-identical — no
  # resume bookkeeping, no metadata.state (PR-3 pin).
  defp run_default_iteration(client, state, opts) do
    args = build_args(state, Keyword.get(opts, :prompt, state.prompt), :default_off)

    case dispatch(client, state, args, opts) do
      {output, 0} -> parse_output(output)
      {_output, :timeout} -> {:ok, Runner.error("harness_timeout", "")}
      {output, 127} -> {:ok, Runner.error("runner_unavailable", output)}
      {output, _code} -> {:ok, Runner.error("codex cli failed", output)}
    end
  end

  # Armed: only a trusted anchor in the declared cwd continues; everything
  # else (unanchored, provisional, poisoned, cwd mismatch) runs fresh-armed.
  # Every path below returns `metadata.state` — error and timeout terminals
  # included — the harness merges runner state only via metadata.
  defp run_armed_iteration(client, state, rs, opts) do
    case ResumeState.resolve_mode(rs, state.cwd) do
      :continuation ->
        run_continuation(client, state, ResumeState.continuing(rs), opts)

      {:fresh_armed, _reason} ->
        run_fresh_armed(client, state, rs, opts)
    end
  end

  # Fresh-armed: the anchor is BACKEND-issued — nothing exists pre-spawn, so
  # the only argv change is dropping `--ephemeral` (the session must
  # persist); `thread.started` is captured from the stream and the anchor
  # stays PROVISIONAL unless this same attempt sees a real terminal (CH2-6;
  # PORT sign-off Q2). The prompt source is `opts[:prompt]`-else-
  # `state.prompt` — the caller's `:guidance` opt is structurally IGNORED
  # here (it means "continuation guidance"), so a fresh conversation always
  # carries the full task. An inflight parked answer reverts to :pending
  # first (this turn provably never places it on an argv; it redelivers on
  # the next continuation).
  defp run_fresh_armed(client, state, rs, opts) do
    rs = ResumeState.guidance_undelivered(rs)
    args = build_args(state, Keyword.get(opts, :prompt, state.prompt), :fresh_armed)

    case dispatch(client, state, args, opts) do
      {output, 0} ->
        {result, thread_id, terminal} = do_parse_output(output)
        final_rs = capture_anchor(rs, thread_id, state.cwd, terminal)
        {:ok, ResumePolicy.attach_runner_state(result, state, final_rs)}

      {_output, :timeout} ->
        armed_failure({:known, "harness_timeout"}, "", state, rs, :fresh_armed, opts)

      {output, 127} ->
        armed_failure({:known, "runner_unavailable"}, output, state, rs, :fresh_armed, opts)

      {output, _code} ->
        armed_failure({:classify, "codex cli failed"}, output, state, rs, :fresh_armed, opts)
    end
  end

  # Continuation: exec-level opts FIRST, then the `resume` subcommand —
  # codex 0.144.1 rejects `-C`/`-s` after `resume` (verified live). The
  # guidance is GUIDANCE-ONLY — parked inflight text first, then the
  # caller's `:guidance` opt, then the shared nudge
  # (`ResumePolicy.take_continuation_guidance/2`); `opts[:prompt]` is never
  # read (the original task never rides the argv again — CM2-3) — and rides
  # behind `--` so dash-leading text parses as the prompt positional.
  # Never `--ephemeral`, never `--last`.
  defp run_continuation(client, state, rs, opts) do
    {guidance, rs} = ResumePolicy.take_continuation_guidance(rs, opts)
    args = build_args(state, guidance, {:continuation, rs.session_id})

    case dispatch(client, state, args, opts) do
      {output, 0} ->
        {result, thread_id, _terminal} = do_parse_output(output)
        final_rs = verify_continuation_thread(rs, thread_id, opts)
        {:ok, ResumePolicy.attach_runner_state(result, state, final_rs)}

      {_output, :timeout} ->
        armed_failure({:known, "harness_timeout"}, "", state, rs, :continuation, opts)

      {output, 127} ->
        armed_failure({:known, "runner_unavailable"}, output, state, rs, :continuation, opts)

      {output, _code} ->
        armed_failure({:classify, "codex cli failed"}, output, state, rs, :continuation, opts)
    end
  end

  # No `thread.started` in the stream → nothing to capture, state unchanged.
  defp capture_anchor(rs, nil, _cwd, _terminal), do: rs

  # A poisoned anchor rearms only on a DIFFERENT backend id
  # (`rearm_new_anchor/4` refuses reuse and resets the retry latch).
  defp capture_anchor(%ResumeState{status: :poisoned} = rs, thread_id, cwd, terminal) do
    case ResumeState.rearm_new_anchor(rs, thread_id, cwd, :backend) do
      {:ok, provisional} -> maybe_trust(provisional, terminal)
      {:error, _reuse_or_invalid} -> rs
    end
  end

  defp capture_anchor(rs, thread_id, cwd, terminal) do
    cleared = if rs.status == :unanchored, do: rs, else: ResumeState.clear(rs, :new)

    case ResumeState.capture_backend(cleared, thread_id, cwd) do
      {:ok, provisional} -> maybe_trust(provisional, terminal)
      {:error, _invalid} -> rs
    end
  end

  # CH2-6: a backend id becomes trusted only on a REAL `turn.completed`
  # terminal in the same attempt — the stream's parsed terminal accumulator,
  # not the result posture: the exit-0-no-terminal fallthrough also produces
  # `Runner.done` (deliberate, pinned), but a truncated stream is not proof
  # the session persisted usefully, so it stays provisional (next turn
  # resolves fresh-armed).
  defp maybe_trust(rs, {:done, _usage}), do: ResumeState.trust(rs)
  defp maybe_trust(rs, _no_clean_terminal), do: rs

  # A resumed thread announces its own id — a different one means the CLI
  # silently started elsewhere; the anchor no longer names the live
  # conversation, so drop it loudly. A missing echo keeps the anchor.
  defp verify_continuation_thread(rs, nil, _opts), do: rs

  defp verify_continuation_thread(%ResumeState{session_id: id} = rs, id, _opts), do: rs

  defp verify_continuation_thread(rs, other, opts) do
    ResumePolicy.emit_anchor_mismatch(
      :codex,
      :continuation,
      rs.session_id,
      "continuation echoed thread #{inspect(other)} instead of anchor #{rs.session_id} — anchor dropped",
      opts
    )

    ResumeState.clear(rs, :new)
  end

  # Armed terminal failures classify + poison + emit through the shared
  # vendor policy (`ResumePolicy.armed_failure/7`; the recognized rejection
  # "no rollout found …" verified live on 0.144.1) — one module so the two
  # runners cannot drift.
  defp armed_failure(labeling, output, state, rs, mode, opts),
    do: ResumePolicy.armed_failure(:codex, labeling, output, state, rs, mode, opts)

  # Inject the per-run MCP server via Codex's `-c dotted.key=value`
  # override so we never write the table to disk. The value is a TOML
  # inline table — `mcp_servers.<name> = {url="<url>"}` replaces the
  # whole server entry, not just a sub-key. This is important when a
  # host config the operator has synced declares `[mcp_servers.<name>]`
  # with a stdio shape (`command = "..."`); writing only `…url=` would
  # leave the sibling `command` key in place and Codex rejects mixed
  # url/command tables. Inline-table replacement avoids that collision
  # entirely.
  #
  # Exec-level opts always precede the mode tail: `--ephemeral` exists only
  # default-off, and a continuation appends `resume <id> -- <guidance>`
  # LAST (codex 0.144.1 rejects exec-level opts after the subcommand).
  defp build_args(state, prompt, mode) do
    redacted_prompt = PromptRedaction.redact(prompt)

    exec_opts =
      mcp_override(state) ++
        ["-m", state.model] ++
        access_args(state) ++
        ["--json"] ++
        ephemeral_flag(mode) ++
        ["--skip-git-repo-check", "--ignore-rules", "-C", state.cwd]

    ["exec" | exec_opts ++ positional_tail(mode, redacted_prompt)]
  end

  defp ephemeral_flag(:default_off), do: ["--ephemeral"]
  defp ephemeral_flag(_armed), do: []

  defp positional_tail({:continuation, anchor_id}, guidance),
    do: ["resume", anchor_id, "--", guidance]

  defp positional_tail(_fresh, prompt), do: [prompt]

  defp dispatch(client, state, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout, state.timeout_ms)
    base_run_opts = [timeout: timeout_ms] ++ teardown_opts(opts)

    run_opts =
      if state.session_name,
        do: [{:name, state.session_name} | base_run_opts],
        else: base_run_opts

    Sandbox.run(client, "codex", args, run_opts)
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

  # `default_tools_approval_mode="approve"` is load-bearing (PR-2 live smoke):
  # codex ≥0.142 gates MCP tool calls behind a per-server approval mode whose
  # default PROMPTS — headless `exec` auto-cancels the prompt ("user cancelled
  # MCP tool call") and the call never leaves the client. Auto-approving is
  # correct here by construction: the injected server is the ENGINE'S OWN
  # scoped endpoint (consolidator / deposit lane) — the engine owns both ends
  # of the channel, so there is no operator to prompt.
  defp mcp_override(%{mcp_server_url: url} = state) when is_binary(url) and url != "",
    do: [
      "-c",
      ~s(mcp_servers.#{state.mcp_server_name}=) <>
        ~s({url="#{url}", default_tools_approval_mode="approve"})
    ]

  defp mcp_override(_), do: []

  # `:read_only` is the executor posture (PR-2): the CLI's own sandbox holds
  # the read floor, never the bypass flag.
  defp access_args(%{access: :read_only}), do: ["-s", "read-only"]
  defp access_args(_state), do: ["--dangerously-bypass-approvals-and-sandbox"]

  @impl Runner
  def apply_input(client, input, state) do
    Sandbox.write_file(
      client,
      "#{state.forge_home}/session/response.json",
      Jason.encode!(%{response: input})
    )

    :ok
  end

  # The shared checkpoint codec (ResumePolicy): {iteration, sanitized
  # resume state}; static config recovers through the materialized-config
  # codec instead. The config-declared cwd stays the cwd-gate input a
  # restored foreign-workdir anchor fails next turn.
  @impl Runner
  def serialize_state(state), do: ResumePolicy.serialize_state(state)

  @impl Runner
  def restore_state(state, snapshot), do: ResumePolicy.restore_state(state, snapshot)

  defp sync_host_codex_config(client, codex_home, forge_home, config_sync) do
    host_codex = host_codex_dir()
    auth_path = Path.join(host_codex, @auth_file)

    cond do
      not File.dir?(host_codex) ->
        {:error, :no_credentials}

      not File.regular?(auth_path) ->
        {:error, :no_credentials}

      true ->
        for dir <- ["#{forge_home}/session", "#{forge_home}/templates", codex_home] do
          Sandbox.exec(client, "mkdir -p #{dir}", [])
        end

        Enum.each(syncable_entries(config_sync), fn entry ->
          source = Path.join(host_codex, entry)
          dest = "#{codex_home}/#{entry}"

          if File.regular?(source),
            do: FileSync.sync_file(client, source, dest, @auth_file, "Codex")
        end)

        :ok
    end
  end

  # `:auth_only` (the executor posture): the host config.toml would carry the
  # operator's host MCP servers into a session meant to see only the deposit
  # endpoint — auth alone crosses.
  defp syncable_entries(:auth_only), do: [@auth_file]
  defp syncable_entries(_full), do: @syncable_entries

  defp parse_output(output) do
    {result, _thread_id, _terminal} = do_parse_output(output)
    {:ok, result}
  end

  # The armed paths also need the backend-issued thread id
  # (`{"type":"thread.started","thread_id":"…"}` — key shape verified live
  # on codex 0.144.1); the first one in the stream wins. It rides
  # `metadata.thread_id` when present, and the event itself stays out of
  # `tool_events` (system noise). The raw `terminal` accumulator returns
  # alongside so the armed fresh path can gate anchor promotion on a REAL
  # `turn.completed` (F8/CH2-6) — the nil-fallthrough result posture below
  # stays `Runner.done` (deliberate, pinned) and cannot carry that signal.
  defp do_parse_output(output) do
    lines = String.split(output, "\n", trim: true)

    {events, terminal, turns, thread_id} =
      Enum.reduce(lines, {[], nil, 0, nil}, fn line,
                                               {events_acc, terminal_acc, turns_acc, tid_acc} ->
        if String.starts_with?(line, "{") do
          case Jason.decode(line) do
            {:ok, %{"type" => "thread.started"} = ev} ->
              tid = tid_acc || thread_id_of(ev)
              {events_acc, terminal_acc, turns_acc, tid}

            {:ok, decoded} ->
              {new_events, new_terminal, new_turns} =
                handle_event(decoded, events_acc, terminal_acc, turns_acc)

              {new_events, new_terminal, new_turns, tid_acc}

            _ ->
              {events_acc, terminal_acc, turns_acc, tid_acc}
          end
        else
          {events_acc, terminal_acc, turns_acc, tid_acc}
        end
      end)

    base_metadata = %{tool_events: Enum.reverse(events), turns: turns}

    metadata =
      if thread_id, do: Map.put(base_metadata, :thread_id, thread_id), else: base_metadata

    result =
      case terminal do
        {:done, usage} ->
          base = Runner.done(output)
          meta = if usage, do: Map.put(metadata, :usage, usage), else: metadata
          %{base | metadata: Map.merge(base.metadata, meta)}

        {:error, message} ->
          base = Runner.error(message, output)
          %{base | metadata: Map.merge(base.metadata, metadata)}

        nil ->
          # Stream ended without a terminal turn.completed/turn.failed/error
          # line (e.g., interrupted before a turn finished but exit-0). Treat
          # as completed — same posture as ClaudeCode's missing-result branch.
          base = Runner.done(output)
          %{base | metadata: Map.merge(base.metadata, metadata)}
      end

    {result, thread_id, terminal}
  end

  defp thread_id_of(%{"thread_id" => tid}) when is_binary(tid) and tid != "", do: tid
  defp thread_id_of(_), do: nil

  # ---- Codex JSONL → ClaudeCode-shape mapping ----

  # turn.started → drop (system noise; thread.started is consumed upstream
  # in do_parse_output)
  defp handle_event(%{"type" => "turn.started"}, events, terminal, turns),
    do: {events, terminal, turns}

  # turn.completed → terminal :done; usage stashed into metadata.usage; turns += 1
  defp handle_event(%{"type" => "turn.completed"} = ev, events, _terminal, turns) do
    {events, {:done, Map.get(ev, "usage")}, turns + 1}
  end

  # turn.failed → terminal :error with error.message
  defp handle_event(%{"type" => "turn.failed"} = ev, events, _terminal, turns) do
    msg = get_in(ev, ["error", "message"]) || "turn_failed"
    {events, {:error, msg}, turns}
  end

  # top-level error → terminal :error
  defp handle_event(%{"type" => "error"} = ev, events, _terminal, turns) do
    msg = Map.get(ev, "message") || "error"
    {events, {:error, msg}, turns}
  end

  # item.started — currently only mcp_tool_call carries forward.
  defp handle_event(
         %{"type" => "item.started", "item" => %{"type" => "mcp_tool_call"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{
      "type" => "tool_use",
      "name" => Map.get(item, "tool"),
      "server" => Map.get(item, "server"),
      "input" => Map.get(item, "arguments"),
      "id" => Map.get(item, "id")
    }

    {[decoded | events], terminal, turns}
  end

  defp handle_event(%{"type" => "item.started"}, events, terminal, turns),
    do: {events, terminal, turns}

  # item.completed — mcp_tool_call → tool_result; agent_message → assistant;
  # reasoning → reasoning. Other subtypes are dropped.
  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "mcp_tool_call"} = item},
         events,
         terminal,
         turns
       ) do
    content = get_in(item, ["result", "content"]) || get_in(item, ["error", "message"])
    is_error = Map.get(item, "status") == "failed"

    decoded = %{
      "type" => "tool_result",
      "tool_use_id" => Map.get(item, "id"),
      "content" => content,
      "is_error" => is_error
    }

    {[decoded | events], terminal, turns}
  end

  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "agent_message"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{"type" => "assistant", "text" => Map.get(item, "text")}
    {[decoded | events], terminal, turns}
  end

  defp handle_event(
         %{"type" => "item.completed", "item" => %{"type" => "reasoning"} = item},
         events,
         terminal,
         turns
       ) do
    decoded = %{"type" => "reasoning", "text" => Map.get(item, "text")}
    {[decoded | events], terminal, turns}
  end

  defp handle_event(%{"type" => "item.completed"}, events, terminal, turns),
    do: {events, terminal, turns}

  defp handle_event(%{"type" => "item.updated"}, events, terminal, turns),
    do: {events, terminal, turns}

  defp handle_event(_, events, terminal, turns), do: {events, terminal, turns}

  defp default_forge_home,
    do: Application.get_env(:jido_claw, :forge_home, "/var/local/forge")

  defp host_codex_dir,
    do: Path.expand(Application.get_env(:jido_claw, :codex_home_dir, "~/.codex"))
end
