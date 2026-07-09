defmodule JidoClaw.Security.ShellCommandTest do
  @moduledoc """
  Pure unit suite for the shell-aware `run_command` approval analyzer. Covers the
  grammar/tokenizer, redirect metadata, separators, command-word resolution, the
  honest **effect** model (resolved commit vs git opacity vs config injection vs
  persistent config write), the deliberate `git config` key-resolution grammar,
  the `opaque?` fail-closed floor and its invariant, compound/control forms,
  interpreter recursion, suspicious structure, the documented pass-through
  residuals, and the DoS bounds.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Security.ShellCommand, as: SC
  alias JidoClaw.Security.ShellCommand.{Analysis, Command}

  @kinds [:command_substitution, :backtick, :pipe_to_shell]

  # `command_present?/3` returns true on `opaque?`, so `git?`/`cron?` fold in the
  # fail-closed floor — exactly how the gate consumes them. `git?` calls the
  # `command_present?(_, "git", subcommand: "commit")` shim directly (the gate's
  # git floor: :git_commit | :git_config_injection | :git_config_persistent_write
  # | opaque?), so the unit helper exercises the same path the wrapper does.
  defp git?(cmd), do: SC.command_present?(SC.analyze(cmd), "git", subcommand: "commit")
  defp cron?(cmd), do: SC.command_present?(SC.analyze(cmd), "crontab", [])
  defp struct?(cmd, kinds \\ @kinds), do: SC.structure_present?(SC.analyze(cmd), kinds)
  defp opaque?(cmd), do: SC.analyze(cmd).opaque?
  defp gated?(cmd), do: git?(cmd) or cron?(cmd) or struct?(cmd)

  defp effects(cmd), do: SC.analyze(cmd).effects
  defp has_effect?(cmd, kind), do: SC.has_effect?(SC.analyze(cmd), kind)

  defp assert_effect(cmd, kind) do
    assert has_effect?(cmd, kind),
           "expected #{inspect(cmd)} to carry effect #{inspect(kind)}, got #{inspect(effects(cmd))}"
  end

  defp refute_effect(cmd, kind) do
    refute has_effect?(cmd, kind),
           "expected #{inspect(cmd)} NOT to carry effect #{inspect(kind)}, got #{inspect(effects(cmd))}"
  end

  defp assert_opaque(cmd, opts) do
    scope = Keyword.fetch!(opts, :scope)
    reason = Keyword.fetch!(opts, :reason)

    assert Enum.any?(effects(cmd), &match?({:opaque, %{scope: ^scope, reason: ^reason}}, &1)),
           "expected #{inspect(cmd)} opaque {scope: #{inspect(scope)}, reason: #{inspect(reason)}}, " <>
             "got #{inspect(effects(cmd))}"
  end

  describe "grammar / tokenizer" do
    test "quoting concatenates a quoted arg as one word" do
      assert %Analysis{commands: [%Command{cmd: "git", args: ["-C", "my dir", "commit"]}]} =
               SC.analyze(~s(git -C "my dir" commit))
    end

    test "adjacent quoted and bare runs concatenate into one word" do
      assert %Analysis{commands: [%Command{cmd: "-Cmy dir", args: []}]} =
               SC.analyze(~s(-C"my dir"))

      assert %Analysis{commands: [%Command{cmd: "abc", args: []}]} = SC.analyze(~s('a'"b"c))
    end

    test "escapes are literal, not operators or word boundaries" do
      # `git\ commit` is one literal command word (a space-bearing name), NOT the
      # `git` command with a `commit` subcommand.
      assert %Analysis{commands: [%Command{cmd: "git commit", args: []}]} =
               SC.analyze("git\\ commit")

      refute git?("git\\ commit")
      assert %Analysis{commands: [%Command{cmd: "a&&b", args: []}]} = SC.analyze("a\\&\\&b")
    end

    test "an unterminated quote is best-effort, never raises" do
      assert %Analysis{
               commands: [%Command{cmd: "git", args: ["commit", "-m", "hi"]}],
               opaque?: false
             } =
               SC.analyze(~s(git commit -m "hi))
    end

    test "empty, whitespace-only, and operators-only inputs yield no commands" do
      for input <- ["", "   ", "\t \n ", "&&", "; ;", "| |"] do
        assert match?(%Analysis{commands: [], structure: [], opaque?: false}, SC.analyze(input)),
               "expected #{inspect(input)} to yield no commands"
      end
    end

    test "comments are recognized at word-start only" do
      # Whole-line and trailing comments contribute no command word.
      refute git?("# git commit")
      refute git?("echo x # git commit")
      # A trailing comment suppresses a following separator+command on the line.
      refute git?("echo x # noop ; git commit")
      # Mid-word `#` and quoted `#` are NOT comments.
      assert %Analysis{commands: [%Command{cmd: "git#x"}]} = SC.analyze("git#x")

      assert %Analysis{commands: [%Command{cmd: "echo", args: ["#x"]}]} =
               SC.analyze(~s(echo "#x"))
    end

    test "a backslash-newline line continuation splices into one command" do
      assert git?("git \\\n commit")

      assert %Analysis{commands: [%Command{cmd: "git", args: ["commit"]}]} =
               SC.analyze("git \\\ncommit")
    end
  end

  describe "redirect metadata (still resolves to git commit)" do
    test "leading redirects of every shape leave the command word intact" do
      for cmd <- [
            "2>&1 git commit",
            "2>/dev/null git commit",
            "2> /dev/null git commit",
            ">out git commit",
            ">&2 git commit"
          ] do
        assert %Analysis{commands: [%Command{cmd: "git", args: args}]} = SC.analyze(cmd)
        assert "commit" in args, "expected #{inspect(cmd)} to resolve to git commit"
      end
    end

    test "a trailing redirect fused to an arg still exposes the subcommand" do
      assert git?("git commit>out")
    end

    test "a redirect target is not mistaken for the subcommand (redirect-aware args)" do
      # `> out` drops the target word `out`, so the real subcommand `commit`
      # still resolves regardless of the redirect's position.
      assert git?("git > out commit")
      assert git?("git commit > out")
    end
  end

  describe "separators" do
    test "every separator exposes a following git commit" do
      for cmd <- [
            "a && git commit",
            "a || git commit",
            "a | git commit",
            "git commit &",
            "a; git commit",
            "echo x\ngit commit"
          ] do
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end
  end

  describe "command-word resolution" do
    test "path-prefixed commands resolve by basename" do
      assert git?("/usr/bin/git commit")
    end

    test "env-assignment prefixes are transparent" do
      assert git?("FOO=bar git commit")
      assert git?("A=1 B=2 git commit")
      assert git?("FOO=$BAR git commit")
    end

    test "wrapper words and their value-taking flags are transparent" do
      for cmd <- [
            "sudo git commit",
            "env git commit",
            "nohup git commit",
            "nice git commit",
            "sudo -u user git commit",
            "nice -n 10 git commit",
            "timeout 5 git commit",
            "env -i git commit",
            "env FOO=bar git commit",
            "sudo -- git commit",
            "sudo nice git commit"
          ] do
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end
  end

  describe "fail-closed (opaque? → gate, never pass-through)" do
    test "recursion depth beyond the bound is opaque" do
      deep = Enum.reduce(1..5, "git commit", fn _i, acc -> "sh -c " <> inspect(acc) end)
      assert opaque?(deep)
      # ...while a chain within the bound resolves the inner git commit cleanly.
      within = Enum.reduce(1..3, "git commit", fn _i, acc -> "sh -c " <> inspect(acc) end)
      assert git?(within)
      refute opaque?(within)
    end

    test "the sub-command count cap is opaque" do
      refute opaque?(String.duplicate("a;", 200))
      assert opaque?(String.duplicate("a;", 300))
    end

    test "over-length input is opaque without parsing" do
      assert opaque?(String.duplicate("x", 70_000))
    end

    test "an unrecognized wrapper flag is opaque" do
      assert opaque?("sudo -X git commit")
      assert opaque?(~s(env -S "git commit"))
    end

    test "here-docs and here-strings feeding a command are opaque" do
      assert opaque?("sh <<EOF\ngit commit\nEOF")
      # Acceptable false positive on a benign cat.
      assert opaque?("cat <<EOF\nhello\nEOF")
      assert opaque?(~s(cat <<< "git commit"))
    end

    test "a parameter-expansion command word is opaque" do
      for cmd <- ["$GIT commit", "git${IFS}commit", "$x commit"] do
        assert opaque?(cmd), "expected #{inspect(cmd)} to be opaque"
      end
    end

    test "the opaque floor makes command_present? gate regardless" do
      analysis = SC.analyze("$GIT commit")
      assert SC.command_present?(analysis, "git", subcommand: "commit")
      assert SC.command_present?(analysis, "crontab", [])
    end
  end

  describe "compound / control (must gate via descent or opacity)" do
    test "control structures, groups, and visible functions gate" do
      for cmd <- [
            "if true; then git commit; fi",
            "(git commit)",
            "{ git commit; }",
            "f(){ git commit; }; f",
            "for x in a; do git commit; done",
            "case x in y) git commit;; esac",
            "! git commit"
          ] do
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end
  end

  describe "interpreter / eval recursion" do
    test "shells with a -c script (every trigger shape) resolve the inner command" do
      for cmd <- [
            ~s(sh -c "git commit"),
            "bash -lc 'git commit'",
            ~s(sh -c"git commit"),
            ~s(bash -o pipefail -c "git commit"),
            ~s(eval "git commit"),
            "eval git commit"
          ] do
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end

    test "a dynamic -c / eval script target is opaque (fail closed, scope :interpreter)" do
      # The recursion would run on `""` (the dynamic content collapses to empty
      # text) and miss the real command — so it fails closed to :opaque instead.
      for cmd <- [
            ~s(sh -c "$cmd"),
            ~s(bash -c "$x"),
            ~s(sh -c"$cmd"),
            ~s(eval "$cmd"),
            ~s(sh -c "git status $x"),
            ~s(cmd="git commit"; sh -c "$cmd")
          ] do
        assert opaque?(cmd), "expected #{inspect(cmd)} to be opaque"
        assert_opaque(cmd, scope: :interpreter, reason: :dynamic_interpreter)
      end
    end
  end

  describe "command-runner floor (S-M1)" do
    test "a runner wrapping a gated root or shell gates (literal reach)" do
      for cmd <- [
            "echo . | xargs git commit -m x",
            "ssh host git commit",
            "su -c 'git commit'",
            "flock /tmp/lock git commit",
            "strace git commit",
            "xargs crontab -",
            "parallel bash ::: x"
          ] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :runner, reason: :command_runner)
      end
    end

    test "a single-argv-word runner template still exposes the gated root (quoting fix)" do
      # `parallel 'git commit' ::: x` / `ssh host "git commit"` pass the template
      # as ONE argv word — split on whitespace before the gated-root match.
      for cmd <- ["parallel 'git commit' ::: x", ~s(ssh host "git commit")] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :runner, reason: :command_runner)
      end
    end

    test "find gates on any -exec-family predicate" do
      for cmd <- [
            "find . -exec git commit ;",
            "find . -execdir crontab - ;",
            "find . -ok rm {} ;",
            "find . -okdir sh -c x ;"
          ] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :runner, reason: :find_exec)
      end
    end

    test "a runner or find with a dynamic arg fails closed" do
      for cmd <- ["xargs $cmd", ~s(find . "$predicate")] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :runner, reason: :dynamic_runner)
      end
    end

    test "a runner reaching git gates even on a non-commit sub-command (documented FP)" do
      # `watch git status` re-runs a git command; the floor gates ANY git reach,
      # so this is a conscious false positive (asks for approval, never silent).
      assert gated?("watch git status")
      assert_opaque("watch git status", scope: :runner, reason: :command_runner)
    end

    test "a runner not reaching a gated root, and a literal find, pass through" do
      for cmd <- ["xargs ls", "ssh host ls", "find . -name git", "find . -type f"] do
        refute gated?(cmd), "expected #{inspect(cmd)} to pass through"
        refute opaque?(cmd)
      end
    end
  end

  describe "interpreter one-liner + stdin floor (S-M1)" do
    test "an interpreter eval one-liner (every trigger shape) gates" do
      for cmd <- [
            ~s(python -c "x"),
            "python3 -c 'x'",
            ~s(node -e "x"),
            ~s(node -p "x"),
            "node --eval=x",
            ~s(perl -e "x"),
            "perl -E'x'",
            "ruby -e 'x'",
            "ruby -r lib",
            ~s(deno eval "x"),
            ~s(bun -e "x"),
            "php -r 'x'"
          ] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :interpreter, reason: :interpreter_eval)
      end
    end

    test "a piped / stdin interpreter (no script-file arg) gates" do
      for cmd <- ["echo code | python", "printf 'x' | python", "cat x | python -", "python -"] do
        assert gated?(cmd), "expected #{inspect(cmd)} to gate"
        assert_opaque(cmd, scope: :interpreter, reason: :stdin_interpreter)
      end
    end

    test "an interpreter with a dynamic argv token fails closed" do
      assert gated?(~s(python "$x"))
      assert_opaque(~s(python "$x"), scope: :interpreter, reason: :dynamic_interpreter_arg)
    end

    test "an interpreter script-file invocation (even piped) passes through — residual" do
      for cmd <- ["python foo.py", "cat data | python foo.py", "node app.js", "ruby script.rb"] do
        refute gated?(cmd), "expected #{inspect(cmd)} to pass through"
        refute opaque?(cmd)
      end
    end
  end

  describe "git effects: resolved commit (:git_commit, honest)" do
    test "an inline alias / global-flag form resolving to commit IS a :git_commit" do
      for cmd <- [
            "git commit -m x",
            "git -c alias.ci=commit ci",
            ~s(git -c alias.x='commit -a' x),
            "git -c alias.ci=co -c alias.co=commit ci",
            ~s(git -c alias.ci='-c user.name=x commit' ci),
            "git -c user.name=x commit",
            "git --git-dir=.git commit",
            "git -C repo commit"
          ] do
        assert_effect(cmd, :git_commit)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end

    test "an alias resolving to a benign sub-command is NOT a commit and passes" do
      for cmd <- [
            "git -c alias.ci=status ci",
            "git -c alias.ci=st -c alias.st=status ci --short",
            ~s(git -c alias.ci='-c user.name=x status' ci --short)
          ] do
        refute_effect(cmd, :git_commit)
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end
  end

  describe "git effects: resolved push (:git_push, honest)" do
    test "every shell dressing of a resolved push carries :git_push (no opacity)" do
      for cmd <- [
            "git push",
            "git push origin main",
            ~s(git push origin "$branch"),
            ~s(git -C "my dir" push),
            "FOO=bar git push",
            "sudo git push",
            "/usr/bin/git push",
            ~s(sh -c "git push"),
            "bash -lc 'git push'",
            "echo x\ngit push",
            "git push &",
            "git -c alias.p=push p",
            "git > out push"
          ] do
        assert_effect(cmd, :git_push)
        refute opaque?(cmd), "expected #{inspect(cmd)} to gate via :git_push, not opacity"
      end
    end

    test "push-adjacent benign forms carry no :git_push" do
      for cmd <- [
            "git log && echo push",
            ~s(echo "git push"),
            "git -c alias.p=status p",
            ~s(git fetch origin "$branch")
          ] do
        refute_effect(cmd, :git_push)
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end

    test "a !-shell alias to push stays opaque, never a resolved :git_push" do
      cmd = ~s(git -c alias.p='!git push' p)
      assert_opaque(cmd, scope: :git, reason: :shell_alias)
      refute_effect(cmd, :git_push)
    end
  end

  describe "git effects: opacity (:opaque scope :git, never a false :git_commit)" do
    test "git-resolution uncertainty is honest opacity, not a commit" do
      for {cmd, reason} <- [
            {"git --frobnicate commit", :unknown_flag},
            {"git $x", :dynamic_subcommand},
            {"git -c alias.ci=co -c alias.co=ci ci", :alias_cycle},
            {~s(git -c alias.x='!git commit' x), :shell_alias}
          ] do
        assert_opaque(cmd, scope: :git, reason: reason)
        refute_effect(cmd, :git_commit)
        assert git?(cmd), "expected #{inspect(cmd)} to gate (via the opaque floor)"
      end
    end

    test "every dynamic-sub-command dressing resolves to a dynamic_subcommand opacity" do
      for cmd <- ["git $x", "x=commit; git $x", ~s(git -C "$d" $x), ~s(git -C "my dir" $x)] do
        assert_opaque(cmd, scope: :git, reason: :dynamic_subcommand)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end
  end

  describe "git effects: config injection (:git_config_injection)" do
    test "a visible GIT_CONFIG_* env mutation injects config into any git command" do
      # Each form injects config (e.g. `alias.ci=commit`) into git's environment —
      # leading/env-wrapper assignment, or a prior shell-state mutation
      # (export/set -a/standalone, incl. inside an sh -c) that persists to a later
      # git. All parse cleanly, so they gate via the injection effect, not opacity.
      for cmd <- [
            "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci",
            "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci",
            "env -i GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit git ci",
            "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit; git ci",
            "set -a; GIT_CONFIG_COUNT=1; GIT_CONFIG_KEY_0=alias.ci; GIT_CONFIG_VALUE_0=commit; git ci",
            "GIT_CONFIG_COUNT=1; git ci",
            ~s(sh -c "export GIT_CONFIG_COUNT=1; git ci"),
            ~s(GIT_CONFIG_PARAMETERS='alias.ci=commit' git ci),
            "GIT_CONFIG_GLOBAL=/tmp/evil git status",
            "GIT_CONFIG_COUNT=$n git ci"
          ] do
        assert_effect(cmd, :git_config_injection)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end

    test "inline -c include / --config-env / dynamic-c are config injection" do
      for cmd <- [
            "git -c include.path=/path/to/config ci",
            "git -c includeIf.gitdir:/x/.path=/p ci",
            "git -c include.path=/p commit",
            "git --config-env=include.path=VAR ci",
            ~s(git -c "$cfg" ci)
          ] do
        assert_effect(cmd, :git_config_injection)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
        refute opaque?(cmd), "expected #{inspect(cmd)} to gate via injection, not opacity"
      end
    end

    test "GIT_CONFIG-shaped tokens with no git command, and a non-include -c, pass through" do
      for cmd <- [
            "echo GIT_CONFIG_COUNT=1",
            "export GIT_CONFIG_COUNT=1",
            "GIT_AUTHOR_NAME=x git status",
            "FOO=bar git status",
            "git -c core.pager=less status",
            "git -c user.name=x status"
          ] do
        refute_effect(cmd, :git_config_injection)
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end
  end

  describe "git effects: persistent config write (:git_config_persistent_write)" do
    test "a git config alias.*/include.* write plants config and gates (persists)" do
      # `git config` WRITES config a later git honors and that persists to
      # .git/config across run_command calls, so an alias/include write gates even
      # with no later git in the same string (a benign value like `alias.x status`
      # still gates — it is an alias write); option-bearing forms and sh -c
      # recursion are covered too.
      for cmd <- [
            "git config alias.ci commit; git ci",
            "git config alias.ci '!git commit'; git ci",
            "git config include.path /tmp/evil; git ci",
            "git config alias.ci commit",
            "git config alias.ci status",
            "git config --global alias.ci commit",
            "git config set alias.ci commit",
            "git --no-pager config alias.ci commit",
            "git config includeIf.gitdir:/x/.path /p",
            ~s(sh -c "git config alias.ci commit; git ci")
          ] do
        assert_effect(cmd, :git_config_persistent_write)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
      end
    end

    test "an ordinary git config write to a non-risky key passes through" do
      for cmd <- [
            "git config user.name x",
            "git config core.pager less",
            "git config --get remote.origin.url",
            "git -C config status"
          ] do
        refute_effect(cmd, :git_config_persistent_write)
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end
  end

  describe "git config grammar (deliberate key resolution)" do
    test "dynamic-key, section-mutation, and edit forms gate as persistent writes" do
      # The closed bug: a dynamic key collapses to empty text, so the old
      # position-independent literal `alias.*` scan missed `git config "$key"
      # commit`. The deliberate grammar fails closed on a dynamic key, gates a
      # rename into a risky section, and gates the editor mutation surface.
      for cmd <- [
            ~s(git config "$key" commit),
            ~s(git config set "$key" commit),
            ~s(git config set --global "$key" commit),
            "git config set --file .git/config alias.ci commit",
            "git config rename-section foo alias",
            "git config rename-section --file .git/config foo alias",
            "git config --rename-section foo include",
            "git config edit",
            "git config -e",
            "git config --edit",
            ~s(K=alias.ci; git config "$K" commit; git ci)
          ] do
        assert_effect(cmd, :git_config_persistent_write)
        assert git?(cmd), "expected #{inspect(cmd)} to gate"
        refute opaque?(cmd), "expected #{inspect(cmd)} to gate via the write effect, not opacity"
      end
    end

    test "reads, removals, and a benign dynamic-value write pass through" do
      # Reads/removals cannot plant config a later git honors, so they are
      # intentionally allowed; a write whose KEY is literal-benign never inspects
      # its (dynamic) value.
      for cmd <- [
            ~s(git config user.name "$val"),
            "git config --get alias.x",
            "git config get user.name",
            "git config unset alias.x",
            "git config remove-section alias",
            "git config --list"
          ] do
        refute_effect(cmd, :git_config_persistent_write)
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end
  end

  describe "invariants" do
    test "opaque? holds iff an {:opaque, _} effect is present" do
      opaque_fixtures = [
        # parse-scope
        "$GIT commit",
        "git${IFS}commit",
        "sudo -X git commit",
        "sh <<EOF\ngit commit\nEOF",
        String.duplicate("a;", 300),
        String.duplicate("x", 70_000),
        # interpreter-scope
        ~s(sh -c "$cmd"),
        ~s(eval "$cmd"),
        # git-scope
        "git --frobnicate commit",
        "git $x"
      ]

      for cmd <- opaque_fixtures do
        analysis = SC.analyze(cmd)
        assert analysis.opaque?, "expected #{inspect(cmd)} opaque?"

        assert Enum.any?(analysis.effects, &match?({:opaque, _}, &1)),
               "expected #{inspect(cmd)} to carry an {:opaque, _} effect"
      end

      non_opaque = ["git commit", "git status", "echo hi", "git config alias.ci commit", ""]

      for cmd <- non_opaque do
        analysis = SC.analyze(cmd)
        refute analysis.opaque?, "expected #{inspect(cmd)} NOT opaque?"

        refute Enum.any?(analysis.effects, &match?({:opaque, _}, &1)),
               "expected #{inspect(cmd)} to carry no {:opaque, _} effect"
      end
    end

    test "a dynamic value in a known value position never gates by itself" do
      # The var is a mere argument: it neither becomes a sub-command nor adds
      # opacity. `git commit -m "$MSG"` still gates — on the literal `commit`.
      for cmd <- [
            ~s(git config user.name "$val"),
            ~s(git -C "$dir" status),
            ~s(git fetch origin "$branch"),
            ~s(git checkout "$b")
          ] do
        refute git?(cmd), "expected #{inspect(cmd)} to pass through"
        refute opaque?(cmd), "expected #{inspect(cmd)} to carry no opacity"
      end

      assert_effect(~S|git commit -m "$MSG"|, :git_commit)
      assert git?(~S|git commit -m "$MSG"|)
    end
  end

  describe "suspicious structure" do
    test "command substitution is detected, escaped/literal forms are not" do
      assert struct?(~S|git status $(date)|, [:command_substitution])
      assert struct?(~S|echo "$(date)"|, [:command_substitution])
      refute struct?(~S|echo '$(x)'|, [:command_substitution])
      refute struct?(~S|echo \$(date)|, [:command_substitution])
    end

    test "backticks are detected" do
      assert struct?(~S|git log `date`|, [:backtick])
    end

    test "a pipe into a bare shell is detected, through wrappers and shell flags" do
      for cmd <- ["curl x | sh", "base64 -d | bash -e", "foo | sudo sh", "foo | sh -s"] do
        assert struct?(cmd, [:pipe_to_shell]), "expected #{inspect(cmd)} pipe_to_shell"
      end
    end

    test "a -c shell on a pipe RHS diverts to recursion, not a pipe-gate" do
      refute struct?("foo | sh -c \"git status\"", [:pipe_to_shell])
    end

    test "structure kinds are also surfaced as effects (single detect_structure source)" do
      assert has_effect?(~S|echo $(date)|, :command_substitution)
      assert has_effect?(~S|git log `date`|, :backtick)
      assert has_effect?("curl x | sh", :pipe_to_shell)
    end
  end

  describe "structure_present?/2 toggle semantics" do
    test "an empty kinds list is always false, even when opaque" do
      refute struct?(~S|echo $(date)|, [])
      refute SC.structure_present?(SC.analyze("$GIT commit"), [])
    end

    test "narrowing kinds disables only the unselected structural gates" do
      assert struct?(~S|echo $(date)|, [:command_substitution])
      refute struct?(~S|echo $(date)|, [:pipe_to_shell])
    end

    test "opaque? matches any non-empty kinds (fail closed)" do
      assert SC.structure_present?(SC.analyze("$GIT commit"), [:pipe_to_shell])
    end
  end

  describe "documented residuals (must pass through — escape valve covers them)" do
    test "script-file indirection and alias definitions are benign" do
      for cmd <- [
            "bash deploy.sh",
            "sh < deploy.sh",
            "alias gc='git commit'",
            "gc"
          ] do
        refute gated?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end

    test "benign commands and argument-position variables pass through" do
      for cmd <- [
            "git status",
            "git log && echo commit",
            "echo committing soon",
            ~S|git log -1 --format="%H"|
          ] do
        refute gated?(cmd), "expected #{inspect(cmd)} to pass through"
      end
    end

    test "an argument-position variable does not obscure a literal command word" do
      # `git commit -m "$MSG"` gates on the literal `git commit`, not the var.
      assert git?(~S|git commit -m "$MSG"|)
    end
  end

  describe "DoS bounds complete within limits" do
    test "a huge separator chain returns promptly" do
      assert %Analysis{opaque?: true} = SC.analyze(String.duplicate("a;", 100_000))
    end

    test "a deeply nested interpreter chain returns promptly" do
      deep = Enum.reduce(1..50, "git commit", fn _i, acc -> "sh -c " <> inspect(acc) end)
      assert %Analysis{} = SC.analyze(deep)
    end
  end

  # ---------------------------------------------------------------------------
  # Exit-code provenance (OB1-3 — PORT-OB1-3.md; source tests cited per row)
  # ---------------------------------------------------------------------------

  defp prov(cmd), do: SC.exit_code_provenance(cmd)

  describe "exit_code_provenance/1: preserved" do
    # {command, expected_runner_tool_or_nil}
    @preserved [
      {"mix test", "mix test"},
      {"cd /app && FOO=1 mix test", "mix test"},
      {"sudo mix test", "mix test"},
      {"mix test > out.log 2>&1", "mix test"},
      {"pytest tests/unit -x", "pytest"},
      {"py.test tests/", "py.test"},
      {"tox", "tox"},
      {"npm test", "npm test"},
      {"pnpm test", "pnpm test"},
      {"yarn test", "yarn test"},
      {"uv run pytest", "uv run pytest"},
      {"python -m pytest tests/", "python -m pytest"},
      {"python -m unittest discover", "python -m unittest"},
      {"mix compile --warnings-as-errors", nil},
      {"ls -la", nil},
      # `npm run test` is deliberately NOT the runner table's `npm test`.
      {"npm run test", nil},
      # General `;`-chain shadowing is out of scope — a documented miss,
      # conservatively :preserved (decision 6).
      {"mix test ; echo done", "mix test"},
      # `&&`-chained `true` does not swallow (a failure short-circuits it).
      {"mix test && true", "mix test"}
    ]

    test "clean invocations preserve their exit code" do
      for {cmd, tool} <- @preserved do
        provenance = prov(cmd)

        assert provenance.exit_code == :preserved,
               "expected #{inspect(cmd)} :preserved, got #{inspect(provenance)}"

        case tool do
          nil ->
            assert provenance.test_runner == nil,
                   "expected #{inspect(cmd)} to carry no runner, got #{inspect(provenance)}"

          tool ->
            assert %{tool: ^tool, skipped?: false} = provenance.test_runner
        end
      end
    end

    # Source: test_test_invocation_supports_shell_preamble_with_pipefail_output_plumbing
    # (test_parallel_executor.py:1598 @ e905a41c).
    test "pipefail before the filter pipeline protects it" do
      assert prov("set -o pipefail && mix test | tail -5").exit_code == :preserved
      assert prov("set -o pipefail; mix test 2>&1 | tail -20").exit_code == :preserved
    end
  end

  describe "exit_code_provenance/1: masked" do
    # Source: test_unprotected_tail_pipe_is_form_mismatch_not_command_proof (:1276).
    test "an unprotected presentation-filter pipe masks the exit code" do
      for cmd <- [
            "mix test 2>&1 | tail -20",
            "mix test | head -5",
            "mix test | cat",
            ~s(./gradlew test --tests "com.example.SomeTest" -i 2>&1 | tail -100)
          ] do
        assert prov(cmd).exit_code == :masked, "expected #{inspect(cmd)} :masked"
      end
    end

    # Source: test_command_claim_rejects_grep_filtered_run_as_tests_passed_claim
    # (:1707) + the wc/tee siblings — transforming filters are never peelable,
    # pipefail or not (residual pipe ⇒ not provable-clean).
    test "a transforming filter pipe is never provable-clean" do
      for cmd <- [
            "mix test | grep -i pass",
            "pytest tests/unit | wc -l",
            "mix test | tee out.log",
            "set -o pipefail && mix test | grep -i pass"
          ] do
        assert prov(cmd).exit_code == :masked, "expected #{inspect(cmd)} :masked"
      end
    end

    # Source: test_test_invocation_rejects_pipefail_text_without_shell_option
    # (:1634) — prose "pipefail" is not the option.
    test "pipefail prose does not protect" do
      assert prov("echo pipefail && mix test | tail -5").exit_code == :masked
    end

    # Source: test_test_invocation_rejects_pipefail_set_after_output_pipe (:1654).
    test "pipefail set after the pipeline does not protect" do
      assert prov("mix test | tail -5; set -o pipefail").exit_code == :masked
    end

    test "the explicit exit-swallow idioms mask regardless of pipefail" do
      for cmd <- [
            "mix test || true",
            "mix test || :",
            "mix test; true",
            "mix test; :",
            "set -o pipefail && mix test || true"
          ] do
        assert prov(cmd).exit_code == :masked, "expected #{inspect(cmd)} :masked"
      end
    end

    test "an upstream pipe feed is conservatively masked (residual pipe)" do
      assert prov("cat fixtures.txt | mix test").exit_code == :masked
    end
  end

  describe "exit_code_provenance/1: unknown (total, never a raise)" do
    test "unparseable / unresolvable input degrades to :unknown" do
      # A parameter-expansion command word and an unrecognized wrapper flag are
      # the strip → :unknown paths; the huge chain trips the subcommand cap.
      assert %SC.Provenance{exit_code: :unknown, test_runner: nil} = prov("$CMD test")
      assert %SC.Provenance{exit_code: :unknown, test_runner: nil} = prov("sudo --frob mix test")
      assert %SC.Provenance{exit_code: :unknown} = prov(String.duplicate("a;", 100_000))
    end

    test "a non-string input is :unknown" do
      assert %SC.Provenance{exit_code: :unknown} = SC.exit_code_provenance(nil)
      assert %SC.Provenance{exit_code: :unknown} = SC.exit_code_provenance(42)
    end
  end

  describe "exit_code_provenance/1: test-runner recognition + skip flags" do
    # Source: test_gradle_maven_tests_passed_rejects_skip_test_invocations
    # (:1420). Divergence (PORT-OB1-3): recognized WITH skipped?: true rather
    # than refused, so the evidence classifier can flag the claim.
    test "gradle/maven skip flags surface skipped?: true" do
      for cmd <- [
            "gradle build -x test",
            "gradle build --exclude-task test",
            "gradle test --exclude-task=test",
            "gradle check -xtest",
            "mvn verify -DskipTests",
            "mvn verify -DskipTests=true",
            "mvn verify -Dmaven.test.skip",
            "mvn verify --define skipTests",
            "mvn verify --define=skipTests",
            "./gradlew test -x :app:test"
          ] do
        provenance = prov(cmd)

        assert %{skipped?: true} = provenance.test_runner,
               "expected #{inspect(cmd)} skipped?: true, got #{inspect(provenance)}"
      end
    end

    # Source: test_maven_tests_passed_supports_explicit_false_skip_properties (:1453).
    test "=false|0|no|off skip values do NOT skip" do
      for cmd <- [
            "mvn verify -DskipTests=false",
            "mvn verify -DskipTests=0",
            "mvn verify -Dmaven.test.skip=no",
            "mvn verify -DskipTests=off"
          ] do
        assert %{tool: "mvn", skipped?: false} = prov(cmd).test_runner,
               "expected #{inspect(cmd)} skipped?: false"
      end
    end

    test "gradle/maven need a test-family task word to register as a runner" do
      assert prov("mvn install -DskipTests").test_runner == nil
      assert prov("gradle assemble").test_runner == nil
      assert %{tool: "gradle", skipped?: false} = prov("gradle check").test_runner
      assert %{tool: "gradlew", skipped?: false} = prov("./gradlew :app:test").test_runner
    end

    test "mix precommit is deliberately NOT a test runner (Verify authority owns it)" do
      assert prov("mix precommit").test_runner == nil
    end

    test "a runner is still recognized on a masked line (the claim verdict is Evidence's)" do
      assert %{tool: "mix test"} = prov("mix test | tail -20").test_runner
    end
  end

  describe "exit_code_provenance/1: analyze/1 regression pins" do
    # The provenance path must not perturb the gate analyzer: same inputs,
    # byte-identical Analysis before/after deriving provenance.
    test "analyze/1 output is unchanged for provenance-exercised inputs" do
      for cmd <- [
            "mix test 2>&1 | tail -20",
            "set -o pipefail && mix test | tail -5",
            "mix test || true",
            "gradle build -x test",
            "git commit -m x && mix test | grep ok"
          ] do
        baseline = SC.analyze(cmd)
        _provenance = prov(cmd)
        assert SC.analyze(cmd) == baseline
      end
    end

    test "provenance kinds never leak into effect_kinds/0" do
      refute :preserved in SC.effect_kinds()
      refute :masked in SC.effect_kinds()
      assert Enum.count(SC.effect_kinds()) == 9
    end
  end
end
