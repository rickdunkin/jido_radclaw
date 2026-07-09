defmodule JidoClaw.Orchestration.Verify.Evidence.AssertionsTest do
  @moduledoc """
  The slice-2 assertion verifier over real per-test trees (`@tag :tmp_dir`)
  plus the injected `:scanner` seam for the timeout branch. Every
  can't-verify branch is pinned as trust (`verified: true`); the ONLY false
  branch is a compiled pattern absent across scanned files that existed
  (`:contradicted`) — a matched-but-unreadable/oversized file still counts
  scanned, the pinned residual — source-anchored via PORT-OB1-3 (test map
  rows for `test_verification.py`).
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Orchestration.Verify.Evidence.Assertions

  defmodule SleepyScanner do
    @moduledoc "A scanner whose reads outlast any sane timeout (decision-8 pin)."

    @spec find(String.t(), String.t()) :: [String.t()]
    def find(project_dir, hint), do: Path.wildcard(Path.join(project_dir, hint))

    @spec read(String.t(), pos_integer()) :: nil
    def read(_path, _max) do
      Process.sleep(:timer.seconds(5))
      nil
    end
  end

  defp assertion(overrides) do
    Map.merge(
      %{
        "ac_id" => "AC1",
        "assertion" => "warmup is 10",
        "tier" => "T1_CONSTANT",
        "file_hint" => "*.ex",
        "pattern" => "WARMUP\\s*=\\s*10"
      },
      Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
    )
  end

  defp verify_one(overrides, dir, opts \\ []) do
    assert [result] = Assertions.verify([assertion(overrides)], dir, opts)
    result
  end

  describe "T1 constant" do
    @tag :tmp_dir
    test "pattern present in a scanned file verifies", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.ex"), "WARMUP = 10\n")

      assert %{verified: true, reason: "pattern found in scanned files"} =
               verify_one(%{}, dir)
    end

    @tag :tmp_dir
    test "pattern absent across existing files contradicts — the ONLY false branch",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.ex"), "WARMUP = 5\n")

      assert %{verified: false, reason: reason, ac_id: "AC1", tier: "T1_CONSTANT"} =
               verify_one(%{}, dir)

      assert reason =~ "contradicted"
      assert reason =~ "1 scanned files"
    end

    @tag :tmp_dir
    test "found-wrong-value flips via the folded pattern (source row :183)", %{tmp_dir: dir} do
      # The dropped `expected_value` route: `WARMUP\s*=\s*10` against a file
      # holding `WARMUP = 5` is pattern-absent ⇒ the same discrepancy by a
      # simpler route.
      File.write!(Path.join(dir, "settings.ex"), "# config\nWARMUP = 5\n")

      assert %{verified: false} = verify_one(%{file_hint: "settings.ex"}, dir)
    end
  end

  describe "T2 structural" do
    @tag :tmp_dir
    test "a basename match verifies (case-insensitive)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "camera_provider.ex"), "defmodule Whatever do end\n")

      assert %{verified: true, reason: "matching file exists"} =
               verify_one(
                 %{tier: "T2_STRUCTURAL", pattern: "Camera_Provider", file_hint: "*.ex"},
                 dir
               )
    end

    @tag :tmp_dir
    test "a content match verifies when no basename matches", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "providers.ex"), "defmodule CameraProvider do end\n")

      assert %{verified: true, reason: "pattern found in scanned files"} =
               verify_one(
                 %{
                   tier: "T2_STRUCTURAL",
                   pattern: "defmodule\\s+CameraProvider",
                   file_hint: "*.ex"
                 },
                 dir
               )
    end

    @tag :tmp_dir
    test "neither basename nor content contradicts", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "providers.ex"), "defmodule Other do end\n")

      assert %{verified: false, reason: reason} =
               verify_one(
                 %{tier: "T2_STRUCTURAL", pattern: "CameraProvider", file_hint: "*.ex"},
                 dir
               )

      assert reason =~ "contradicted"
    end
  end

  describe "can't-verify ⇒ trust (every conservative branch)" do
    @tag :tmp_dir
    test "T3/T4 tiers skip without scanning", %{tmp_dir: dir} do
      for tier <- ["T3_BEHAVIORAL", "T4_UNVERIFIABLE"] do
        assert %{verified: true, reason: "tier not machine-verifiable (skipped)"} =
                 verify_one(%{tier: tier}, dir)
      end
    end

    @tag :tmp_dir
    test "no pattern / no hint / no matching files all trust", %{tmp_dir: dir} do
      assert %{verified: true, reason: "no pattern to verify"} =
               verify_one(%{pattern: nil}, dir)

      assert %{verified: true, reason: "no files matched hint (cannot verify)"} =
               verify_one(%{file_hint: nil}, dir)

      assert %{verified: true, reason: "no files matched hint (cannot verify)"} =
               verify_one(%{file_hint: "*.nomatch"}, dir)
    end

    @tag :tmp_dir
    test "invalid and over-long regex patterns trust", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.ex"), "WARMUP = 10\n")

      assert %{verified: true, reason: reason} = verify_one(%{pattern: "([unclosed"}, dir)
      assert reason =~ "invalid or too-long regex"

      long = String.duplicate("a", 201)
      assert %{verified: true, reason: reason} = verify_one(%{pattern: long}, dir)
      assert reason =~ "invalid or too-long regex"
    end

    test "nil project dir trusts" do
      assert %{verified: true, reason: "no project directory (cannot verify)"} =
               verify_one(%{}, nil)
    end

    @tag :tmp_dir
    test "a traversal hint scans nothing (trust, never an escape)", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      inside = Path.join(dir, "repo")
      File.mkdir_p!(outside)
      File.mkdir_p!(inside)
      File.write!(Path.join(outside, "secret.ex"), "WARMUP = 10\n")

      assert %{verified: true, reason: "no files matched hint (cannot verify)"} =
               verify_one(%{file_hint: "../outside/*.ex"}, inside)
    end

    @tag :tmp_dir
    test "a symlink escaping the tree is dropped, not read", %{tmp_dir: dir} do
      outside = Path.join(dir, "outside")
      inside = Path.join(dir, "repo")
      File.mkdir_p!(outside)
      File.mkdir_p!(inside)
      File.write!(Path.join(outside, "real.ex"), "WARMUP = 10\n")
      File.ln_s!(Path.join(outside, "real.ex"), Path.join(inside, "linked.ex"))

      assert %{verified: true, reason: "no files matched hint (cannot verify)"} =
               verify_one(%{file_hint: "*.ex"}, inside)
    end

    @tag :tmp_dir
    test "a timed-out scan trusts (decision 8)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.ex"), "WARMUP = 10\n")

      assert %{verified: true, reason: "scan timed out (cannot verify)"} =
               verify_one(%{}, dir, scanner: SleepyScanner, timeout_ms: 50)
    end
  end

  describe "bounds and noise" do
    @tag :tmp_dir
    test "noise dirs are excluded from the scan", %{tmp_dir: dir} do
      for noise <- ["_build", "deps", ".git", "node_modules"] do
        noise_dir = Path.join(dir, noise)
        File.mkdir_p!(noise_dir)
        File.write!(Path.join(noise_dir, "gen.ex"), "WARMUP = 10\n")
      end

      # The only match sites are noise ⇒ nothing scanned ⇒ trust.
      assert %{verified: true, reason: "no files matched hint (cannot verify)"} =
               verify_one(%{file_hint: "**/*.ex"}, dir)
    end

    @tag :tmp_dir
    test "an over-sized file is not read (source: skipped file still counts scanned)",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "big.ex"), String.duplicate("x", 51 * 1024) <> "WARMUP = 10")

      # The 50KB cap skips the read; the file still existed, so the pattern
      # is absent across scanned files ⇒ contradicted (verifier.py:136-174
      # behavior, PORT map bounds row).
      assert %{verified: false} = verify_one(%{}, dir)
    end
  end

  test "totality: junk assertion lists and junk entries never raise" do
    assert [] = Assertions.verify("junk", "/tmp", [])
    assert [] = Assertions.verify(nil, "/tmp", [])

    assert [%{ac_id: "AC?", tier: "T4_UNVERIFIABLE", verified: true}] =
             Assertions.verify([%{}], "/tmp", [])
  end
end
