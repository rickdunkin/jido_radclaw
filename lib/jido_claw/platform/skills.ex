defmodule JidoClaw.Skills do
  @moduledoc """
  Cached skill registry backed by YAML files in `.jido/skills/`.

  Skills are multi-step workflows that orchestrate multiple agents. Steps run
  sequentially by default. When steps carry `name` and `depends_on` fields the
  skill is executed as a DAG: independent steps run in parallel, dependent steps
  wait for their prerequisites.

  Parsed once at boot and cached in GenServer state — no disk I/O on lookups.

  Sequential YAML format:

      name: full_review
      description: Run tests and code review in parallel, then synthesize
      steps:
        - template: test_runner
          task: "Run the full test suite and report all results"
        - template: reviewer
          task: "Review recent git changes for bugs and style issues"
      synthesis: "Combine the test results and review findings into a single report"

  DAG YAML format (steps with name + optional depends_on):

      name: full_review
      description: Run tests and code review in parallel, then synthesize
      steps:
        - name: run_tests
          template: test_runner
          task: "Run the full test suite and report all results"
        - name: review_code
          template: reviewer
          task: "Review all recent git changes for bugs and style issues"
        - name: synthesize
          template: docs_writer
          task: "Combine results into a single report"
          depends_on: [run_tests, review_code]
      synthesis: "Present the combined findings"
  """

  use GenServer
  require Logger

  defstruct [:name, :description, :steps, :synthesis, :mode, :max_iterations]

  @default_skills %{
    "full_review.yaml" => """
    name: full_review
    description: Run tests and code review in parallel, then synthesize findings
    steps:
      - name: run_tests
        template: test_runner
        task: "Run the full test suite and report all results including failures, errors, and test counts"
      - name: review_code
        template: reviewer
        task: "Review all recent git changes for bugs, security issues, and style violations"
      - name: synthesize
        template: docs_writer
        task: "Combine the test results and code review findings into a single actionable report with priorities"
        depends_on: [run_tests, review_code]
    synthesis: "Present the combined test and review findings with clear action items"
    """,
    "refactor_safe.yaml" => """
    name: refactor_safe
    description: Review code, refactor, then verify with tests
    steps:
      - name: review_code
        template: reviewer
        task: "Review the codebase and identify refactoring opportunities with specific file and line references"
      - name: refactor
        template: refactorer
        task: "Apply the recommended refactoring changes from the review"
        depends_on: [review_code]
      - name: verify_tests
        template: test_runner
        task: "Run the full test suite to verify refactoring didn't break anything"
        depends_on: [refactor]
    synthesis: "Summarize what was refactored, what tests passed/failed, and any remaining issues"
    """,
    "explore_codebase.yaml" => """
    name: explore_codebase
    description: Deep codebase exploration and documentation
    steps:
      - name: explore
        template: researcher
        task: "Explore the full project structure, key modules, dependencies, and architecture patterns"
      - name: document
        template: docs_writer
        task: "Write a comprehensive project overview document based on the codebase analysis"
        depends_on: [explore]
    synthesis: "Present the codebase overview with architecture diagram suggestions and key findings"
    """,
    "security_audit.yaml" => """
    name: security_audit
    description: Comprehensive security audit — scan project structure, then deep-dive in parallel
    steps:
      - name: map_codebase
        template: researcher
        task: "Map the full project structure focusing on security-relevant code: auth, API endpoints, database queries, shell execution, file handlers, config/secrets"
      - name: audit_code
        template: reviewer
        task: "Perform a deep security audit on all identified security-relevant code. Check for injection, auth bypass, hardcoded secrets, CORS, SSRF, path traversal. Rate each finding CRITICAL/HIGH/MEDIUM/LOW."
        depends_on: [map_codebase]
    synthesis: "Produce a structured security audit report with executive summary, findings by severity, and remediation steps"
    """,
    "implement_feature.yaml" => """
    name: implement_feature
    description: Full feature implementation lifecycle — research, code, then test and review in parallel
    steps:
      - name: research
        template: researcher
        task: "Research the codebase to understand existing patterns, identify files to modify, and produce an implementation plan"
      - name: implement
        template: coder
        task: "Implement the feature following existing patterns, with proper error handling"
        depends_on: [research]
      - name: run_tests
        template: test_runner
        task: "Run the full test suite to check for regressions and verify new functionality"
        depends_on: [implement]
      - name: review_code
        template: reviewer
        task: "Review the implementation for correctness, conventions, security, and test coverage"
        depends_on: [implement]
      - name: synthesize
        template: docs_writer
        task: "Summarize: what was implemented, files modified, test results, review verdict, remaining work"
        depends_on: [run_tests, review_code]
    synthesis: "Present the feature summary with test and review outcomes"
    """,
    "debug_issue.yaml" => """
    name: debug_issue
    description: Systematic debugging — investigate, reproduce, fix, verify
    steps:
      - name: investigate
        template: researcher
        task: "Investigate the issue: search relevant code, check git log for recent changes, form hypotheses"
      - name: reproduce
        template: test_runner
        task: "Try to reproduce: run existing tests, write a minimal reproduction test if possible"
        depends_on: [investigate]
      - name: fix
        template: coder
        task: "Fix the root cause (not symptom), add a regression test"
        depends_on: [reproduce]
      - name: verify
        template: test_runner
        task: "Verify: run reproduction test and full suite, confirm no regressions"
        depends_on: [fix]
    synthesis: "Root cause, fix applied, verification results, regression test added, related risks"
    """,
    "onboard_dev.yaml" => """
    name: onboard_dev
    description: Generate comprehensive onboarding documentation for new developers
    steps:
      - name: explore
        template: researcher
        task: "Thorough codebase analysis: project type, structure, entry points, config, key modules, data flow, testing setup"
      - name: write_docs
        template: docs_writer
        task: "Write onboarding guide: Quick Start, Architecture, Codebase Map, Key Files, Common Tasks, Conventions"
        depends_on: [explore]
    synthesis: "Present complete onboarding documentation with a First Day Checklist at the top"
    """,
    "iterative_feature.yaml" => """
    name: iterative_feature
    description: Implement a feature with iterative refinement — generate, verify, repeat until passing
    mode: iterative
    max_iterations: 5
    steps:
      - name: implement
        role: generator
        template: coder
        task: "Implement the feature following existing project patterns, with proper error handling and tests"
        produces:
          type: elixir_module
          verification_criteria:
            - "All tests pass"
            - "No compiler warnings"
            - "mix format clean"
      - name: verify
        role: evaluator
        template: verifier
        task: "Verify the implementation: run mix compile --warnings-as-errors, mix format --check-formatted, mix test. Review the code for correctness and conventions. End with VERDICT: PASS or VERDICT: FAIL with specific issues to fix."
        consumes: [implement]
    synthesis: "Present the final implementation after iterative refinement with verification results"
    """,
    "verified_feature.yaml" => """
    name: verified_feature
    description: Implement a feature with semi-formal pre-verification
    mode: iterative
    max_iterations: 5
    steps:
      - name: implement
        role: generator
        template: coder
        task: "Implement the feature following existing project patterns"
        produces:
          type: elixir_module
      - name: pre_verify
        role: evaluator
        template: verifier
        task: |
          Verify the implementation through structured analysis:
          1. Read the implementation code and any files it touches
          2. Search for related tests, modules, and dependencies
          3. Check git diff for the full scope of changes
          4. Run: mix compile --warnings-as-errors
          5. Run: mix test
          6. Run: mix format --check-formatted
          7. Collect all findings from steps 1-6 as evidence text
          8. Call verify_certificate with:
             - code: the implementation
             - specification: the original task description
             - evidence: your collected findings from steps 1-6
          If ALL of the following hold, emit VERDICT: PASS:
            - mix compile passes
            - mix test passes
            - mix format --check-formatted passes
            - certificate confidence >= 0.8 and verdict PASS
          Otherwise emit VERDICT: FAIL with specific issues.
        consumes: [implement]
    synthesis: "Present the final implementation with verification certificate"
    """,
    "sfr_review.yaml" => """
    name: sfr_review
    description: Code review with semi-formal reasoning certificate
    steps:
      - name: analyze_scope
        template: verifier
        task: "Run git_diff and git_status to identify all changed files. For each changed file, read it and search for tests that cover it. Summarize what each file does and what tests exist for it."
      - name: certificate_review
        template: verifier
        task: |
          Review all changes identified in the scope analysis:
          1. Read each changed file and its related modules
          2. Search for tests covering the changed code
          3. Run: mix compile --warnings-as-errors
          4. Collect all findings as evidence text
          5. Call verify_certificate with certificate_type "code_review":
             - code: the git diff of all changes
             - specification: what the changes intend to accomplish (from scope analysis)
             - evidence: your collected findings
          Report the certificate verdict and any issues found.
        depends_on: [analyze_scope]
    synthesis: "Present code review findings with semi-formal certificate and confidence scores"
    """
  }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all cached skill names."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Find a cached skill by name."
  @spec get(String.t()) :: {:ok, %__MODULE__{}} | {:error, String.t()}
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Return all cached skill structs."
  @spec all() :: [%__MODULE__{}]
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Reload skills from disk (hot-reload after YAML edits)."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Ensure default skills exist in .jido/skills/.

  Backfills any missing default skill files without overwriting user edits.
  Creates the directory if it doesn't exist.
  """
  @spec ensure_defaults(String.t()) :: :ok
  def ensure_defaults(project_dir) do
    dir = skills_dir(project_dir)
    File.mkdir_p!(dir)

    Enum.each(@default_skills, fn {filename, content} ->
      path = Path.join(dir, filename)
      unless File.exists?(path), do: File.write!(path, content)
    end)

    :ok
  end

  @doc """
  Returns true if any step in the skill has a `depends_on` or `name` field,
  indicating DAG execution should be used instead of sequential FSM execution.
  """
  @spec has_dag_steps?(%__MODULE__{}) :: boolean()
  def has_dag_steps?(%__MODULE__{steps: steps}) do
    Enum.any?(steps, fn step ->
      Map.has_key?(step, "depends_on") or Map.has_key?(step, :depends_on) or
        Map.has_key?(step, "name") or Map.has_key?(step, :name)
    end)
  end

  @doc """
  Determine the execution mode for a skill.

  Returns `:iterative` for skills with `mode: "iterative"`, `:dag` for skills
  with DAG step annotations, and `:sequential` otherwise.
  """
  @spec execution_mode(%__MODULE__{}) :: :iterative | :dag | :sequential
  def execution_mode(%__MODULE__{mode: "iterative"}), do: :iterative

  def execution_mode(%__MODULE__{} = skill) do
    if has_dag_steps?(skill), do: :dag, else: :sequential
  end

  # Backwards-compatible API (accepts project_dir but ignores it — uses cache)
  @spec list(String.t()) :: [String.t()]
  def list(_project_dir), do: list()

  @spec get(String.t(), String.t()) :: {:ok, %__MODULE__{}} | {:error, String.t()}
  def get(name, _project_dir), do: get(name)

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    {:ok, %{project_dir: project_dir, skills: []}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    skills = load_from_disk(state.project_dir)
    Logger.debug("[Skills] Cached #{length(skills)} skills from #{skills_dir(state.project_dir)}")
    {:noreply, %{state | skills: skills}}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state.skills, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.skills, & &1.name), state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Enum.find(state.skills, &(&1.name == name)) do
      nil -> {:reply, {:error, "Skill '#{name}' not found"}, state}
      skill -> {:reply, {:ok, skill}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    skills = load_from_disk(state.project_dir)
    Logger.info("[Skills] Reloaded #{length(skills)} skills")
    {:reply, :ok, %{state | skills: skills}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp skills_dir(project_dir), do: Path.join([project_dir, ".jido", "skills"])

  defp load_from_disk(project_dir) do
    dir = skills_dir(project_dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&parse_skill_file/1)

      {:error, _} ->
        []
    end
  end

  defp parse_skill_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) ->
        skill = %__MODULE__{
          name: Map.get(data, "name", Path.basename(path, ".yaml")),
          description: Map.get(data, "description", ""),
          steps: Map.get(data, "steps", []),
          synthesis: Map.get(data, "synthesis", ""),
          mode: Map.get(data, "mode"),
          max_iterations: Map.get(data, "max_iterations")
        }

        [skill]

      {:ok, _} ->
        []

      {:error, reason} ->
        Logger.warning("[Skills] Failed to parse #{path}: #{inspect(reason)}")
        []
    end
  end
end
