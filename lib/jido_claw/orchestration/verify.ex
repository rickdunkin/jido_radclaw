defmodule JidoClaw.Orchestration.Verify do
  # Ported from mateodaza/camus @ 53da91b3, MIT (skills/camus/scripts/verify.py —
  # the {pass, inconclusive, tampered, failures, checks} gate contract, the
  # failure-classification table, the HEAD-integrity invariant, and the
  # "NEVER a false verdict" cardinal rule). Two deliberate corrections over
  # upstream, documented inline: a two-mode integrity model (upstream is
  # sealed-only), and capture-failure degrading a would-be green to
  # INCONCLUSIVE rather than open (law 4 of docs/TRUST-BOUNDARIES.md — our
  # verify target is a git repo by definition, so "integrity not asserted"
  # must never read as a certified green).
  @moduledoc """
  The deterministic verify authority (next-ten item 5, camus C1-2): the engine
  runs the repo's verify command itself and reads the **exit code** — the
  verdict never rides an LLM relay (law 2). `build_result/2` is pure: every
  subprocess/git touch is an injected seam (`:runner`, `:porcelain`, `:head`,
  `:diff_digest`), defaulting to `JidoClaw.Orchestration.Verify.OsCmdRunner`
  and `JidoClaw.Orchestration.Verify.Git`.

  ## Two integrity modes

    * `:sealed` — the camus committed-state shape plus the signed C1-2 audit
      hardening, selected when the run holds an
      engine-observed `sealed_head` (the run committed work): the tracked tree
      and every nonignored untracked path must be clean against HEAD before the
      checks run (dirt ⇒ RED `uncommitted_state`, checks never run), mutation
      and HEAD movement during the checks are RED, and HEAD must equal the
      sealed sha (a committed cover-up is `head_moved` — porcelain is blind to
      edit→commit→rerun). Gitignored paths remain outside the authority.
    * `:working_tree` — the default for today's non-committing routes: a dirty
      tree before the checks is recorded as an envelope **fact**
      (`integrity_note`), mid-verify integrity rides HEAD stability plus a
      content-addressed working-tree digest: a tracked binary diff plus a
      sorted, bounded manifest of nonignored untracked path/type/mode/content
      fingerprints. A green binds `{head, tree_digest}`.

  ## Misclassification policy (camus cardinal rule)

  Err toward **inconclusive** (a withheld verdict) — never a false red, never
  a pass. `missing_tool` / `no_tests` / `timeout` / `output_limit` /
  `integrity_unavailable` are inconclusive kinds; the integrity RED kinds
  (`uncommitted_state` / `working_tree_mutation` / `head_moved`) never are — a
  tampered tree is red, the remedy is a human look, never an auto-retry.

  ## Capture failure (law-4 override of camus's degrade-open)

  A would-be PASS whose integrity capture failed (`head` nil in either mode;
  `tree_digest` nil in `:working_tree`; porcelain nil in `:sealed`) downgrades
  to inconclusive `integrity_unavailable` — a green must always name exactly
  what state it certified. A RED stays red (failing checks are failing
  regardless), with `integrity_note` recording the unasserted invariant.
  """

  # The failure-entry shape has ONE construction site (`Envelope.failure/5`);
  # imported so every classification/integrity site builds through it.
  import JidoClaw.Orchestration.Verify.Envelope, only: [failure: 5]

  alias JidoClaw.Orchestration.Verify.Envelope

  # Failure kinds that mean "this check could not deliver a verdict on the
  # CODE" — a failure set made up solely of these leaves the run inconclusive
  # (pass:false, never red). The integrity RED kinds are deliberately NOT here.
  @inconclusive_kinds ~w(missing_tool no_tests timeout output_limit integrity_unavailable)

  @remedy_no_verifier "no recognized verify config found; set `verify_cmd:` (or a `verify:` " <>
                        "block) in .jido/config.yaml to specify the command explicitly"

  @type check :: %{
          :name => String.t(),
          :cmd => [String.t()],
          optional(:env) => %{optional(String.t()) => String.t()},
          optional(:timeout_ms) => pos_integer() | nil
        }

  @doc "The inconclusive failure kinds (strings — the JSONB boundary vocabulary)."
  @spec inconclusive_kinds() :: [String.t()]
  def inconclusive_kinds, do: @inconclusive_kinds

  @doc """
  The runner seam module: `config :jido_claw, :verify, runner: module` (a
  module exporting `run(check, repo) :: {exit | :output_limit, log_tail}`),
  defaulting to the real `Verify.OsCmdRunner`. test.exs points it at a stub so
  a full-catalog composer launch never spawns a subprocess.
  """
  @spec runner() :: module()
  def runner, do: seam(:runner, __MODULE__.OsCmdRunner)

  @doc """
  The git seam module: `config :jido_claw, :verify, git: module` (a module
  exporting `head/1`, `porcelain/1`, `diff_digest/1`), defaulting to the real
  `Verify.Git`. Shared by `build_result/2` defaults, the composer's
  wave-boundary head observation, and the convergence-time integrity re-check.
  """
  @spec git() :: module()
  def git, do: seam(:git, __MODULE__.Git)

  defp seam(key, default) do
    :jido_claw
    |> Application.get_env(:verify, [])
    |> Keyword.get(key, default)
  end

  @doc """
  Assemble the verify envelope for `checks` (collect-all: every check runs,
  every nonzero exit is classified into one failure entry).

  Options:

    * `:repo` (required) — the working directory every check and git capture
      targets.
    * `:runner` (required) — `fun(check, repo) -> {exit :: integer() |
      :output_limit, log_tail :: binary()}`. The runner owns
      redact-full-then-tail; `build_result` never sees raw output.
    * `:sealed_head` — the engine-observed sealed sha (nil ⇒ `:working_tree`
      mode, a sha ⇒ `:sealed`).
    * `:porcelain` / `:head` / `:diff_digest` — the git capture seams
      (`fun(repo) -> value | nil`), defaulting to `git/0`'s module.
  """
  @spec build_result([check()], keyword()) :: Envelope.t()
  def build_result(checks, opts) do
    repo = Keyword.fetch!(opts, :repo)
    runner = Keyword.fetch!(opts, :runner)
    git_mod = git()
    porcelain = Keyword.get(opts, :porcelain, &git_mod.porcelain/1)
    head = Keyword.get(opts, :head, &git_mod.head/1)
    diff_digest = Keyword.get(opts, :diff_digest, &git_mod.diff_digest/1)
    sealed_head = Keyword.get(opts, :sealed_head)

    seams = %{porcelain: porcelain, head: head, diff_digest: diff_digest}

    case mode_for(sealed_head) do
      :sealed -> sealed_result(checks, runner, repo, sealed_head, seams)
      :working_tree -> working_tree_result(checks, runner, repo, seams)
    end
  end

  @doc """
  The loud refusal envelope (camus `no_verifier_detected` shape: `pass: false,
  inconclusive: true`, remedy in `log_tail`) — used for an empty check list
  AND for every config-resolution failure the verify stage catches (an invalid
  `verify_cmd` must ride the infra lane with a remedy, never a wave-execution
  error). `mode`/`sealed_head` echo what the run would have verified against.
  """
  @spec refusal_result(String.t(), String.t(), keyword()) :: Envelope.t()
  def refusal_result(reason, log_tail, opts \\ []) do
    sealed_head = Keyword.get(opts, :sealed_head)

    %Envelope{
      pass: false,
      inconclusive: true,
      tampered: false,
      failures: [failure("verify", "missing_tool", log_tail, nil, reason)],
      checks: [],
      head: nil,
      integrity_note: Keyword.get(opts, :integrity_note),
      mode: mode_for(sealed_head),
      tree_digest: nil,
      sealed_head: sealed_head
    }
  end

  defp mode_for(sealed_head) when is_binary(sealed_head), do: :sealed
  defp mode_for(_sealed_head), do: :working_tree

  # ---------------------------------------------------------------------------
  # Sealed mode (camus shape + signed untracked hardening + sealed-head compare)
  # ---------------------------------------------------------------------------

  defp sealed_result(checks, runner, repo, sealed_head, seams) do
    before_porcelain = seams.porcelain.(repo)
    head_before = seams.head.(repo)

    cond do
      # A committed cover-up (edit → COMMIT → rerun): porcelain reads clean but
      # HEAD is not the sealed sha — RED, checks never run, evidence preserved.
      is_binary(head_before) and head_before != sealed_head ->
        tampered_refusal(
          "head_moved",
          "HEAD does not match the sealed head: #{sealed_head} -> #{head_before}",
          head_before,
          :sealed,
          sealed_head
        )

      # HEAD-integrity invariant (camus run-6 + C1-2 audit hardening): a gating
      # verify certifies the COMMITTED state — tracked dirt or a nonignored
      # untracked path before the checks is RED `uncommitted_state`, never
      # inconclusive, and the checks never run (nothing was verified).
      is_binary(before_porcelain) and String.trim(before_porcelain) != "" ->
        tampered_refusal(
          "uncommitted_state",
          bounded_porcelain(before_porcelain),
          head_before,
          :sealed,
          sealed_head
        )

      checks == [] ->
        %{
          refusal_result("no_verifier_detected", @remedy_no_verifier, sealed_head: sealed_head)
          | integrity_note: capture_note(before_porcelain, head_before, :sealed)
        }

      true ->
        run_sealed_checks(
          checks,
          runner,
          repo,
          sealed_head,
          seams,
          {before_porcelain, head_before}
        )
    end
  end

  defp run_sealed_checks(
         checks,
         runner,
         repo,
         sealed_head,
         seams,
         {before_porcelain, head_before}
       ) do
    {ran, failures} = run_checks(checks, runner, repo)

    after_porcelain = seams.porcelain.(repo)
    head_after = seams.head.(repo)

    integrity_failures =
      List.flatten([
        working_tree_mutation_failure(before_porcelain, after_porcelain, &bounded_porcelain/1),
        head_moved_failure(head_before, head_after),
        sealed_mismatch_failure(sealed_head, head_after)
      ])

    # A sealed PASS must have asserted the whole invariant: both porcelain
    # snapshots and the after-HEAD captured. `head_before` is deliberately not
    # required — the sealed compare above already refused a readable mismatch,
    # and an unreadable before-head still leaves the after-head + porcelain
    # pair asserting what the green certified.
    captured? =
      is_binary(before_porcelain) and is_binary(after_porcelain) and is_binary(head_after)

    assemble(
      ran,
      failures ++ integrity_failures,
      head_after,
      nil,
      :sealed,
      sealed_head,
      captured?,
      capture_note(after_porcelain, head_after, :sealed)
    )
  end

  defp sealed_mismatch_failure(sealed_head, head_after)
       when is_binary(head_after) and head_after != sealed_head do
    [
      failure(
        "integrity",
        "head_moved",
        "HEAD does not match the sealed head after verify: #{sealed_head} -> #{head_after}",
        nil,
        nil
      )
    ]
  end

  defp sealed_mismatch_failure(_sealed_head, _head_after), do: []

  # ---------------------------------------------------------------------------
  # Working-tree mode (our divergence for non-committing routes)
  # ---------------------------------------------------------------------------

  defp working_tree_result(checks, runner, repo, seams) do
    before_porcelain = seams.porcelain.(repo)
    head_before = seams.head.(repo)
    digest_before = seams.diff_digest.(repo)

    if checks == [] do
      %{
        refusal_result("no_verifier_detected", @remedy_no_verifier)
        | integrity_note: dirty_before_note(before_porcelain)
      }
    else
      {ran, failures} = run_checks(checks, runner, repo)

      head_after = seams.head.(repo)
      digest_after = seams.diff_digest.(repo)

      integrity_failures =
        List.flatten([
          head_moved_failure(head_before, head_after),
          digest_mutation_failure(digest_before, digest_after)
        ])

      # A working-tree PASS binds {head, tree_digest} — both captures (before
      # AND after: a nil before-capture means mid-verify stability was never
      # asserted) are load-bearing; the porcelain dirty-before FACT is not.
      captured? =
        is_binary(head_before) and is_binary(head_after) and
          is_binary(digest_before) and is_binary(digest_after)

      assemble(
        ran,
        failures ++ integrity_failures,
        head_after,
        digest_after,
        :working_tree,
        nil,
        captured?,
        working_tree_note(before_porcelain, head_after, digest_after)
      )
    end
  end

  # The dirty-before FACT (never a failure in working-tree mode): the green
  # certifies the working tree as-is, so the reader must know it was dirty.
  defp dirty_before_note(porcelain) when is_binary(porcelain) do
    case String.trim(porcelain) do
      "" ->
        nil

      dirt ->
        "working tree dirty against HEAD before verify (#{length(String.split(dirt, "\n"))} " <>
          "paths); the verdict certifies the working tree, not the commit"
    end
  end

  defp dirty_before_note(_porcelain), do: "dirty-before snapshot unavailable (git errored)"

  defp working_tree_note(before_porcelain, head_after, digest_after) do
    notes =
      Enum.reject(
        [
          dirty_before_note(before_porcelain),
          if(is_nil(head_after) or is_nil(digest_after),
            do: "integrity capture unavailable (HEAD or tree digest unreadable); not asserted"
          )
        ],
        &is_nil/1
      )

    case notes do
      [] -> nil
      notes -> Enum.join(notes, "; ")
    end
  end

  defp capture_note(porcelain, head, :sealed) do
    if is_nil(porcelain) or is_nil(head) do
      "integrity capture unavailable (git porcelain or HEAD unreadable); not asserted"
    end
  end

  defp digest_mutation_failure(digest_before, digest_after)
       when is_binary(digest_before) and is_binary(digest_after) and
              digest_before != digest_after do
    [
      failure(
        "integrity",
        "working_tree_mutation",
        "working-tree content changed during verify (tree digest #{digest_before} -> #{digest_after})",
        nil,
        nil
      )
    ]
  end

  defp digest_mutation_failure(_digest_before, _digest_after), do: []

  # ---------------------------------------------------------------------------
  # Shared assembly
  # ---------------------------------------------------------------------------

  defp run_checks(checks, runner, repo) do
    {ran, failures} =
      Enum.reduce(checks, {[], []}, fn check, {ran, failures} ->
        {exit, tail} = runner.(check, repo)
        entry = %{name: check.name, cmd: check.cmd, exit: exit_value(exit)}

        case exit do
          0 ->
            {[entry | ran], failures}

          _nonzero ->
            kind = classify_failure(check, exit, tail)
            {[entry | ran], [failure(check.name, kind, tail, exit_value(exit), nil) | failures]}
        end
      end)

    {Enum.reverse(ran), Enum.reverse(failures)}
  end

  defp exit_value(exit) when is_integer(exit), do: exit
  defp exit_value(_sentinel), do: nil

  defp working_tree_mutation_failure(before_porcelain, after_porcelain, bound)
       when is_binary(before_porcelain) and is_binary(after_porcelain) and
              before_porcelain != after_porcelain do
    [failure("integrity", "working_tree_mutation", bound.(after_porcelain), nil, nil)]
  end

  defp working_tree_mutation_failure(_before, _after, _bound), do: []

  defp head_moved_failure(head_before, head_after)
       when is_binary(head_before) and is_binary(head_after) and head_before != head_after do
    [
      failure(
        "integrity",
        "head_moved",
        "HEAD moved during verify: #{head_before} -> #{head_after}",
        nil,
        nil
      )
    ]
  end

  defp head_moved_failure(_before, _after), do: []

  defp assemble(ran, failures, head, tree_digest, mode, sealed_head, captured?, note) do
    would_pass? = failures == []

    failures =
      if would_pass? and not captured? do
        # Law-4 override of camus's degrade-open: a green that cannot name what
        # state it certified is INCONCLUSIVE, never a pass.
        [
          failure(
            "integrity",
            "integrity_unavailable",
            "integrity capture failed (git unreadable); a green cannot certify unnamed state — " <>
              "fix git availability in the project dir and re-run",
            nil,
            nil
          )
        ]
      else
        failures
      end

    passed = failures == []

    # One pass over the failures: tampered = any integrity-RED kind;
    # inconclusive = failing AND every kind withheld a verdict (camus rule —
    # the integrity kinds are not inconclusive, so tampering forces a real red
    # even when every check was itself inconclusive).
    {tampered, all_inconclusive} =
      Enum.reduce(failures, {false, true}, fn %{kind: kind}, {tampered, all_inconclusive} ->
        {tampered or kind in ["uncommitted_state", "working_tree_mutation", "head_moved"],
         all_inconclusive and kind in @inconclusive_kinds}
      end)

    inconclusive = not passed and all_inconclusive

    %Envelope{
      pass: passed,
      inconclusive: inconclusive,
      tampered: tampered,
      failures: failures,
      checks: ran,
      head: head,
      integrity_note: note,
      mode: mode,
      tree_digest: tree_digest,
      sealed_head: sealed_head
    }
  end

  defp tampered_refusal(kind, log_tail, head, mode, sealed_head) do
    %Envelope{
      pass: false,
      inconclusive: false,
      tampered: true,
      failures: [failure("integrity", kind, log_tail, nil, nil)],
      # The checks never ran — nothing was verified.
      checks: [],
      head: head,
      integrity_note: nil,
      mode: mode,
      tree_digest: nil,
      sealed_head: sealed_head
    }
  end

  defp bounded_porcelain(porcelain) do
    porcelain
    |> String.trim_trailing("\n")
    |> String.slice(0, 400)
  end

  # ---------------------------------------------------------------------------
  # Failure classification (camus table + mix adaptations)
  # ---------------------------------------------------------------------------

  # Kind for one nonzero exit. Misclassification policy: err toward
  # inconclusive (a withheld verdict) — never toward a false red, never a pass.
  defp classify_failure(_check, :output_limit, _tail), do: "output_limit"

  # command not found -> the check couldn't RUN (toolchain/deps missing).
  defp classify_failure(_check, 127, _tail), do: "missing_tool"

  # The runner's timeout sentinel: a budget statement, not a code verdict.
  defp classify_failure(_check, 124, _tail), do: "timeout"

  defp classify_failure(check, exit, tail) do
    tail = tail || ""
    cmd = Enum.map(check.cmd, &to_string/1)

    cond do
      # pytest exit 5 = "no tests collected": nothing ran, so nothing failed.
      exit == 5 and pytest?(cmd) ->
        "no_tests"

      # An ENVIRONMENT statement (system python in an env-managed repo), never
      # a code verdict — camus-verbatim.
      String.contains?(tail, "No module named") ->
        "missing_tool"

      # Mix adaptation: `mix precommit` in a repo without the alias exits 1
      # with `** (Mix) The task "precommit" could not be found` — the mix
      # equivalent of the npx/exec-runner env lane, scoped to a mix argv so a
      # real test failure that merely prints "could not be found" stays red.
      List.first(cmd) == "mix" and String.contains?(tail, "The task") and
          String.contains?(tail, "could not be found") ->
        "missing_tool"

      # `npx --no-install tsc` exits 1 (not 127) when the tool isn't installed;
      # pnpm/yarn exec print `Command "x" not found` — camus-verbatim, scoped
      # to exec-runner argv.
      exec_runner?(cmd) and
          Enum.any?(["could not determine executable", "not found"], &String.contains?(tail, &1)) ->
        "missing_tool"

      true ->
        "failed"
    end
  end

  defp pytest?(cmd), do: String.contains?(Enum.join(cmd, " "), "pytest")

  defp exec_runner?(cmd) do
    List.first(cmd) in ["npx", "bunx"] or Enum.at(cmd, 1) == "exec"
  end
end
