defmodule JidoClaw.Orchestration.Verify.ConfigTest do
  @moduledoc """
  Resolution-chain tests for `JidoClaw.Orchestration.Verify.Config` over
  scratch project dirs (real `.jido/config.yaml` files + `mix.exs` markers —
  no subprocess): per-run override → config.yaml → mix auto-detect →
  `:no_verifier`; the no-shell scalar rules; the loud unknown-check refusal.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verify.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "jido_verify_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_yaml!(dir, yaml) do
    File.mkdir_p!(Path.join(dir, ".jido"))
    File.write!(Path.join([dir, ".jido", "config.yaml"]), yaml)
  end

  describe "auto-detect (chain step 3)" do
    test "no mix.exs and no config is a loud :no_verifier, never a silent skip", %{dir: dir} do
      assert {:error, :no_verifier} = Config.resolve(dir)
      assert Config.format_error(:no_verifier) =~ "verify_cmd"
    end

    test "mix.exs with a precommit alias detects mix precommit", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "defp aliases, do: [precommit: [\"test\"]]")

      assert {:ok, [%{name: "mix:precommit", cmd: ["mix", "precommit"]}]} = Config.resolve(dir)
    end

    test "mix.exs without a precommit alias detects mix test", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "defmodule P.MixProject do\nend\n")

      assert {:ok, [%{name: "mix:test", cmd: ["mix", "test"]}]} = Config.resolve(dir)
    end
  end

  describe "config.yaml (chain step 2)" do
    test "a shell-free verify_cmd scalar whitespace-splits into one named check", %{dir: dir} do
      write_yaml!(dir, "verify_cmd: mix precommit\n")

      assert {:ok, [%{name: "verify", cmd: ["mix", "precommit"], env: %{}, timeout_ms: nil}]} =
               Config.resolve(dir)
    end

    test "a verify_cmd argv list passes through verbatim (metacharacters and all)", %{dir: dir} do
      write_yaml!(dir, "verify_cmd:\n  - mix\n  - test\n  - --only\n  - \"tag:*\"\n")

      assert {:ok, [%{cmd: ["mix", "test", "--only", "tag:*"]}]} = Config.resolve(dir)
    end

    test "a verify: block with cmd/env/timeout_ms builds one validated check", %{dir: dir} do
      write_yaml!(dir, """
      verify:
        cmd: mix precommit
        timeout_ms: 60000
        env:
          MIX_ENV: test
      """)

      assert {:ok, [check]} = Config.resolve(dir)
      assert check.cmd == ["mix", "precommit"]
      assert check.timeout_ms == 60_000
      assert check.env == %{"MIX_ENV" => "test"}
    end

    test "a verify: checks: registry resolves the ordered named list (orca OR2-2)", %{dir: dir} do
      write_yaml!(dir, """
      verify:
        checks:
          - name: format
            cmd: mix format --check-formatted
          - name: unit
            cmd: mix test
            timeout_ms: 120000
      """)

      assert {:ok, [%{name: "format"}, %{name: "unit", timeout_ms: 120_000}]} =
               Config.resolve(dir)
    end

    test "duplicate check names refuse loudly", %{dir: dir} do
      write_yaml!(dir, """
      verify:
        checks:
          - name: unit
            cmd: mix test
          - name: unit
            cmd: mix format
      """)

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "duplicate"
    end

    test "both verify_cmd and verify: present is a loud ambiguity error", %{dir: dir} do
      write_yaml!(dir, "verify_cmd: mix test\nverify:\n  cmd: mix precommit\n")

      assert {:error, :ambiguous_verify_config} = Config.resolve(dir)
      assert Config.format_error(:ambiguous_verify_config) =~ "exactly one"
    end

    test "a scalar verify: refuses loudly even with a mix.exs present, never silent autodetect",
         %{dir: dir} do
      # The failure mode being pinned: collapsing a non-map `verify:` to nil
      # falls through to autodetect and certifies `mix test` — the WRONG
      # command — instead of refusing.
      File.write!(Path.join(dir, "mix.exs"), "defmodule P.MixProject do\nend\n")
      write_yaml!(dir, "verify: mix format\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "verify_cmd"
    end

    test "a list verify: refuses loudly (an argv command belongs under verify_cmd:)", %{dir: dir} do
      write_yaml!(dir, "verify:\n  - mix\n  - test\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "verify_cmd"
    end
  end

  describe "the no-shell scalar rules" do
    test "a scalar with shell metacharacters is a loud validation error, never missing_tool",
         %{dir: dir} do
      write_yaml!(dir, "verify_cmd: \"mix test | tail -5\"\n")

      assert {:error, {:shell_syntax, :metacharacters, _cmd} = reason} = Config.resolve(dir)
      assert Config.format_error(reason) =~ "argv list"
    end

    test "a scalar with a leading env-assignment token is shell syntax, never a confusing missing_tool",
         %{dir: dir} do
      write_yaml!(dir, "verify_cmd: MIX_ENV=prod mix test\n")

      assert {:error, {:shell_syntax, :env_assignment, _cmd} = reason} = Config.resolve(dir)
      assert Config.format_error(reason) =~ "env"
    end

    test "an empty scalar refuses", %{dir: dir} do
      write_yaml!(dir, "verify_cmd: \"  \"\n")
      assert {:error, {:invalid_verify_config, _detail}} = Config.resolve(dir)
    end
  end

  describe "per-run override (chain step 1)" do
    test "a scalar override wins over config + autodetect", %{dir: dir} do
      write_yaml!(dir, "verify_cmd: mix test\n")

      assert {:ok, [%{name: "override", cmd: ["mix", "format"]}]} =
               Config.resolve(dir, "mix format")
    end

    test "an argv-list override passes through", %{dir: dir} do
      assert {:ok, [%{name: "override", cmd: ["./scripts/verify.sh", "--fast"]}]} =
               Config.resolve(dir, ["./scripts/verify.sh", "--fast"])
    end

    test "a cmd-map override validates env + timeout", %{dir: dir} do
      assert {:ok, [check]} =
               Config.resolve(dir, %{
                 "cmd" => ["mix", "test"],
                 "env" => %{"MIX_ENV" => "test"},
                 "timeout_ms" => 5_000
               })

      assert check.env == %{"MIX_ENV" => "test"}
      assert check.timeout_ms == 5_000
    end

    test "a checks-name override selects from the configured registry in override order",
         %{dir: dir} do
      write_yaml!(dir, """
      verify:
        checks:
          - name: format
            cmd: mix format --check-formatted
          - name: unit
            cmd: mix test
      """)

      assert {:ok, [%{name: "unit"}, %{name: "format"}]} =
               Config.resolve(dir, %{"checks" => ["unit", "format"]})
    end

    test "an override naming an unknown check refuses loudly (orca silent-skip inverted)",
         %{dir: dir} do
      write_yaml!(dir, """
      verify:
        checks:
          - name: unit
            cmd: mix test
      """)

      assert {:error, {:unknown_check, "lint", ["unit"]} = reason} =
               Config.resolve(dir, %{"checks" => ["lint"]})

      assert Config.format_error(reason) =~ "refusing loudly"
    end

    test "a shell-syntax scalar override is the same loud validation error", %{dir: dir} do
      assert {:error, {:shell_syntax, :env_assignment, _cmd}} =
               Config.resolve(dir, "FOO=bar mix test")

      assert {:error, {:shell_syntax, :metacharacters, _cmd}} =
               Config.resolve(dir, "mix test && echo done")
    end

    test "an unsupported override shape refuses with a bounded error", %{dir: dir} do
      assert {:error, {:invalid_verify_config, _detail}} = Config.resolve(dir, 42)
      assert {:error, {:invalid_verify_config, _detail}} = Config.resolve(dir, %{"nope" => true})
    end
  end

  describe "malformed yaml shapes" do
    test "a non-string env map refuses loudly", %{dir: dir} do
      write_yaml!(dir, "verify:\n  cmd: mix test\n  env:\n    RETRIES: 3\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "env"
    end

    test "a non-positive timeout refuses loudly", %{dir: dir} do
      write_yaml!(dir, "verify:\n  cmd: mix test\n  timeout_ms: -5\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "timeout_ms"
    end

    test "a checks entry without a name refuses loudly", %{dir: dir} do
      write_yaml!(dir, "verify:\n  checks:\n    - cmd: mix test\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "name"
    end

    test "a verify: block with neither cmd nor checks refuses loudly", %{dir: dir} do
      write_yaml!(dir, "verify:\n  timeout_ms: 5000\n")

      assert {:error, {:invalid_verify_config, detail}} = Config.resolve(dir)
      assert detail =~ "cmd"
    end
  end
end
