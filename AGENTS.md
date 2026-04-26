# JidoClaw

## Build & Development Commands

```bash
mix setup                              # deps.get + ash.setup
mix compile                            # compile project
mix compile --warnings-as-errors       # strict compile (CI)
mix format                             # auto-format (enforced)
mix format --check-formatted           # CI format check
mix test                               # full suite (runs ash.setup --quiet first)
mix test test/jido_claw/foo_test.exs   # single test file
mix test test/path_test.exs:42         # single test by line
mix test --failed                      # re-run failures
mix jidoclaw                           # run CLI REPL (setup wizard on first run)
mix jidoclaw --mcp                     # run as MCP server (stdio)
mix escript.build                      # build standalone binary
```

**Database** (PostgreSQL required):

```bash
mix ecto.setup    # create + migrate
mix ecto.reset    # drop + create + migrate
```

**Prerequisites**: Elixir >= 1.17, OTP >= 27, PostgreSQL. Ollama recommended for local dev.

**Tidewave MCP**:

Always use Tidewave's tools for evaluating code, querying the database, etc.

Use `get_docs` to access documentation and the `get_source_location` tool to
find module/function definitions.

### MCP Server Mode

JidoClaw exposes 15 tools over MCP stdio transport for use with Claude Code, Cursor, and other MCP-compatible editors. To add it to a project, create or edit `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "jidoclaw": {
      "command": "mix",
      "args": ["jidoclaw", "--mcp"],
      "cwd": "/absolute/path/to/jido_radclaw"
    }
  }
}
```

The `cwd` must be the absolute path to the JidoClaw project directory (where `mix.exs` lives). The server requires PostgreSQL to be running and `mix ecto.setup` to have been run at least once.

**Exposed tools**: `read_file`, `write_file`, `edit_file`, `list_directory`, `search_code`, `run_command`, `git_status`, `git_diff`, `git_commit`, `project_info`, `run_skill`, `store_solution`, `find_solution`, `network_share`, `network_status`.

**Known limitations** (anubis_mcp 1.1.1 — patched in `lib/jido_claw/core/`):
- Runtime patch overrides `Anubis.Server.Handlers.Tools` to rescue a Peri validation crash caused by jido_mcp's JSON-Schema-shaped tool schemas, and to atomize known string argument keys before dispatching to Jido actions. Remove once `jido_mcp` either emits Peri-compatible schemas or no longer routes those descriptors through Anubis's pre-dispatch Peri validation path.

## Architecture

JidoClaw is an AI agent orchestration platform built on Elixir/OTP and the Jido framework ecosystem. It provides a CLI REPL with ~31 tools, swarm orchestration, sandboxed code execution (Forge), a Phoenix LiveView web dashboard, and multi-provider LLM support.

### Supervision Tree

`JidoClaw.Application` starts children in groups:

- **Core**: Registries, Repo, Vault, Forge engine, PubSub, SignalBus, Telemetry, agent runtime (`JidoClaw.Jido`), Memory, Skills, Shell sessions, Display, AgentTracker
- **Gateway**: `JidoClaw.Web.Endpoint` (Phoenix) - started when mode is `:gateway` or `:both`
- **Cluster**: libcluster + `:pg` - started when `:cluster_enabled` is true
- **MCP**: Jido MCP server over stdio - started when `:serve_mode` is `:mcp` (Gateway and Discord are skipped in this mode)
- **Discord**: Nostrum started dynamically only when `DISCORD_BOT_TOKEN` is set and `:skip_discord` is not true

### Key Patterns

- **Tools**: All tools are `Jido.Action` modules (`use Jido.Action` with `name`, `description`, `schema`) in `lib/jido_claw/tools/`. Add new tools there and register in `lib/jido_claw/agent/agent.ex`.
- **Agent templates**: `lib/jido_claw/agent/workers/` - specialized agents (Coder, Reviewer, Researcher, etc.) using `use Jido.AI.Agent`
- **Signals**: Internal event routing via `Jido.Signal.Bus` with `jido_claw.<subsystem>.<event>` namespace
- **Stateful processes**: GenServer everywhere - sessions, shell manager, memory, skills, display
- **Swarm**: The main agent can spawn sub-agents dynamically; `AgentTracker` monitors per-agent stats
- **Skills**: YAML-based multi-step workflows in `.jido/skills/` with `depends_on` for DAG execution
- **VFS**: Virtual filesystem (`JidoClaw.VFS.Resolver`) routes `github://`, `s3://`, `git://` paths to backends

### Module Namespace Convention

`JidoClaw.<Subsystem>.<Module>` - key subsystems:

| Directory        | Purpose                                           |
| ---------------- | ------------------------------------------------- |
| `agent/`         | Main agent, prompt builder, templates, workers    |
| `cli/`           | REPL, commands, branding, setup, formatter        |
| `forge/`         | Sandboxed execution (runners, sandbox backends)   |
| `tools/`         | All 31+ Jido.Action tool modules                  |
| `platform/`      | Session, Tenant, Channel, Cron, BackgroundProcess |
| `reasoning/`     | Strategy + pipeline stores, classifier, telemetry, certificate templates |
| `security/`      | Encryption vault, secret redaction                |
| `web/`           | Phoenix endpoint, controllers, LiveView           |
| `orchestration/` | Persistent workflow state machine                 |
| `solutions/`     | Solution fingerprinting, trust scoring, semi-formal verification |

### Data Layer

Ash Framework 3.0 + PostgreSQL. Resources in `lib/jido_claw/accounts/` and `lib/jido_claw/folio/`. Test DB uses `Ecto.Adapters.SQL.Sandbox` for parallel isolation.

### Configuration Cascade

1. `config/config.exs` (compile-time, includes LLMDB model catalog)
2. `.jido/config.yaml` (user runtime config: provider, model, strategy)
3. `.env` / env vars (secrets - loaded at app start, env vars take precedence)

### `.jido/` Directory

Project-level config directory. `config.yaml`, `memory.json`, `sessions/` are git-ignored. `agents/`, `skills/`, `strategies/`, and `pipelines/` YAML definitions are committed. Schema details live in the module docs for `JidoClaw.Reasoning.StrategyStore` (user strategies + optional prompt templates) and `JidoClaw.Reasoning.PipelineStore` (user pipelines + optional `max_context_bytes`).

**`system_prompt.md`** is created from `priv/defaults/system_prompt.md` during setup but is not auto-synced afterward. When tools or skills are added to the defaults, manually copy the updated default to `.jido/system_prompt.md`.

## Code Style

- `mix format` enforced, no exceptions
- Signal strings: `jido_claw.<subsystem>.<event>` (never `jido_cli`)
- Prefer pattern matching over conditionals
- Commit messages: `feat:`, `fix:`, `refactor:`, `docs:` prefixes

## Testing

- Tests in `test/jido_claw/`, mirroring source structure
- `:docker_sandbox` tag excluded by default
- Supports `MIX_TEST_PARTITION` for CI sharding

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
