# Resolve remaining Credo nesting findings

## Context

`.credo.exs` is now at `max_nesting: 3` and `max_complexity: 11`. Eleven `Refactor.Nesting` findings remain. On reflection, all eleven have clean helper-extraction refactors — including the three I initially proposed suppressing. Inline `# credo:disable-for-next-line` is also fragile here: Credo reports nesting on the deep expression line, not the function head, so a directive above the `defp` would not match and we would need either per-expression directives or `disable-for-lines:N` blocks, both of which are noisier than a small refactor. Refactor all eleven.

End state: `mix credo --strict` returns 0 findings; behavior unchanged.

## Approach

### 1. `lib/jido_claw/workflows/plan_workflow.ex:143` — `detect_cycle/3`

Extract the inner `Enum.reduce_while` into `detect_cycle_in_deps/3` and flatten the outer `if/else if/else` into a `cond`.

```elixir
defp detect_cycle(name, step_map, path) do
  cond do
    name in path ->
      cycle = [name | path] |> Enum.reverse() |> Enum.join(" -> ")
      {:error, "Cyclic dependency detected: #{cycle}"}

    step = Map.get(step_map, name) ->
      detect_cycle_in_deps(step.depends_on, step_map, [name | path])

    true ->
      :ok
  end
end

defp detect_cycle_in_deps(deps, step_map, path) do
  Enum.reduce_while(deps, :ok, fn dep, :ok ->
    case detect_cycle(dep, step_map, path) do
      :ok -> {:cont, :ok}
      {:error, _} = err -> {:halt, err}
    end
  end)
end
```

### 2. `lib/jido_claw/workflows/plan_workflow.ex:219` — `step_depth/4`

Replace the `Enum.map |> then(fn depths -> if depths == [], do: -1, else: Enum.max(depths) end)` chain with a multi-clause `max_dep_depth/4` helper, and flatten the outer `if/case` into a `cond`.

```elixir
defp step_depth(step, step_map, known_depths, visiting) do
  cond do
    MapSet.member?(visiting, step.name) ->
      0

    Map.has_key?(known_depths, step.name) ->
      Map.fetch!(known_depths, step.name)

    true ->
      visiting = MapSet.put(visiting, step.name)
      max_dep_depth(step.depends_on, step_map, known_depths, visiting) + 1
  end
end

defp max_dep_depth([], _step_map, _known_depths, _visiting), do: -1

defp max_dep_depth(deps, step_map, known_depths, visiting) do
  deps
  |> Enum.map(fn dep ->
    dep_step = Map.fetch!(step_map, dep)
    step_depth(dep_step, step_map, known_depths, visiting)
  end)
  |> Enum.max()
end
```

### 3. `lib/jido_claw/workflows/context_builder.ex:99` — `format_artifact_context/3`

The depth is `Enum.flat_map → if → anonymous fn`. `Enum.map_join` alone would not clear it. Extract `format_artifact_section/3` as the primary fix:

```elixir
def format_artifact_context(step, all_steps, prior_results) do
  consumes = Map.get(step, :consumes) || []

  if consumes == [] do
    ""
  else
    sections =
      Enum.flat_map(consumes, &format_artifact_section(&1, all_steps, prior_results))

    if sections == [] do
      ""
    else
      "## Artifact Context\n\n#{Enum.join(sections, "\n\n")}"
    end
  end
end

defp format_artifact_section(producer_name, all_steps, prior_results) do
  producer_step = Enum.find(all_steps, fn s -> s.name == producer_name end)
  producer_result = Enum.find(prior_results, fn r -> r.name == producer_name end)

  static = if producer_step, do: Map.get(producer_step, :produces) || %{}, else: %{}
  dynamic = if producer_result, do: Map.get(producer_result, :artifacts) || %{}, else: %{}
  merged = Map.merge(normalize_produces(static), dynamic)

  if map_size(merged) > 0 do
    lines = Enum.map_join(merged, "\n", fn {k, v} -> "- **#{k}**: #{v}" end)
    ["### Artifacts from #{producer_name}\n#{lines}"]
  else
    []
  end
end
```

### 4. `lib/jido_claw/memory/hybrid_search_sql.ex:813` — `load_facts/3`

Chain is `case ranked → Enum.flat_map → case Map.fetch → if attach?`. Extract `maybe_attach_shadows/3`:

```elixir
defp maybe_attach_shadows(fact, false, _shadows), do: fact
defp maybe_attach_shadows(fact, true, shadows), do: attach_shadows(fact, shadows)
```

Call site:

```elixir
Enum.flat_map(ranked, fn {id, score} ->
  case Map.fetch(loaded, id) do
    {:ok, fact} ->
      shadows = Map.get(shadows_by_id, id, [])
      [%{fact: maybe_attach_shadows(fact, attach?, shadows), combined_score: score}]

    :error ->
      []
  end
end)
```

### 5. `lib/jido_claw/forge/manager.ex:108` — `handle_call({:start_session, …}, _, _)`

Deepest chain is `cond → case Registry.lookup → if cluster_session_exists? → case DynamicSupervisor.start_child`. Extract `try_start_session/4`:

```elixir
true ->
  case Registry.lookup(@registry, session_id) do
    [{_pid, _}] -> {:reply, {:error, :already_exists}, state}
    [] -> try_start_session(session_id, spec, runner_type, state)
  end
```

```elixir
defp try_start_session(session_id, spec, runner_type, state) do
  if cluster_session_exists?(session_id) do
    {:reply, {:error, :already_exists}, state}
  else
    child_spec = {JidoClaw.Forge.Harness, {session_id, spec, []}}

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, pid} ->
        Process.monitor(pid)
        handle = %{session_id: session_id, pid: pid}

        new_state = %{
          state
          | sessions: MapSet.put(state.sessions, session_id),
            session_runners: Map.put(state.session_runners, session_id, runner_type),
            runner_counts: Map.update(state.runner_counts, runner_type, 1, &(&1 + 1))
        }

        ForgePubSub.broadcast_session_event({:session_started, session_id})
        {:reply, {:ok, handle}, new_state}

      {:error, :already_claimed} ->
        {:reply, {:error, :already_exists}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
```

### 6. `lib/jido_claw/platform/cron/scheduler.ex:24` — `load_persistent_jobs/2`

Chain is `case for_tenant → Enum.reduce → case build_persistent_opts → case schedule`. Preserve the two distinct failure log messages by tagging the failure variant:

```elixir
defp try_schedule_job(tenant_id, job) do
  case build_persistent_opts(job) do
    {:ok, opts} ->
      case schedule(tenant_id, opts) do
        {:ok, _, _} -> :ok
        {:error, reason} -> {:error, :schedule, reason}
      end

    {:error, reason} ->
      {:error, :build_opts, reason}
  end
end
```

Call site:

```elixir
{:ok, jobs} ->
  count =
    Enum.reduce(jobs, 0, fn job, acc ->
      case try_schedule_job(tenant_id, job) do
        :ok ->
          acc + 1

        {:error, :schedule, reason} ->
          Logger.warning("[Cron] Failed to schedule job #{job.job_id}: #{inspect(reason)}")
          acc

        {:error, :build_opts, reason} ->
          Logger.warning("[Cron] Skipping invalid persisted job #{job.job_id}: #{inspect(reason)}")
          acc
      end
    end)

  {:ok, count}
```

### 7. `lib/jido_claw/forge/sandbox/local.ex:148` — `inject_env/2`

Depth comes from `if sandbox → Agent.update fn → update_in fn → Map.new fn`. Extract `stringify_env/2`:

```elixir
defp stringify_env(existing, env) do
  (existing || %{})
  |> Map.merge(env)
  |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
end
```

Call site:

```elixir
if sandbox do
  Agent.update(pid, fn state ->
    update_in(state, [sid, :env], &stringify_env(&1, env))
  end)

  :ok
else
  {:error, :no_sandbox}
end
```

### 8. `lib/jido_claw/tools/edit_file.ex:50` — `run/2`

Chain is `case File.read → cond (occurrences) → true → case Resolver.write`. Extract `write_edit/5`:

```elixir
true ->
  write_edit(path, content, old_str, new_str, opts)
```

```elixir
defp write_edit(path, content, old_str, new_str, opts) do
  new_content = String.replace(content, old_str, new_str, global: false)

  case Resolver.write(path, new_content, opts) do
    :ok ->
      diff = build_diff(old_str, new_str)
      {:ok, %{path: path, diff: diff, status: "edited"}}

    {:error, reason} ->
      {:error, "Failed to write #{path}: #{inspect(reason)}"}
  end
end
```

### 9. `lib/mix/tasks/jidoclaw.migrate.memory.ex:141` — `migrate_memory/3`

Split into read/decode + multi-clause `migrate_entries/3`. The cond's three branches become three function clauses keyed on `{workspace, dry_run?}`.

```elixir
defp migrate_memory(project_dir, workspace, dry_run?) do
  path = Path.join([project_dir, ".jido", "memory.json"])

  case read_entries(path) do
    {:ok, entries} ->
      Mix.shell().info("memory.json: #{length(entries)} entries")
      migrate_entries(entries, workspace, dry_run?)

    :empty ->
      %{inserted: 0, skipped: 0, failed: 0}
  end
end

defp read_entries(path) do
  case File.read(path) do
    {:ok, body} ->
      decode_entries(body)

    {:error, :enoent} ->
      Mix.shell().info("memory.json: not present, skipping")
      :empty

    {:error, reason} ->
      Mix.shell().info("memory.json: read error (#{inspect(reason)})")
      :empty
  end
end

defp decode_entries(body) do
  case Jason.decode(body) do
    {:ok, map} when is_map(map) ->
      entries =
        map
        |> Enum.map(fn {_id, entry} -> entry end)
        |> Enum.reject(&is_nil/1)

      {:ok, entries}

    {:error, reason} ->
      Mix.shell().info("memory.json: invalid JSON (#{inspect(reason)})")
      :empty
  end
end

# Workspace would be created — every entry's import_hash is unique
# within a fresh workspace_id, so all entries would be inserted on a
# real run.
defp migrate_entries(entries, nil, true) do
  %{inserted: length(entries), skipped: 0, failed: 0}
end

# Workspace already exists. Compute each entry's import_hash and
# predict insert vs skip without writing.
defp migrate_entries(entries, workspace, true) do
  Enum.reduce(entries, %{inserted: 0, skipped: 0, failed: 0}, fn entry, acc ->
    attrs = legacy_to_attrs(entry, workspace)

    if already_imported?(attrs[:import_hash]) do
      Map.update!(acc, :skipped, &(&1 + 1))
    else
      Map.update!(acc, :inserted, &(&1 + 1))
    end
  end)
end

defp migrate_entries(entries, workspace, false) do
  Enum.reduce(entries, %{inserted: 0, skipped: 0, failed: 0}, fn entry, acc ->
    attrs = legacy_to_attrs(entry, workspace)
    classify_import(entry, attrs, acc)
  end)
end
```

Each clause is depth ≤ 2.

### 10. `lib/jido_claw/application.ex:67` — `start/2` (Discord block)

Extract `maybe_start_discord/0` with two tagged helpers so the two distinct log lines (Nostrum app failure vs consumer failure) survive the refactor. Helpers normalize all success shapes (`{:ok, _}`, `{:ok, _, _}` from `Supervisor.start_child/2`) to plain `:ok` so the `with` chain stays small.

In `start/2`, replace the entire `unless ... do ... end` block (lines 59–79) with:

```elixir
maybe_start_discord()
```

New helpers:

```elixir
defp maybe_start_discord do
  if Application.get_env(:jido_claw, :skip_discord) do
    :ok
  else
    case System.get_env("DISCORD_BOT_TOKEN") do
      nil ->
        :ok

      token ->
        Application.put_env(:nostrum, :token, token)
        Application.put_env(:nostrum, :gateway_intents, :all)
        Application.put_env(:nostrum, :num_shards, :auto)

        start_nostrum()
    end
  end
end

defp start_nostrum do
  with :ok <- ensure_nostrum_started(),
       :ok <- start_discord_consumer() do
    Logger.warning("[JidoClaw] Discord adapter started")
  end
end

defp ensure_nostrum_started do
  case Application.ensure_all_started(:nostrum) do
    {:ok, _} ->
      :ok

    {:error, reason} ->
      Logger.warning("[JidoClaw] Discord failed to start: #{inspect(reason)}")
      {:error, :nostrum}
  end
end

defp start_discord_consumer do
  case Supervisor.start_child(JidoClaw.Supervisor, JidoClaw.Channel.DiscordConsumer) do
    {:ok, _} ->
      :ok

    {:ok, _, _} ->
      :ok

    {:error, reason} ->
      Logger.warning("[JidoClaw] Discord consumer failed to start: #{inspect(reason)}")
      {:error, :consumer}
  end
end
```

Each helper logs its own failure at the boundary; `start_nostrum/0` doesn't need an `else` clause since the helpers have already logged. Token is fetched once in the `case` head and reused.

`maybe_start_discord/0` body is `if → case`, depth 2. `start_nostrum/0` is the `with`; the sub-helpers are flat `case`s.

### 11. `lib/jido_claw/application.ex:365` — `parse_dotenv/1`

Extract `parse_dotenv_line/1` and `put_env_if_unset/1`.

```elixir
defp parse_dotenv(content) do
  content
  |> String.split("\n")
  |> Enum.each(&parse_dotenv_line/1)
end

defp parse_dotenv_line(line) do
  line = String.trim(line)

  cond do
    line == "" -> :skip
    String.starts_with?(line, "#") -> :skip
    true -> put_env_if_unset(line)
  end
end

defp put_env_if_unset(line) do
  case String.split(line, "=", parts: 2) do
    [key, value] ->
      key = String.trim(key)
      value = value |> String.trim() |> strip_quotes()
      # env vars take precedence over .env entries
      if System.get_env(key) == nil, do: System.put_env(key, value)

    _ ->
      :skip
  end
end
```

## Files modified

- `lib/jido_claw/workflows/plan_workflow.ex` — items 1, 2
- `lib/jido_claw/workflows/context_builder.ex` — item 3
- `lib/jido_claw/memory/hybrid_search_sql.ex` — item 4
- `lib/jido_claw/forge/manager.ex` — item 5
- `lib/jido_claw/platform/cron/scheduler.ex` — item 6
- `lib/jido_claw/forge/sandbox/local.ex` — item 7
- `lib/jido_claw/tools/edit_file.ex` — item 8
- `lib/mix/tasks/jidoclaw.migrate.memory.ex` — item 9
- `lib/jido_claw/application.ex` — items 10, 11

No `.credo.exs` changes — the existing `max_nesting: 3` / `max_complexity: 11` stays.

## Verification

1. `mix credo --strict` — must return 0 findings.
2. `mix compile --warnings-as-errors` — must succeed.
3. `mix format --check-formatted` — must pass.
4. Targeted tests for refactored modules:
   ```
   mix test test/jido_claw/workflows/ \
            test/jido_claw/forge/ \
            test/jido_claw/memory/retrieval_test.exs \
            test/jido_claw/memory/fact_test.exs \
            test/jido_claw/tools/edit_file_test.exs \
            test/jido_claw/cron/ \
            test/jido_claw/application_test.exs
   ```
   `test_helper.exs` excludes `:docker_sandbox` and `:slow` by default, so `test/jido_claw/forge/` is the safe scope.
5. Full suite as a final guard: `mix test`.

`load_facts/3` (item 4) has no direct test file but is exercised through `test/jido_claw/memory/retrieval_test.exs`. `parse_dotenv/1` (item 11) is covered indirectly by `test/jido_claw/application_test.exs`'s `load_dotenv/0` tests. `migrate_memory/3` (item 9) and the Discord startup (item 10) are not covered by unit tests; rely on compile + credo + full-suite boot to catch regressions, and (if possible) one manual `mix jidoclaw.migrate.memory --dry-run` against a project that has a `.jido/memory.json`.
