defmodule JidoClaw.JidoMd do
  @moduledoc """
  Generates and loads the JIDO.md self-knowledge file at .jido/JIDO.md,
  and the .jido/config.yaml with documented defaults.
  """

  def ensure(project_dir) do
    path = Path.join([project_dir, ".jido", "JIDO.md"])

    unless File.exists?(path) do
      generate(project_dir)
    end
  end

  def generate(project_dir) do
    dir = Path.join(project_dir, ".jido")
    File.mkdir_p!(dir)

    project_name = Path.basename(project_dir)
    project_type = detect_type(project_dir)
    framework_details = detect_framework_details(project_dir, project_type)
    entry_points = detect_entry_points(project_dir, project_type)

    content =
      jido_md_content(project_name, project_dir, project_type, framework_details, entry_points)

    path = Path.join(dir, "JIDO.md")
    File.write!(path, content)

    config_path = Path.join(dir, "config.yaml")

    unless File.exists?(config_path) do
      File.write!(config_path, config_yaml_content())
    end

    # Ensure agents directory exists
    agents_dir = Path.join(dir, "agents")
    File.mkdir_p!(agents_dir)

    ensure_gitignore(dir)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Content builders
  # ---------------------------------------------------------------------------

  defp jido_md_content(project_name, project_dir, project_type, framework_details, entry_points) do
    """
    # JIDO.md — Self-Knowledge for #{project_name}

    This file is read by the Jido agent at session start. It describes the project,
    available tools, agent templates, skills, and conventions. Edit the Architecture
    and Conventions sections to guide agent behavior for your specific codebase.

    ---

    ## Project

    - **Name**: #{project_name}
    - **Type**: #{project_type}
    - **Root**: #{project_dir}
    #{framework_details}
    #{entry_points_section(entry_points)}
    ---

    ## Agent Templates

    Use `spawn_agent` with a template name to create a child agent. Each template
    has a fixed tool set and iteration limit optimized for its task.

    ### `coder`
    - **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, git_status, git_diff, git_commit, project_info
    - **Max iterations**: 25
    - **Use for**: Writing new code, fixing bugs, implementing features, modifying existing files

    ### `test_runner`
    - **Tools**: read_file, run_command, search_code
    - **Max iterations**: 15
    - **Use for**: Running test suites, verifying changes, checking test coverage, reproducing failures

    ### `reviewer`
    - **Tools**: read_file, git_diff, git_status, search_code
    - **Max iterations**: 15
    - **Use for**: Code review, finding bugs, checking style, auditing recent changes

    ### `docs_writer`
    - **Tools**: read_file, write_file, search_code
    - **Max iterations**: 15
    - **Use for**: Writing documentation, README files, module docs, inline comments

    ### `researcher`
    - **Tools**: read_file, search_code, list_directory, project_info
    - **Max iterations**: 15
    - **Use for**: Codebase exploration, architecture analysis, dependency mapping, understanding unfamiliar code

    ### `refactorer`
    - **Tools**: read_file, write_file, edit_file, list_directory, search_code, run_command, git_status, git_diff, git_commit, project_info
    - **Max iterations**: 25
    - **Use for**: Large-scale refactoring, code restructuring, renaming across files, extracting modules

    ### `verifier`
    - **Tools**: read_file, search_code, git_diff, git_status, run_command, list_directory
    - **Max iterations**: 20
    - **Use for**: Interactive verification — running tests, starting servers, hitting endpoints, checking build output. Emits VERDICT: PASS or VERDICT: FAIL.

    ---

    ## Skills

    Skills are multi-step workflows that orchestrate agents sequentially. Run a skill
    with the `run_skill` tool or the `/skill <name>` REPL command.

    ### Built-in Skills

    | Skill | Steps | Purpose |
    |-------|-------|---------|
    | `full_review` | test_runner → reviewer | Run tests and review recent changes, synthesize findings |
    | `refactor_safe` | reviewer → refactorer → test_runner | Review, refactor, then verify nothing broke |
    | `explore_codebase` | researcher → docs_writer | Deep exploration, then produce a project overview doc |

    ### Custom Skills

    Create `.jido/skills/<name>.yaml` with this format:

    ```yaml
    name: my_skill
    description: What this skill does
    steps:
      - template: researcher
        task: "Explore the auth module and identify all entry points"
      - template: coder
        task: "Implement the changes based on the research findings"
      - template: test_runner
        task: "Run the full test suite and verify nothing is broken"
    synthesis: "Summarize what was done and any remaining issues"
    ```

    Each step runs sequentially. The output of previous steps is available as context
    for subsequent steps. The `synthesis` field is the final prompt used to summarize
    all step outputs into a single result.

    Available template names: `coder`, `test_runner`, `reviewer`, `docs_writer`,
    `researcher`, `refactorer`

    ---

    ## Build & Test

    #{build_commands(project_type)}
    ---

    ## Memory

    The agent has persistent memory that survives across sessions. Memory is stored in
    `.jido/memory.json` (git-ignored).

    **Memory types**:
    - `fact` — General facts about the codebase (default)
    - `pattern` — Recurring patterns or approaches discovered
    - `decision` — Architectural or design decisions made
    - `preference` — User preferences for how tasks should be done

    **Tools**:
    - `remember` — Store a fact: `remember("auth uses Guardian JWT", type: "pattern")`
    - `recall` — Search memories: `recall("auth")` returns matching entries

    The agent automatically recalls relevant memories at the start of each session.
    Use memory to preserve context across sessions: decisions made, patterns found,
    files that are important, things to avoid.

    ---

    ## Architecture

    <!-- Describe your project's high-level architecture here. Examples:
    - What are the main subsystems or layers?
    - How does data flow through the system?
    - What are the key entry points (web, CLI, background jobs)?
    - What external services does this project depend on?
    - What are the critical invariants the agent must not break?
    -->

    ---

    ## Conventions

    <!-- Describe your coding conventions here. Examples:
    - Naming patterns for modules, functions, files
    - Where new modules should be placed
    - How errors are handled (Result types, exceptions, etc.)
    - Test patterns and where tests live
    - How database migrations are structured
    - Commit message format
    - PR/review requirements
    -->

    ---

    ## Rules

    - Always run tests after making changes — use `test_runner` or the build commands above
    - Use `search_code` before modifying a function to find all call sites
    - Use `git_diff` before committing to review what changed
    - Keep commits atomic: one logical change per commit with a clear message
    - Prefer editing existing files over creating new ones when extending functionality
    - Read the file before editing it — never write blind
    - When a task is ambiguous, `recall` memory before asking the user

    ---

    ## Configuration

    Agent behavior is controlled by `.jido/config.yaml`. Key settings:

    | Key | Default | Description |
    |-----|---------|-------------|
    | `model` | `ollama:nemotron-3-super:cloud` | Provider and model (`ollama:model` or `openai:model`) |
    | `max_iterations` | `25` | Hard cap on agent reasoning steps per task |
    | `timeout` | `120000` | Milliseconds before a task times out |
    | `ollama.base_url` | `http://localhost:11434` | Ollama server URL |

    Set `OLLAMA_API_KEY` in your environment to use Ollama Cloud. The base_url switches
    automatically unless you override it in config.yaml.
    """
  end

  defp config_yaml_content do
    """
    # JidoClaw Configuration
    # Generated by `jido init`. Edit to customize agent behavior.
    # This file is git-ignored — safe to put personal settings here.
    # Run `jido --setup` or `/setup` in the REPL to reconfigure interactively.

    # Provider: ollama | anthropic | openai | google | groq | xai | openrouter
    provider: ollama

    # Model: provider:model_name
    # Local:  ollama:nemotron-3-super, ollama:qwen3.5:35b, ollama:qwen3-coder-next:latest
    # Cloud:  ollama:nemotron-3-super:cloud, anthropic:claude-sonnet-4-20250514, openai:gpt-4.1
    # Router: openrouter:anthropic/claude-sonnet-4, openrouter:deepseek/deepseek-r1
    model: "ollama:nemotron-3-super:cloud"

    # Maximum reasoning iterations per agent task.
    max_iterations: 25

    # Task timeout in milliseconds (default: 2 minutes)
    timeout: 120000

    # Provider-specific settings (optional overrides)
    # providers:
    #   ollama:
    #     base_url: "http://localhost:11434"
    #   openrouter:
    #     base_url: "https://openrouter.ai/api/v1"
    """
  end

  # ---------------------------------------------------------------------------
  # Framework detection
  # ---------------------------------------------------------------------------

  defp detect_type(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> "Elixir/OTP"
      File.exists?(Path.join(dir, "package.json")) -> "JavaScript/TypeScript"
      File.exists?(Path.join(dir, "Cargo.toml")) -> "Rust"
      File.exists?(Path.join(dir, "go.mod")) -> "Go"
      File.exists?(Path.join(dir, "pyproject.toml")) -> "Python"
      File.exists?(Path.join(dir, "requirements.txt")) -> "Python"
      true -> "Unknown"
    end
  end

  defp detect_framework_details(dir, "Elixir/OTP") do
    mix_content = safe_read(Path.join(dir, "mix.exs"))

    has_phoenix = dep_present?(mix_content, "phoenix")
    has_liveview = dep_present?(mix_content, "phoenix_live_view")
    has_ecto = dep_present?(mix_content, "ecto")
    has_oban = dep_present?(mix_content, "oban")
    has_absinthe = dep_present?(mix_content, "absinthe")

    umbrella = File.exists?(Path.join(dir, "apps"))

    frameworks =
      []
      |> maybe_add(has_phoenix, "Phoenix #{if has_liveview, do: "(with LiveView)", else: ""}")
      |> maybe_add(has_ecto, "Ecto")
      |> maybe_add(has_oban, "Oban")
      |> maybe_add(has_absinthe, "Absinthe/GraphQL")
      |> maybe_add(umbrella, "Umbrella project (apps/ directory)")

    if frameworks == [] do
      ""
    else
      "- **Frameworks**: #{Enum.join(frameworks, ", ")}\n"
    end
  end

  defp detect_framework_details(dir, "JavaScript/TypeScript") do
    pkg_content = safe_read(Path.join(dir, "package.json"))

    has_next = pkg_dep_present?(pkg_content, "next")
    has_react = pkg_dep_present?(pkg_content, "react")
    has_express = pkg_dep_present?(pkg_content, "express")
    has_fastify = pkg_dep_present?(pkg_content, "fastify")
    has_nest = pkg_dep_present?(pkg_content, "@nestjs/core")

    has_prisma =
      pkg_dep_present?(pkg_content, "prisma") or pkg_dep_present?(pkg_content, "@prisma/client")

    has_ts = File.exists?(Path.join(dir, "tsconfig.json"))

    frameworks =
      []
      |> maybe_add(has_next, "Next.js")
      |> maybe_add(has_react and not has_next, "React")
      |> maybe_add(has_express, "Express")
      |> maybe_add(has_fastify, "Fastify")
      |> maybe_add(has_nest, "NestJS")
      |> maybe_add(has_prisma, "Prisma")
      |> maybe_add(has_ts, "TypeScript")

    if frameworks == [] do
      ""
    else
      "- **Frameworks**: #{Enum.join(frameworks, ", ")}\n"
    end
  end

  defp detect_framework_details(dir, "Rust") do
    cargo = safe_read(Path.join(dir, "Cargo.toml"))

    has_axum = String.contains?(cargo, "axum")
    has_actix = String.contains?(cargo, "actix-web")
    has_tokio = String.contains?(cargo, "tokio")
    has_sqlx = String.contains?(cargo, "sqlx")

    frameworks =
      []
      |> maybe_add(has_axum, "Axum")
      |> maybe_add(has_actix, "Actix-web")
      |> maybe_add(has_tokio, "Tokio async")
      |> maybe_add(has_sqlx, "SQLx")

    if frameworks == [] do
      ""
    else
      "- **Frameworks**: #{Enum.join(frameworks, ", ")}\n"
    end
  end

  defp detect_framework_details(dir, "Go") do
    mod = safe_read(Path.join(dir, "go.mod"))

    has_gin = String.contains?(mod, "gin-gonic/gin")
    has_echo = String.contains?(mod, "labstack/echo")
    has_fiber = String.contains?(mod, "gofiber/fiber")

    frameworks =
      []
      |> maybe_add(has_gin, "Gin")
      |> maybe_add(has_echo, "Echo")
      |> maybe_add(has_fiber, "Fiber")

    if frameworks == [] do
      ""
    else
      "- **Frameworks**: #{Enum.join(frameworks, ", ")}\n"
    end
  end

  defp detect_framework_details(dir, "Python") do
    pyproject = safe_read(Path.join(dir, "pyproject.toml"))
    requirements = safe_read(Path.join(dir, "requirements.txt"))
    combined = pyproject <> requirements

    has_django = String.contains?(combined, "django")
    has_fastapi = String.contains?(combined, "fastapi")
    has_flask = String.contains?(combined, "flask")
    has_sqlalchemy = String.contains?(combined, "sqlalchemy")

    frameworks =
      []
      |> maybe_add(has_django, "Django")
      |> maybe_add(has_fastapi, "FastAPI")
      |> maybe_add(has_flask, "Flask")
      |> maybe_add(has_sqlalchemy, "SQLAlchemy")

    if frameworks == [] do
      ""
    else
      "- **Frameworks**: #{Enum.join(frameworks, ", ")}\n"
    end
  end

  defp detect_framework_details(_dir, _type), do: ""

  defp detect_entry_points(dir, "Elixir/OTP") do
    candidates = [
      {Path.join([dir, "lib"]), "lib/"},
      {Path.join([dir, "config", "config.exs"]), "config/config.exs"},
      {Path.join([dir, "mix.exs"]), "mix.exs"}
    ]

    # Look for application.ex or main entry files
    app_files =
      [
        Path.join([dir, "lib", "**", "application.ex"]),
        Path.join([dir, "lib", "**", "main.ex"])
      ]
      |> Enum.flat_map(&wildcard_relative(dir, &1))

    explicit =
      Enum.filter(candidates, fn {path, _} -> File.exists?(path) end) |> Enum.map(&elem(&1, 1))

    (explicit ++ app_files) |> Enum.uniq()
  end

  defp detect_entry_points(dir, "JavaScript/TypeScript") do
    pkg = safe_read(Path.join(dir, "package.json"))

    main =
      case Jason.decode(pkg) do
        {:ok, %{"main" => m}} -> [m]
        _ -> []
      end

    candidates =
      ["src/index.ts", "src/index.js", "index.ts", "index.js", "src/app.ts", "src/server.ts"]
      |> Enum.filter(&File.exists?(Path.join(dir, &1)))

    (main ++ candidates) |> Enum.uniq()
  end

  defp detect_entry_points(dir, "Rust") do
    candidates = ["src/main.rs", "src/lib.rs"]
    Enum.filter(candidates, &File.exists?(Path.join(dir, &1)))
  end

  defp detect_entry_points(dir, "Go") do
    candidates = ["main.go", "cmd/main.go"]
    Enum.filter(candidates, &File.exists?(Path.join(dir, &1)))
  end

  defp detect_entry_points(dir, "Python") do
    candidates = ["main.py", "app.py", "src/main.py", "manage.py"]
    Enum.filter(candidates, &File.exists?(Path.join(dir, &1)))
  end

  defp detect_entry_points(_dir, _type), do: []

  defp entry_points_section([]), do: ""

  defp entry_points_section(points) do
    list = points |> Enum.map(&"  - `#{&1}`") |> Enum.join("\n")
    "- **Entry points**:\n#{list}\n"
  end

  # ---------------------------------------------------------------------------
  # Build commands
  # ---------------------------------------------------------------------------

  defp build_commands("Elixir/OTP") do
    """
    | Command | Purpose |
    |---------|---------|
    | `mix compile` | Compile the project |
    | `mix test` | Run the full test suite |
    | `mix test test/path/to/test.exs` | Run a specific test file |
    | `mix test --failed` | Re-run only failing tests |
    | `mix format` | Format all source files |
    | `mix format --check-formatted` | Verify formatting (CI) |
    | `mix credo` | Lint with Credo |
    | `mix credo --strict` | Strict lint mode |
    | `mix dialyzer` | Run Dialyzer type analysis |
    | `mix deps.get` | Fetch dependencies |
    | `mix ecto.migrate` | Run database migrations (if Ecto is used) |

    """
  end

  defp build_commands("JavaScript/TypeScript") do
    """
    | Command | Purpose |
    |---------|---------|
    | `npm install` | Install dependencies |
    | `npm run build` | Build the project |
    | `npm test` | Run the full test suite |
    | `npm run lint` | Lint the codebase |
    | `npm run typecheck` | TypeScript type checking |
    | `npm run dev` | Start development server |

    """
  end

  defp build_commands("Rust") do
    """
    | Command | Purpose |
    |---------|---------|
    | `cargo build` | Compile the project |
    | `cargo test` | Run the full test suite |
    | `cargo clippy` | Lint with Clippy |
    | `cargo fmt` | Format source files |
    | `cargo doc` | Generate documentation |

    """
  end

  defp build_commands("Go") do
    """
    | Command | Purpose |
    |---------|---------|
    | `go build ./...` | Build all packages |
    | `go test ./...` | Run the full test suite |
    | `golangci-lint run` | Lint the codebase |
    | `gofmt -w .` | Format source files |
    | `go vet ./...` | Run go vet |

    """
  end

  defp build_commands("Python") do
    """
    | Command | Purpose |
    |---------|---------|
    | `pytest` | Run the full test suite |
    | `pytest -x` | Stop on first failure |
    | `ruff check` | Lint with Ruff |
    | `ruff format` | Format source files |
    | `mypy .` | Type checking |

    """
  end

  defp build_commands(_), do: "<!-- Add your build/test commands here -->\n\n"

  # ---------------------------------------------------------------------------
  # .gitignore management
  # ---------------------------------------------------------------------------

  defp ensure_gitignore(dir) do
    gitignore_path = Path.join(dir, ".gitignore")

    existing =
      if File.exists?(gitignore_path) do
        File.read!(gitignore_path)
      else
        ""
      end

    additions =
      ["sessions/", "config.yaml", "memory.json", "memory.db"]
      |> Enum.reject(&String.contains?(existing, &1))
      |> Enum.join("\n")

    unless additions == "" do
      separator =
        if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"

      File.write!(gitignore_path, existing <> separator <> additions <> "\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp dep_present?(mix_content, dep_name) do
    String.contains?(mix_content, ":#{dep_name}")
  end

  defp pkg_dep_present?(pkg_content, dep_name) do
    String.contains?(pkg_content, "\"#{dep_name}\"")
  end

  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _item), do: list

  defp wildcard_relative(base_dir, pattern) do
    # Convert glob pattern to matching files, return relative paths
    base_len = String.length(base_dir) + 1

    pattern
    |> Path.wildcard()
    |> Enum.map(fn abs_path ->
      String.slice(abs_path, base_len, String.length(abs_path))
    end)
  end
end
