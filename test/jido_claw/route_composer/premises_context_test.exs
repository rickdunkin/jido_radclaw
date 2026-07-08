defmodule JidoClaw.RouteComposer.PremisesContextTest do
  use ExUnit.Case, async: true

  alias JidoClaw.RouteComposer.PremisesContext

  test "nil and the empty map render to the empty string" do
    assert PremisesContext.render(nil) == ""
    assert PremisesContext.render(%{}) == ""
  end

  test "any non-map term renders to the empty string WITHOUT raising (total renderer)" do
    # `create_parent_run` persists `:premises` through `json_safe/1` and state
    # restore hands the durable value straight to the renderer — a malformed
    # durable value must degrade to no-premises, never crash the wave.
    assert PremisesContext.render([{"path", "code"}]) == ""
    assert PremisesContext.render("path: code") == ""
    assert PremisesContext.render(42) == ""
    assert PremisesContext.render({:tuple, "nope"}) == ""
  end

  test "renders the header, deterministic key-sorted lines, and the scope-shift instruction" do
    text = PremisesContext.render(%{"path" => "code", "est_size" => "small"})

    assert text ==
             "### Premises\n" <>
               "- **est_size**: small\n" <>
               "- **path**: code\n\n" <>
               "If any of your findings or work contradicts a premise, include " <>
               "`scope-shift` in your `signals` output."
  end

  test "atom keys and non-binary scalar values render without raising" do
    text = PremisesContext.render(%{risk: :low, retries: 3})

    assert text =~ "- **retries**: 3"
    assert text =~ "- **risk**: :low"
  end

  test "nested map values (front_door graduated_from shape) are bounded-inspected, no crash" do
    premises = %{
      "graduated_from" => %{
        "prototype_id" => "p1",
        "prototype_dir" => "/tmp/.prototypes/p1",
        "run_id" => "r1"
      }
    }

    text = PremisesContext.render(premises)

    assert text =~ "### Premises"
    assert text =~ "- **graduated_from**: "
    assert text =~ "prototype_id"
  end

  test "an oversized value is byte-capped, elision-marked, and stays valid UTF-8" do
    # 1 ASCII byte + 10k four-byte codepoints misaligns every 4-byte boundary,
    # so the clip must walk back off a partial codepoint to stay valid.
    value = "a" <> String.duplicate("🎉", 10_000)
    text = PremisesContext.render(%{"big" => value})

    assert String.valid?(text)
    assert text =~ "…[premise truncated]"
    # Far below the raw ~40KB value: the per-value byte budget held.
    assert byte_size(text) < 5_000
  end

  test "a huge nested structure is bounded at the source (inspect limits), then clipped" do
    huge = Map.new(1..5_000, fn i -> {"k#{i}", String.duplicate("x", 100)} end)
    text = PremisesContext.render(%{"blob" => huge})

    assert String.valid?(text)
    assert byte_size(text) < 5_000
  end

  # ── Global block bounds ────────────────────────────────────────────────────
  # The whole rendered block is bounded by construction: keys clipped, entry
  # count capped, total ≤ the block byte budget with the instruction line
  # always intact. `@block_byte_budget` is private to the module, so each test
  # pins it as an explicit local `block_budget = 6_000`.

  test "many premises: entry count is capped and the block stays under the byte budget" do
    # Explicit copy of PremisesContext's private @block_byte_budget.
    block_budget = 6_000

    premises =
      Map.new(1..500, fn i -> {"key_" <> String.pad_leading("#{i}", 4, "0"), "value"} end)

    text = PremisesContext.render(premises)

    assert String.valid?(text)
    assert byte_size(text) <= block_budget
    assert text =~ "### Premises"
    assert text =~ "include `scope-shift` in your `signals` output."
    # 500 entries − the 32-entry count cap ⇒ 468 omitted, one marker line.
    assert text =~ "- …[468 premises omitted]"
  end

  test "a huge binary key is elision-clipped, never passed through unbounded" do
    # Explicit copy of PremisesContext's private @block_byte_budget.
    block_budget = 6_000
    huge_key = String.duplicate("k", 50_000)

    text = PremisesContext.render(%{huge_key => "small"})

    assert String.valid?(text)
    assert byte_size(text) <= block_budget
    # The rendered key keeps a 120-byte prefix plus the elision mark; the full
    # key run must be gone.
    assert text =~ String.duplicate("k", 120) <> "…[premise truncated]"
    refute text =~ String.duplicate("k", 121)
    # Key clipping is not entry omission — nothing was dropped.
    refute text =~ "premises omitted"
  end

  test "total cap: per-value-capped entries that jointly overflow drop a trailing sorted suffix" do
    # Explicit copy of PremisesContext's private @block_byte_budget.
    block_budget = 6_000

    keys = Enum.map(1..12, fn i -> "p" <> String.pad_leading("#{i}", 2, "0") end)
    # Each value sits exactly at the 600-byte per-value cap (individually
    # fine), so only the joined block overflows the budget.
    premises = Map.new(keys, fn key -> {key, String.duplicate("v", 600)} end)

    text = PremisesContext.render(premises)

    assert String.valid?(text)
    assert byte_size(text) <= block_budget

    kept_keys =
      ~r/\*\*(p\d{2})\*\*/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()

    kept_count = length(kept_keys)

    # The kept set is a non-empty strict sorted prefix — trailing entries drop
    # whole, never a tail byte-clip of the block.
    assert kept_keys != []
    assert kept_count < 12
    assert kept_keys == Enum.take(Enum.sort(keys), kept_count)

    # One marker for exactly the dropped count, and the instruction survives.
    assert text =~ "- …[#{12 - kept_count} premises omitted]"
    assert text =~ "include `scope-shift` in your `signals` output."
  end

  test "adversarial combo (many entries × huge keys × huge values) stays under the block budget" do
    # Explicit copy of PremisesContext's private @block_byte_budget.
    block_budget = 6_000

    premises =
      Map.new(1..100, fn i ->
        key = String.pad_leading("#{i}", 3, "0") <> String.duplicate("x", 10_000)
        {key, String.duplicate("y", 50_000)}
      end)

    text = PremisesContext.render(premises)

    assert String.valid?(text)
    assert byte_size(text) <= block_budget
    assert text =~ "### Premises"
    assert text =~ ~r/- …\[\d+ premises omitted\]/
    assert text =~ "include `scope-shift` in your `signals` output."
  end

  test "near-budget full render is emitted whole — marker reservation never causes the omission" do
    # Green guard for the two-pass property (the unbounded renderer also
    # passes it): a block that fits the budget as-is, without a marker, is
    # never truncated merely because marker space was pre-reserved.
    # Explicit copy of PremisesContext's private @block_byte_budget.
    block_budget = 6_000

    keys = Enum.map(1..9, fn i -> "p#{i}" end)
    premises = Map.new(keys, fn key -> {key, String.duplicate("v", 600)} end)

    text = PremisesContext.render(premises)

    assert byte_size(text) <= block_budget
    # Near the budget, not trivially under it — the exact fit is the point.
    assert byte_size(text) > 5_000
    for key <- keys, do: assert(text =~ "- **#{key}**: ")
    refute text =~ "premises omitted"
  end

  test "no omission marker when everything fits (small map and the exact count-cap boundary)" do
    small = PremisesContext.render(%{"path" => "code"})
    refute small =~ "premises omitted"

    # Exactly at the 32-entry count cap: all entries render, still no marker.
    at_cap = Map.new(1..32, fn i -> {"k#{i}", "v"} end)
    text = PremisesContext.render(at_cap)

    refute text =~ "premises omitted"
    assert text =~ "- **k1**: v"
    assert text =~ "- **k32**: v"
  end

  # ── Typed sections (item 9 — OB1-2) ────────────────────────────────────────

  describe "typed premises sections" do
    test "absent typed keys render byte-identically to the generic-only form" do
      premises = %{"path" => "code", "est_size" => "m", "ambiguity_score" => 0.1}

      assert PremisesContext.render(premises) ==
               "### Premises\n" <>
                 "- **ambiguity_score**: 0.1\n" <>
                 "- **est_size**: m\n" <>
                 "- **path**: code\n\n" <>
                 "If any of your findings or work contradicts a premise, include " <>
                 "`scope-shift` in your `signals` output."
    end

    test "acceptance criteria render as a dedicated AC-id-numbered section, excluded from bullets" do
      premises = %{
        "path" => "code",
        "acceptance_criteria" => ["`mix test` passes", "GET /health returns 200"]
      }

      text = PremisesContext.render(premises)

      assert text ==
               "### Premises\n" <>
                 "- **path**: code\n\n" <>
                 "### Acceptance criteria\n" <>
                 "AC1. `mix test` passes\n" <>
                 "AC2. GET /health returns 200\n\n" <>
                 "If any of your findings or work contradicts a premise, include " <>
                 "`scope-shift` in your `signals` output."
    end

    test "principles and exit conditions render legible sections after the criteria" do
      premises = %{
        "path" => "code",
        "acceptance_criteria" => ["`mix test` passes"],
        "evaluation_principles" => [
          %{"name" => "correctness", "description" => "must be right", "weight" => 0.9}
        ],
        "exit_conditions" => ["stop after 3 failed attempts"]
      }

      text = PremisesContext.render(premises)

      assert text =~ "### Acceptance criteria\nAC1. `mix test` passes"
      assert text =~ "### Evaluation principles\n- correctness (weight 0.90): must be right"
      assert text =~ "### Exit conditions\n- stop after 3 failed attempts"
      # Typed keys never appear as generic bullets.
      refute text =~ "- **acceptance_criteria**"
      refute text =~ "- **evaluation_principles**"
      refute text =~ "- **exit_conditions**"
      # The instruction stays last.
      assert String.ends_with?(text, "`scope-shift` in your `signals` output.")
    end

    test "a malformed typed value renders nowhere (neither section nor bullet)" do
      text = PremisesContext.render(%{"path" => "code", "acceptance_criteria" => "junk"})

      refute text =~ "Acceptance criteria"
      refute text =~ "junk"
      assert text =~ "- **path**: code"
    end

    test "criteria count is capped with a marker; AC ids stay stable for the kept prefix" do
      criteria = Enum.map(1..20, fn i -> "criterion number #{i} `cmd#{i}` exits 0" end)
      text = PremisesContext.render(%{"acceptance_criteria" => criteria})

      assert text =~ "AC1. criterion number 1"
      assert text =~ "AC12. criterion number 12"
      refute text =~ "AC13."
      assert text =~ "- …[8 acceptance criteria omitted]"
    end

    test "typed sections participate in the whole-block budget (hostile sizes stay bounded)" do
      # Explicit copy of PremisesContext's private @block_byte_budget.
      block_budget = 6_000

      premises = %{
        "path" => "code",
        "acceptance_criteria" =>
          Enum.map(1..40, fn i -> "AC body #{i} " <> String.duplicate("a", 2_000) end),
        "evaluation_principles" =>
          Enum.map(1..20, fn i ->
            %{"name" => "p#{i}", "description" => String.duplicate("d", 2_000), "weight" => 0.5}
          end),
        "exit_conditions" =>
          Enum.map(1..20, fn i -> "exit #{i} " <> String.duplicate("e", 2_000) end)
      }

      text = PremisesContext.render(premises)

      assert String.valid?(text)
      assert byte_size(text) <= block_budget
      assert text =~ "### Premises"
      assert text =~ "### Acceptance criteria"
      # The instruction always survives, last.
      assert String.ends_with?(text, "`scope-shift` in your `signals` output.")
    end

    test "generic entries still fold under the budget when typed sections are present" do
      # Explicit copy of PremisesContext's private @block_byte_budget.
      block_budget = 6_000

      premises =
        1..12
        |> Map.new(fn i ->
          {"p" <> String.pad_leading("#{i}", 2, "0"), String.duplicate("v", 600)}
        end)
        |> Map.put("acceptance_criteria", ["`mix test` passes", "GET /health returns 200"])

      text = PremisesContext.render(premises)

      assert byte_size(text) <= block_budget
      assert text =~ "### Acceptance criteria"
      assert text =~ "AC1. `mix test` passes"
      assert text =~ ~r/- …\[\d+ premises omitted\]/
      assert String.ends_with?(text, "`scope-shift` in your `signals` output.")
    end
  end
end
