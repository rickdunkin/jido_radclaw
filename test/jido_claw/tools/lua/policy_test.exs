defmodule JidoClaw.Tools.Lua.PolicyTest do
  # async: false — the config-resolution cases mutate the `:lua` app env;
  # everything else takes explicit opts.
  use ExUnit.Case, async: false

  alias JidoClaw.Tools.Lua.Policy

  describe "resolve/1 defaults" do
    test "empty opts yield the documented defaults" do
      policy = Policy.resolve([])

      assert policy.timeout_ms == 1_500
      assert policy.max_calls == 12
      assert policy.max_call_depth == 64
      assert policy.max_script_bytes == 6_000
      assert policy.max_heap_bytes == 64 * 1024 * 1024
      assert policy.max_instructions == 10_000_000
      assert policy.max_string_bytes == 8 * 1024 * 1024
      assert policy.max_result_bytes == 32_768
    end

    test "default max_string_bytes stays below default max_heap_bytes" do
      policy = Policy.resolve([])
      assert policy.max_string_bytes < policy.max_heap_bytes
    end

    test "max_string_bytes ceiling stays below the max_heap_bytes floor (structural invariant)" do
      # Even at the extreme clamps the VM's own warning holds: the string
      # ceiling (32 MiB) is under the heap floor (64 MiB).
      hostile = Policy.resolve(max_string_bytes: 1_000_000_000, max_heap_bytes: 1)
      assert hostile.max_string_bytes < hostile.max_heap_bytes
    end
  end

  describe "resolve/1 clamps (both ends per cap)" do
    test "timeout_ms clamps to 100..5_000" do
      assert Policy.resolve(timeout_ms: 1).timeout_ms == 100
      assert Policy.resolve(timeout_ms: 99_999).timeout_ms == 5_000
      assert Policy.resolve(timeout_ms: 2_000).timeout_ms == 2_000
    end

    test "max_calls clamps to 1..25" do
      assert Policy.resolve(max_calls: 0).max_calls == 1
      assert Policy.resolve(max_calls: 500).max_calls == 25
      assert Policy.resolve(max_calls: 5).max_calls == 5
    end

    test "max_call_depth clamps to 4..256" do
      assert Policy.resolve(max_call_depth: 1).max_call_depth == 4
      assert Policy.resolve(max_call_depth: 10_000).max_call_depth == 256
    end

    test "max_script_bytes clamps to 256..100_000" do
      assert Policy.resolve(max_script_bytes: 1).max_script_bytes == 256
      assert Policy.resolve(max_script_bytes: 10_000_000).max_script_bytes == 100_000
    end

    test "max_heap_bytes clamps to 64MiB..512MiB" do
      assert Policy.resolve(max_heap_bytes: 1).max_heap_bytes == 64 * 1024 * 1024

      assert Policy.resolve(max_heap_bytes: 10 * 1024 * 1024 * 1024).max_heap_bytes ==
               512 * 1024 * 1024
    end

    test "max_instructions clamps to 100_000..100_000_000" do
      assert Policy.resolve(max_instructions: 1).max_instructions == 100_000
      assert Policy.resolve(max_instructions: 999_999_999_999).max_instructions == 100_000_000
    end

    test "max_string_bytes clamps to 64KiB..32MiB" do
      assert Policy.resolve(max_string_bytes: 1).max_string_bytes == 64 * 1024
      assert Policy.resolve(max_string_bytes: 1_000_000_000).max_string_bytes == 32 * 1024 * 1024
    end

    test "max_result_bytes clamps to 4_096..262_144" do
      assert Policy.resolve(max_result_bytes: 1).max_result_bytes == 4_096
      assert Policy.resolve(max_result_bytes: 10_000_000).max_result_bytes == 262_144
    end

    test "non-integer values fall back to defaults, never disable a cap" do
      policy = Policy.resolve(timeout_ms: "fast", max_calls: nil, max_instructions: :infinity)

      assert policy.timeout_ms == 1_500
      assert policy.max_calls == 12
      assert policy.max_instructions == 10_000_000
    end
  end

  describe "resolve/1 config resolution" do
    setup do
      original = Application.get_env(:jido_claw, :lua)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_claw, :lua)
          value -> Application.put_env(:jido_claw, :lua, value)
        end
      end)

      :ok
    end

    test "app config overrides defaults" do
      Application.put_env(:jido_claw, :lua, timeout_ms: 3_000, max_calls: 20)

      policy = Policy.resolve([])
      assert policy.timeout_ms == 3_000
      assert policy.max_calls == 20
      # untouched keys keep their defaults
      assert policy.max_script_bytes == 6_000
    end

    test "explicit opts override app config" do
      Application.put_env(:jido_claw, :lua, timeout_ms: 3_000)

      assert Policy.resolve(timeout_ms: 500).timeout_ms == 500
    end

    test "config values are clamped too" do
      Application.put_env(:jido_claw, :lua, timeout_ms: 999_999)

      assert Policy.resolve([]).timeout_ms == 5_000
    end
  end

  describe "validate_script/2" do
    test "accepts a normal script" do
      assert Policy.validate_script("return 1 + 1", Policy.resolve([])) == :ok
    end

    test "rejects empty and whitespace-only scripts" do
      policy = Policy.resolve([])

      assert Policy.validate_script("", policy) == {:error, :lua_empty_script}
      assert Policy.validate_script("   \n\t ", policy) == {:error, :lua_empty_script}
    end

    test "rejects a script over max_script_bytes with sizes in the error" do
      policy = Policy.resolve(max_script_bytes: 256)
      script = String.duplicate("x", 300)

      assert Policy.validate_script(script, policy) ==
               {:error, {:lua_script_too_large, 300, 256}}
    end
  end

  describe "public/1" do
    test "echoes every cap as a string-keyed wire map" do
      public = Policy.public(Policy.resolve([]))

      assert public["mode"] == "read_only"
      assert public["timeout_ms"] == 1_500
      assert public["max_calls"] == 12
      assert public["max_call_depth"] == 64
      assert public["max_script_bytes"] == 6_000
      assert public["max_heap_bytes"] == 64 * 1024 * 1024
      assert public["max_instructions"] == 10_000_000
      assert public["max_string_bytes"] == 8 * 1024 * 1024
      assert public["max_result_bytes"] == 32_768
      assert public["sandbox"] =~ "print"
    end

    test "is JSON-encodable" do
      assert {:ok, _} = Jason.encode(Policy.public(Policy.resolve([])))
    end
  end
end
