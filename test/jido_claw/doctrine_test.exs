defmodule JidoClaw.DoctrineTest do
  @moduledoc """
  Pure registry contract for `JidoClaw.Doctrine` (AR-5). No DB — slices are
  compile-time priv-file text and the template→slice map is in-code.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Templates
  alias JidoClaw.Doctrine

  describe "slice/1" do
    test "returns non-empty text for each known slice key" do
      for key <- [:base, :artifacts, :reviewer_min] do
        assert is_binary(Doctrine.slice(key))
        assert Doctrine.slice(key) != ""
      end
    end

    test "returns \"\" for an unknown key" do
      assert Doctrine.slice(:does_not_exist) == ""
    end

    test "list/0 enumerates exactly the three seed slices" do
      assert Enum.sort(Doctrine.list()) == [:artifacts, :base, :reviewer_min]
    end
  end

  describe "for_template/1" do
    test "a producing worker gets base + artifacts, never the reviewer slice" do
      doctrine = Doctrine.for_template("coder")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Runtime artifacts"
      refute doctrine =~ "Review discipline"
    end

    test "a judge worker gets base + reviewer-min, never the artifacts slice" do
      doctrine = Doctrine.for_template("reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      refute doctrine =~ "Runtime artifacts"
    end

    test "the AR-8b-2 sketch_reviewer is a read-only judge (base + reviewer-min)" do
      doctrine = Doctrine.for_template("sketch_reviewer")

      assert doctrine =~ "specialized sub-agent"
      assert doctrine =~ "Review discipline"
      refute doctrine =~ "Runtime artifacts"
    end

    test "\"main\" maps to no doctrine (it uses Prompt — doctrine never double-applies)" do
      assert Doctrine.for_template("main") == ""
    end

    test "an unmapped template maps to no doctrine" do
      assert Doctrine.for_template("totally_unknown_template") == ""
    end
  end

  describe "registry-drift guard" do
    test "every doctrine template is a real agent template" do
      assert Enum.all?(Doctrine.template_names(), &Templates.exists?/1)
    end

    test "the doctrine template set equals the worker template set" do
      # A future worker added without a doctrine mapping (or vice versa) fails here.
      # "main" is intentionally absent from both (it is not a worker template).
      assert Enum.sort(Doctrine.template_names()) == Enum.sort(Templates.names())
      refute "main" in Doctrine.template_names()
    end
  end
end
