defmodule JidoClaw.GitHub.PatchQualityTest do
  use ExUnit.Case, async: true
  # async: PatchQuality is pure functional — no GenServer, no ETS, no global state.

  alias JidoClaw.GitHub.PatchQuality

  # A complete, valid patch; individual checks override one field at a time.
  defp good_patch do
    %{files: [%{path: "lib/foo.ex"}], description: "x", branch: "fix/issue-1"}
  end

  describe "validate/1 — happy path" do
    test "should pass a complete, valid patch" do
      assert {:ok, %{passed: true, checks: checks}} = PatchQuality.validate(good_patch())
      assert [_, _, _] = checks
      assert Enum.all?(checks, &(&1.status == "passed"))
    end
  end

  describe "validate/1 — files_present" do
    test "should reject empty / pathless / wrong-shaped file lists" do
      for files <- [[], [nil], [%{}], [%{path: ""}], [%{path: "   "}]] do
        patch = %{good_patch() | files: files}

        assert {:error, {:quality_failed, [:files_present]}} = PatchQuality.validate(patch),
               "expected files #{inspect(files)} to be rejected"
      end
    end
  end

  describe "validate/1 — description_present" do
    test "should reject nil / non-binary / blank descriptions without raising" do
      for desc <- [nil, 123, "   "] do
        patch = %{good_patch() | description: desc}

        assert {:error, {:quality_failed, [:description_present]}} = PatchQuality.validate(patch),
               "expected description #{inspect(desc)} to be rejected"
      end
    end
  end

  describe "validate/1 — branch_valid" do
    test "should reject invalid git branch names" do
      invalid = [
        "bad branch!",
        "/leading",
        "a..b",
        "x.lock",
        ".",
        "foo.",
        "foo//bar",
        ".hidden",
        "foo/.bar"
      ]

      for branch <- invalid do
        patch = %{good_patch() | branch: branch}

        assert {:error, {:quality_failed, [:branch_valid]}} = PatchQuality.validate(patch),
               "expected branch #{inspect(branch)} to be rejected"
      end
    end

    test "should accept a generated fix/issue-N branch" do
      patch = %{good_patch() | branch: "fix/issue-42"}
      assert {:ok, %{passed: true}} = PatchQuality.validate(patch)
    end
  end

  describe "validate/1 — multiple failures" do
    test "should report every failed check (order is incidental)" do
      patch = %{files: [], description: nil, branch: "bad branch!"}

      assert {:error, {:quality_failed, names}} = PatchQuality.validate(patch)

      assert MapSet.new(names) ==
               MapSet.new([:files_present, :description_present, :branch_valid])
    end
  end
end
