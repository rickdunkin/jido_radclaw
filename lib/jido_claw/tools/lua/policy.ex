defmodule JidoClaw.Tools.Lua.Policy do
  @moduledoc """
  Execution caps for the `lua_query` sandbox.

  Ported from jidoka `lib/jidoka/workflow/lua/policy.ex` @ 9469dc09
  (Apache-2.0): the cap-struct + clamp-everything posture and the
  timeout / max-calls / call-depth / script-bytes defaults are verbatim.
  Local deviations: jidoka's catalog surface (`allowed_tools`/`entries`)
  is dropped (our binding table is fixed — `JidoClaw.Tools.Lua.Bindings`
  is the single source), and so is `max_parallel_calls` — the binding
  surface has no parallel host calls (every `jido.*` call runs inline in
  the single eval task). Added on top: `max_heap_bytes` (the
  `Jido.Tools.LuaEval` per-process heap kill), the lua 1.0 VM's
  deterministic budgets (`max_instructions`, `max_string_bytes`), and
  `max_result_bytes` — the aggregate result bound the Runner enforces
  (nothing downstream bounds a large structured map/list result:
  `OutputLimit` caps individual string leaves only and `OutputShaper`
  never shapes this tool).

  Every cap is clamped to a safe range; a non-integer (or absent) value
  falls back to its default, so bad config can degrade limits but never
  disable them. `max_string_bytes`' ceiling (32 MiB) stays below
  `max_heap_bytes`' floor (64 MiB) structurally — the VM's own warning:
  an oversized string must be *refused* deterministically, not caught by
  garbage-collection-timing-dependent heap kills.
  """

  @default_timeout_ms 1_500
  @default_max_calls 12
  @default_max_call_depth 64
  @default_max_script_bytes 6_000
  @default_max_heap_bytes 64 * 1024 * 1024
  @default_max_instructions 10_000_000
  @default_max_string_bytes 8 * 1024 * 1024
  @default_max_result_bytes 32_768

  @enforce_keys [
    :timeout_ms,
    :max_calls,
    :max_call_depth,
    :max_script_bytes,
    :max_heap_bytes,
    :max_instructions,
    :max_string_bytes,
    :max_result_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_calls: pos_integer(),
          max_call_depth: pos_integer(),
          max_script_bytes: pos_integer(),
          max_heap_bytes: pos_integer(),
          max_instructions: pos_integer(),
          max_string_bytes: pos_integer(),
          max_result_bytes: pos_integer()
        }

  @doc """
  Resolve the effective policy: explicit `opts` override the `:lua` app
  config, which overrides the in-module defaults — every value clamped.
  """
  @spec resolve(keyword()) :: t()
  def resolve(opts) when is_list(opts) do
    merged = Keyword.merge(Application.get_env(:jido_claw, :lua, []), opts)

    %__MODULE__{
      timeout_ms: clamp(merged[:timeout_ms], 100, 5_000, @default_timeout_ms),
      max_calls: clamp(merged[:max_calls], 1, 25, @default_max_calls),
      max_call_depth: clamp(merged[:max_call_depth], 4, 256, @default_max_call_depth),
      max_script_bytes: clamp(merged[:max_script_bytes], 256, 100_000, @default_max_script_bytes),
      max_heap_bytes:
        clamp(
          merged[:max_heap_bytes],
          @default_max_heap_bytes,
          512 * 1024 * 1024,
          @default_max_heap_bytes
        ),
      max_instructions:
        clamp(merged[:max_instructions], 100_000, 100_000_000, @default_max_instructions),
      max_string_bytes:
        clamp(merged[:max_string_bytes], 64 * 1024, 32 * 1024 * 1024, @default_max_string_bytes),
      max_result_bytes:
        clamp(merged[:max_result_bytes], 4_096, 262_144, @default_max_result_bytes)
    }
  end

  @doc """
  Pre-eval script validation: rejects blank scripts and scripts over
  `max_script_bytes` (no task is spawned on refusal).
  """
  @spec validate_script(String.t(), t()) ::
          :ok
          | {:error, :lua_empty_script | {:lua_script_too_large, pos_integer(), pos_integer()}}
  def validate_script(script, %__MODULE__{} = policy) when is_binary(script) do
    cond do
      String.trim(script) == "" ->
        {:error, :lua_empty_script}

      byte_size(script) > policy.max_script_bytes ->
        {:error, {:lua_script_too_large, byte_size(script), policy.max_script_bytes}}

      true ->
        :ok
    end
  end

  @doc """
  Operator/LLM-facing echo of the effective caps — the `lua_docs`
  policy block (the jidoka `public/1` shape, extended with our caps).
  """
  @spec public(t()) :: map()
  def public(%__MODULE__{} = policy) do
    %{
      "mode" => "read_only",
      "timeout_ms" => policy.timeout_ms,
      "max_calls" => policy.max_calls,
      "max_call_depth" => policy.max_call_depth,
      "max_script_bytes" => policy.max_script_bytes,
      "max_heap_bytes" => policy.max_heap_bytes,
      "max_instructions" => policy.max_instructions,
      "max_string_bytes" => policy.max_string_bytes,
      "max_result_bytes" => policy.max_result_bytes,
      "sandbox" => "lua_default + print + debug"
    }
  end

  # Clamp an integer into [lo, hi]; anything else falls back to the default.
  defp clamp(value, lo, hi, _default) when is_integer(value) do
    min(max(value, lo), hi)
  end

  defp clamp(_value, _lo, _hi, default), do: default
end
