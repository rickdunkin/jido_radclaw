defmodule JidoClaw.Tools.Lua.CallTrace do
  @moduledoc """
  Per-eval audit trail of `jido.*` host-binding calls.

  Ported from jidoka `lib/jidoka/workflow/lua/call_trace.ex` @ 9469dc09
  (Apache-2.0): the Agent + reserve/complete/calls shape is verbatim.
  Two local deviations:

    * a `refused?/1` flag, set the moment `reserve/4` refuses at the
      call budget, so the Runner classifies the resulting abort as
      `:lua_call_budget_exceeded` **post-eval** without error-string
      sniffing — an in-script `pcall` can swallow the refusal raise,
      but it cannot unset this flag;
    * bounded records — `arguments` is a ~200-byte inspect preview
      and `output` a count/bytes summary, never full data. The trace
      rides back in the LLM-facing result envelope, and script-generated
      arguments can approach `max_string_bytes`.

  The Agent is owned by the tool process (not the eval task), so a
  killed eval leaves a readable partial audit (`"started"` rows).
  """

  alias JidoClaw.Tools.OutputLimit

  @args_preview_bytes 200

  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> %{calls: [], count: 0, next_id: 1, refused?: false} end)
  end

  # `state.calls` is stored newest-first (prepend); read back chronological.
  @spec calls(pid()) :: [map()]
  def calls(pid) do
    Agent.get(pid, fn state ->
      state.calls
      |> Enum.reverse()
      |> Enum.map(&Map.delete(&1, :id))
    end)
  end

  @doc """
  True once any `reserve/4` was refused at the call budget. Checked by
  the Runner after eval — the not-swallowable half of budget refusal.
  """
  @spec refused?(pid()) :: boolean()
  def refused?(pid), do: Agent.get(pid, & &1.refused?)

  @spec reserve(pid(), String.t(), term(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, {:lua_call_budget_exceeded, pos_integer()}}
  def reserve(pid, binding, arguments, max_calls) do
    preview = preview_args(arguments)

    Agent.get_and_update(pid, fn state ->
      if state.count >= max_calls do
        {{:error, {:lua_call_budget_exceeded, max_calls}}, %{state | refused?: true}}
      else
        call_id = state.next_id
        pending = call_record(call_id, binding, preview, "started", nil)

        next_state = %{
          state
          | calls: [pending | state.calls],
            count: state.count + 1,
            next_id: call_id + 1
        }

        {{:ok, call_id}, next_state}
      end
    end)
  end

  @spec complete(pid(), pos_integer(), String.t(), term()) :: :ok
  def complete(pid, call_id, status, output) do
    summary = summarize_output(output)

    Agent.update(pid, fn state ->
      calls =
        Enum.map(state.calls, fn
          %{id: ^call_id} = call -> %{call | "status" => status, "output" => summary}
          call -> call
        end)

      %{state | calls: calls}
    end)
  end

  defp call_record(call_id, binding, preview, status, output) do
    %{
      :id => call_id,
      "binding" => binding,
      "arguments" => preview,
      "status" => status,
      "output" => output
    }
  end

  defp preview_args(arguments) do
    rendered = inspect(arguments, limit: 20, printable_limit: @args_preview_bytes)

    if byte_size(rendered) > @args_preview_bytes do
      rendered
      |> binary_part(0, @args_preview_bytes)
      |> OutputLimit.valid_utf8_prefix()
      |> Kernel.<>("…")
    else
      rendered
    end
  end

  # Summaries only — the script's own return value is the data channel;
  # the trace is an audit line. Never records full output.
  defp summarize_output(nil), do: nil
  defp summarize_output(list) when is_list(list), do: %{"count" => length(list)}
  defp summarize_output(bin) when is_binary(bin), do: %{"bytes" => byte_size(bin)}
  defp summarize_output(other), do: %{"bytes" => :erlang.external_size(other)}
end
