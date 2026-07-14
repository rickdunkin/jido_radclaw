defmodule JidoClaw.Core.JsonSafeTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Core.JsonSafe
  alias JidoClaw.TestSupport.HostileInspect

  describe "encode/1 — map keys are all stringified" do
    test "atom keys become strings; binary keys pass through" do
      assert JsonSafe.encode(%{:status => :ok, "already" => 1}) ==
               %{"status" => "ok", "already" => 1}
    end

    test "non-binary, non-atom keys are stringified via inspect and stay JSON-encodable" do
      out = JsonSafe.encode(%{{:tuple, :key} => :value, 7 => "x"})

      assert out["{:tuple, :key}"] == "value"
      assert out["7"] == "x"
      # The contract: the result is always a valid JSON object.
      assert {:ok, _json} = Jason.encode(out)
    end

    test "non-binary keys nested inside the value are also stringified" do
      out = JsonSafe.encode(%{outer: %{[1, 2] => :v}})
      assert {:ok, _json} = Jason.encode(out)
    end
  end

  describe "encode/1 — value normalization (shared-normalizer regression guard)" do
    test "DateTime → ISO-8601, MapSet → list, module dropped, atoms → strings, nil/bool kept" do
      {:ok, dt, _offset} = DateTime.from_iso8601("2026-05-28T00:00:00Z")

      out =
        JsonSafe.encode(%{
          at: dt,
          tags: MapSet.new([:a, :b]),
          mod: JidoClaw.Core.JsonSafe,
          status: :ok,
          keep: true,
          nada: nil
        })

      assert out["at"] == "2026-05-28T00:00:00Z"
      assert Enum.sort(out["tags"]) == ["a", "b"]
      # Module-valued entries are dropped entirely.
      refute Map.has_key?(out, "mod")
      assert out["status"] == "ok"
      assert out["keep"] == true
      assert out["nada"] == nil
      assert {:ok, _json} = Jason.encode(out)
    end

    test "a bare module atom encodes to nil (leaf), not a string" do
      assert JsonSafe.encode(JidoClaw.Core.JsonSafe) == nil
      assert JsonSafe.encode(:plain_atom) == "plain_atom"
    end

    test "pids/refs/functions become nil in lists and at the top level; dropped as map values" do
      assert JsonSafe.encode(self()) == nil
      assert JsonSafe.encode(make_ref()) == nil
      assert JsonSafe.encode(fn -> :x end) == nil

      out = JsonSafe.encode(%{procs: [self(), :keep], ref: make_ref()})

      # In a list → nil element (parallel to a module atom in a list).
      assert out["procs"] == [nil, "keep"]
      # As a direct map value → the entry is dropped entirely.
      refute Map.has_key?(out, "ref")
      assert {:ok, _json} = Jason.encode(out)
    end

    test "tuples (incl. keyword lists) encode as lists" do
      assert JsonSafe.encode({:ok, 1}) == ["ok", 1]
      # A keyword list is a list of 2-tuples.
      assert JsonSafe.encode(timeout: 5, retries: 3) == [["timeout", 5], ["retries", 3]]
    end

    test "arbitrary nested Elixir terms normalize to Jason-encodable JSON (totality)" do
      term = %{
        tuple: {:pid, self()},
        keyword: [ok: self()],
        nested: [%{{:tuple, :key} => {:error, make_ref()}}],
        fun: fn -> :x end
      }

      out = JsonSafe.encode(term)

      assert {:ok, _json} = Jason.encode(out)
      assert out["tuple"] == ["pid", nil]
      assert out["keyword"] == [["ok", nil]]
      refute Map.has_key?(out, "fun")
    end
  end

  # ── PD1-2 hardening: total wrapper, safe_inspect, invalid UTF-8, improper
  # lists, and the budgeted walkers ──────────────────────────────────────────

  # Hostile Inspect fixtures live in test/support/hostile_inspect.ex —
  # protocols are consolidated in the test env, so a defimpl inside this
  # file would never dispatch. A struct VALUE takes encode/1's generic
  # struct branch (Map.from_struct + recurse) and never invokes its Inspect
  # impl — so the impls are exercised through safe_inspect/1 directly and
  # through encode_key/1 (map KEYS render via inspect).

  describe "safe_inspect/1" do
    test "ordinary terms inspect byte-identically" do
      term = %{a: 1, b: [:x, "y"]}
      assert JsonSafe.safe_inspect(term) == inspect(term)
    end

    test "a raising Inspect impl yields Elixir's own Inspect.Error diagnostic (no escape)" do
      # Modern Elixir catches a RAISING impl inside inspect/1 itself and
      # returns the diagnostic rendering — no exception ever reaches our
      # rescue. The static fallback is for throw/exit, which DO escape.
      out = JsonSafe.safe_inspect(%HostileInspect.Raising{x: 1})
      assert out =~ "Inspect.Error"
      assert String.valid?(out)
    end

    test "a throwing Inspect impl yields the exact pinned static string" do
      assert JsonSafe.safe_inspect(%HostileInspect.Throwing{x: 1}) == "[uninspectable]"
    end

    test "an exiting Inspect impl yields the exact pinned static string" do
      assert JsonSafe.safe_inspect(%HostileInspect.Exiting{x: 1}) == "[uninspectable]"
    end

    test "a SUCCESSFUL inspect returning invalid bytes is scrubbed to valid UTF-8" do
      out = JsonSafe.safe_inspect(%HostileInspect.InvalidBytes{x: 1})
      assert String.valid?(out)
      assert out =~ "�"
    end
  end

  describe "encode/1 — totality hardening" do
    test "malformed calendar/MapSet structs degrade ONLY their leaf beside healthy siblings" do
      malformed_dt = %{__struct__: DateTime, garbage: :fields}
      malformed_set = %{__struct__: MapSet, map: :not_a_map}

      out = JsonSafe.encode(%{bad_dt: malformed_dt, bad_set: malformed_set, ok: "fine"})

      assert out["bad_dt"] == "[unencodable]"
      assert out["bad_set"] == "[unencodable]"
      assert out["ok"] == "fine"
      assert {:ok, _json} = Jason.encode(out)
    end

    test "hostile-Inspect structs as map KEYS render via safe_inspect" do
      # Throw escapes inspect/1 (unlike raise) — the key takes the static
      # fallback and the payload survives.
      out = JsonSafe.encode(%{%HostileInspect.Throwing{x: 1} => "v"})
      assert out == %{"[uninspectable]" => "v"}
    end

    test "invalid-UTF-8 binary VALUES are scrubbed with replacement characters" do
      out = JsonSafe.encode(%{data: <<"ok-", 255, "-tail">>})
      assert out["data"] == "ok-�-tail"
      assert {:ok, _json} = Jason.encode(out)
    end

    test "invalid-UTF-8 binary KEYS take the exact tagged Base64 form" do
      out = JsonSafe.encode(%{<<255>> => "v"})
      assert out == %{"<<invalid-utf8:/w==>>" => "v"}
      assert {:ok, _json} = Jason.encode(out)
    end

    test "a valid key EQUAL to a tagged form collides deterministically (term-order winner)" do
      # Original-key term order: the binary <<255>> sorts AFTER the longer
      # ASCII string? Erlang compares binaries bytewise: "<<invalid-utf8:/w==>>"
      # starts with ?< (60) < 255, so <<255>> is GREATER — later wins.
      out = JsonSafe.encode(%{<<255>> => "from-invalid", "<<invalid-utf8:/w==>>" => "from-valid"})
      assert out == %{"<<invalid-utf8:/w==>>" => "from-invalid"}
    end

    test "improper lists encode with the improper tail as the final element" do
      assert JsonSafe.encode([1 | 2]) == [1, 2]
      assert JsonSafe.encode(%{k: [1, 2 | 3]}) == %{"k" => [1, 2, 3]}
    end
  end

  describe "encode_bounded/2 — budget contract" do
    test "a full traversal returns {:ok, value, accounted_bytes}" do
      assert {:ok, %{"a" => 1, "b" => "x"}, bytes} = JsonSafe.encode_bounded(%{a: 1, b: "x"})
      assert is_integer(bytes) and bytes >= 0
    end

    test "node-count trips short-circuit deterministically" do
      huge = Map.new(1..1_000, fn i -> {"k#{i}", i} end)

      assert {:budget_exceeded, %{observed_at_least: n}} =
               JsonSafe.encode_bounded(huge, max_nodes: 50)

      assert is_integer(n)
      # Deterministic: same input + same budget → same trip.
      assert JsonSafe.encode_bounded(huge, max_nodes: 50) ==
               {:budget_exceeded, %{observed_at_least: n}}
    end

    test "an extreme key count preflights BEFORE materialization" do
      wide = Map.new(1..200_000, fn i -> {i, i} end)

      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(wide, max_nodes: 100)
    end

    test "depth trips short-circuit" do
      deep = Enum.reduce(1..200, :leaf, fn _i, acc -> [acc] end)
      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(deep, max_depth: 16)
    end

    test "cumulative bytes trip before scanning an over-budget binary" do
      assert {:budget_exceeded, %{observed_at_least: n}} =
               JsonSafe.encode_bounded(%{blob: String.duplicate("x", 4096)}, max_bytes: 1024)

      assert n > 1024
    end

    test "an oversized invalid key produces the bounded :trunc-<size> tagged form" do
      key = <<255>> <> :binary.copy(<<254>>, 2047)
      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{key => "v"})

      assert [encoded_key] = Map.keys(out)
      assert encoded_key =~ "<<invalid-utf8:"
      assert encoded_key =~ ":trunc-2048>>"
    end

    test "two oversized invalid keys sharing prefix AND length resolve to the collision sentinel" do
      prefix = :binary.copy(<<255>>, 1500)
      key_a = prefix <> <<0, 1>>
      key_b = prefix <> <<0, 2>>

      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{key_a => "a", key_b => "b"})

      # Both keys collapse to one bounded form; the collision resolves to
      # the constant sentinel — the originals are never compared.
      assert map_size(out) == 1
      assert Map.values(out) == ["[key-collision]"]
    end

    test "key-prefix draws clamp to the caller's cap — total under small caps, never a raise" do
      valid_key = String.duplicate("k", 20)

      assert {:ok, out, _bytes} =
               JsonSafe.encode_bounded(%{valid_key => "v"}, max_key_bytes: 10)

      assert out == %{"kkkkkkkkkk:trunc-20" => "v"}

      invalid_key = :binary.copy(<<255>>, 20)

      assert {:ok, tagged, _bytes} =
               JsonSafe.encode_bounded(%{invalid_key => "v"}, max_key_bytes: 10)

      assert [tagged_key] = Map.keys(tagged)
      assert tagged_key =~ "<<invalid-utf8:"
      assert tagged_key =~ ":trunc-20>>"

      # Inspect-rendered keys take the same clamp.
      assert {:ok, pid_out, _bytes} = JsonSafe.encode_bounded(%{self() => "v"}, max_key_bytes: 4)
      assert [pid_key] = Map.keys(pid_out)
      assert pid_key =~ ~r/:trunc-\d+$/

      # The zero edge: the draw floors at the empty prefix.
      assert {:ok, zero_out, _bytes} =
               JsonSafe.encode_bounded(%{valid_key => "v"}, max_key_bytes: 0)

      assert zero_out == %{":trunc-20" => "v"}
    end

    test "junk budget options normalize to the pinned defaults (no raise, no full-key scan)" do
      key = <<255>> <> :binary.copy(<<254>>, 2047)
      default_result = JsonSafe.encode_bounded(%{key => "v"})

      assert {:ok, _out, _bytes} = default_result
      assert JsonSafe.encode_bounded(%{key => "v"}, max_key_bytes: 0.5) == default_result
      assert JsonSafe.encode_bounded(%{key => "v"}, max_key_bytes: :infinity) == default_result
    end
  end

  describe "encode_bounded/2 — bignum width charge" do
    test "a single huge integer trips the budget BEFORE Jason, at a true lower bound" do
      assert {:budget_exceeded, %{observed_at_least: n}} =
               JsonSafe.encode_bounded(%{big: Integer.pow(10, 200_000)})

      # The charge is a provable LOWER bound of the decimal render — the
      # reported floor never exceeds the true observable width.
      assert n <= 200_001
    end

    test "in-range integers stay uncharged-exact" do
      assert JsonSafe.encode_bounded(%{n: 12_345}) == {:ok, %{"n" => 12_345}, 1}
    end

    test "a below-threshold bignum is genuinely charged, not near-zero" do
      big = Integer.pow(10, 30)
      assert {:ok, %{"m" => ^big}, bytes} = JsonSafe.encode_bounded(%{m: big})
      # external_size 17 → charge 2 × (17 − 8) = 18 (+1 key byte).
      assert bytes >= 18
    end

    test "the first out-of-range negative and the worst-ratio case carry their floor charge" do
      threshold = -9_223_372_036_854_775_809
      assert {:ok, %{"t" => ^threshold}, t_bytes} = JsonSafe.encode_bounded(%{t: threshold})
      assert t_bytes >= 8

      worst = -(Integer.pow(2, 64) - 1)
      assert {:ok, %{"w" => ^worst}, w_bytes} = JsonSafe.encode_bounded(%{w: worst})
      # 8-byte magnitude, external_size 12, charge 8 vs a 21-char render —
      # exactly the documented 2.625x slip cap.
      assert w_bytes >= 8
    end

    test "aggregated moderate bignums trip the DEFAULT budget (the aggregate-slip regression)" do
      # 40k × 18-byte charges ≈ 720 KB > 128 KiB — the rejected −16 header
      # allowance charged these near-zero and passed ~1.2 MB straight to
      # Jason.
      list = List.duplicate(Integer.pow(10, 30), 40_000)
      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(list)
    end
  end

  describe "encode_bounded/2 — calendar fast-path gate" do
    test "well-formed ISO calendar values keep their byte-identical ISO-8601 render" do
      assert {:ok, "2026-07-13", _bytes} = JsonSafe.encode_bounded(~D[2026-07-13])

      assert {:ok, "2026-07-13T12:00:00Z", _bytes} =
               JsonSafe.encode_bounded(~U[2026-07-13 12:00:00Z])

      assert {:ok, "2026-07-13T12:00:00", _bytes} =
               JsonSafe.encode_bounded(~N[2026-07-13 12:00:00])
    end

    test "a hostile-year ISO date refuses the fast path and trips via the bignum charge" do
      hostile = %{
        __struct__: Date,
        calendar: Calendar.ISO,
        year: Integer.pow(10, 200_000),
        month: 1,
        day: 1
      }

      {elapsed_us, result} = :timer.tc(fn -> JsonSafe.encode_bounded(hostile) end)

      # Charged via the generic struct walk + the bignum rule — the
      # decimal is never rendered.
      assert {:budget_exceeded, _info} = result
      assert elapsed_us < 5_000_000
    end

    test "a non-ISO calendar takes the structural walk — no callback ever dispatches" do
      # NotACalendar defines NO calendar callbacks: a conversion attempt
      # would have raised into guard_leaf's "[unencodable]", which the
      # structural shape excludes — proof by construction of no dispatch
      # (the calendar module atom itself drops as a map value).
      custom = %{__struct__: Date, calendar: NotACalendar, year: 1, month: 1, day: 1}

      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(custom)
      assert out == %{"year" => 1, "month" => 1, "day" => 1}
    end
  end

  describe "encode_bounded/2 — key markers + collision sentinel" do
    test "int64-range integer keys render exactly" do
      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{1 => "a", -42 => "b"})
      assert out == %{"1" => "a", "-42" => "b"}
    end

    test "an out-of-int64-range integer key takes the constant bigint marker" do
      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{Integer.pow(2, 64) => "v"})
      assert out == %{"<<key:bigint>>" => "v"}
    end

    test "composite keys take per-class markers; distinct classes coexist" do
      assert {:ok, out, _bytes} =
               JsonSafe.encode_bounded(%{
                 {:a, 1} => "t",
                 [1] => "l",
                 %{x: 1} => "m"
               })

      assert out == %{
               "<<key:tuple>>" => "t",
               "<<key:list>>" => "l",
               "<<key:map>>" => "m"
             }
    end

    test "a hostile-Inspect struct key takes the module marker — Inspect NEVER runs" do
      # Under the old fallback this would have been "[uninspectable]" (the
      # throw swallowed by safe_inspect); the marker proves no dispatch.
      assert {:ok, out, _bytes} =
               JsonSafe.encode_bounded(%{%HostileInspect.Throwing{x: 1} => "s"})

      assert out == %{"<<key:struct:#{inspect(HostileInspect.Throwing)}>>" => "s"}
    end

    test "large shared-prefix composite keys collide via markers — never walked or compared" do
      prefix = Enum.to_list(1..100_000)
      key_a = Enum.concat(prefix, [:a])
      key_b = Enum.concat(prefix, [:b])

      # DEFAULT budgets: marker encoding is O(1) per key and no sort
      # exists, so the 100k-element originals never cost traversal.
      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{key_a => "a", key_b => "b"})
      assert out == %{"<<key:list>>" => "[key-collision]"}
    end

    test "a pid key keeps its bounded built-in render" do
      assert {:ok, out, _bytes} = JsonSafe.encode_bounded(%{self() => "v"})
      assert [key] = Map.keys(out)
      assert key =~ "#PID<"
    end

    test "the collision sentinel is charged exactly, as a rendered leaf" do
      # Keys "1" (from integer 1) and "1" (string) collide: key bytes
      # 1 + 1 plus the 15-byte sentinel = 17 exactly (numbers cost no
      # bytes, so the totals are exact).
      colliding = %{1 => 0, "1" => 0}

      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(colliding, max_bytes: 16)

      assert JsonSafe.encode_bounded(colliding, max_bytes: 17) ==
               {:ok, %{"1" => "[key-collision]"}, 17}
    end

    test "a triple collision charges the sentinel ONCE" do
      # Integer 1, atom :"1", and string "1" all encode to "1": key bytes
      # 1 + 1 + 1 plus ONE sentinel = 18 (not 33).
      colliding = %{1 => 0, :"1" => 0, "1" => 0}

      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(colliding, max_bytes: 17)

      assert JsonSafe.encode_bounded(colliding, max_bytes: 18) ==
               {:ok, %{"1" => "[key-collision]"}, 18}
    end

    test "bulk collisions under a tight byte budget trip — never unaccounted sentinel output" do
      colliding =
        Enum.reduce(1..2_000, %{}, fn i, acc ->
          Map.put(Map.put(acc, i, 0), "#{i}", 0)
        end)

      assert {:budget_exceeded, _info} = JsonSafe.encode_bounded(colliding, max_bytes: 1024)
    end
  end

  describe "fingerprint_projection/2" do
    test "numbers, binaries, and runtime identities collapse to class markers" do
      assert {:ok, {:map, pairs}, _bytes} =
               JsonSafe.fingerprint_projection(%{
                 n: 42,
                 s: "secret-text",
                 p: self(),
                 r: make_ref(),
                 f: fn -> :x end
               })

      assert {:n, :num} in pairs
      assert {:s, :bin} in pairs
      assert {:p, :pid} in pairs
      assert {:r, :ref} in pairs
      assert {:f, :fun} in pairs
    end

    test "exact_keys values stay exact and bounded; other strings collapse" do
      assert {:ok, {:map, pairs}, _bytes} =
               JsonSafe.fingerprint_projection(
                 %{skill: "my_skill", other: "hidden"},
                 exact_keys: ["skill"]
               )

      assert {:skill, "my_skill"} in pairs
      assert {:other, :bin} in pairs
    end

    test "structs and tuples keep tagged shape; map pairs sort deterministically" do
      assert {:ok, projection_a, _} =
               JsonSafe.fingerprint_projection(%{b: {:exit, 1}, a: "x"})

      assert {:ok, projection_b, _} =
               JsonSafe.fingerprint_projection(%{a: "x", b: {:exit, 1}})

      assert projection_a == projection_b
      assert {:map, pairs} = projection_a
      assert {:b, {:tuple, [:exit, :num]}} in pairs
    end

    test "a budget trip yields the pinned contract shape" do
      huge = Map.new(1..100_000, fn i -> {i, i} end)

      assert {:budget_exceeded, %{observed_at_least: n}} =
               JsonSafe.fingerprint_projection(huge, max_nodes: 100)

      assert is_integer(n)
    end
  end
end
