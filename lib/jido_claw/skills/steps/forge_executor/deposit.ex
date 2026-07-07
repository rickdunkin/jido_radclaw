defmodule JidoClaw.Skills.Steps.ForgeExecutor.Deposit do
  @moduledoc """
  Per-step deposit box for a vendor executor session (executor-seam PR-2,
  decision 3 — the single accepted `typed_output` channel).

  One box per vendor step, started (linked) by the step process and registered
  under the step's deposit ref in `DepositRegistry`. The vendor CLI reaches it
  through the scoped MCP endpoint's `submit_structured_output` tool: a payload
  is Zoi-validated against the template's declared output contract
  (`Jido.AI.Output.parse/2` — maps AND binary JSON, string keys coerced) at
  deposit time. Valid ⇒ stored, last-valid-wins; invalid ⇒ a bounded
  structured tool error (MCP `isError`) so the CLI can fix the object and call
  again in-session — nothing stored. With NO declared contract (degenerate —
  all 16 real workers declare one) the raw map is accepted and stored: an
  explicit structured submission has nothing to drift from.

  `take/1` is a read-only peek the step uses after its single iteration; no
  deposit ⇒ `nil` — a lens stage rides the Verdict infra lane, a producer
  falls back to result text (both live-faithful, the PR-1 posture).
  `Verdict.normalize/2` stays at its existing `DefaultMapper` site — box
  validation is the deposit contract, the normalizer the fold backstop.

  Handlers are total over model input (never raise), so the link can't
  realistically fault the step; the client wrappers catch a dead/dying box
  (`:exit`) and degrade to the same no-deposit answers.
  """

  use GenServer

  alias Jido.AI.Output, as: AIOutput
  alias JidoClaw.Orchestration.Verdict

  @registry JidoClaw.Skills.Steps.ForgeExecutor.DepositRegistry
  @call_timeout_ms 15_000

  # -- Client -----------------------------------------------------------------

  @doc """
  Start a deposit box linked to the caller. Options: `:ref` (required — the
  registry key) and `:output` (the template's `%Jido.AI.Output{}` contract, or
  `nil` for the accept-and-store degenerate).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    ref = Keyword.fetch!(opts, :ref)
    output = Keyword.get(opts, :output)
    GenServer.start_link(__MODULE__, output, name: via(ref))
  end

  @doc """
  Validate + store a deposit payload. Returns `{:ok, %{status: :accepted}}` or
  `{:error, message}` (bounded — jido_mcp maps it to an `isError` tool result
  the CLI reads and retries on). Unknown/dead ref ⇒ the no-active-deposit
  error, never a raise (this runs on the MCP endpoint's request process).
  """
  @spec submit(String.t(), term()) :: {:ok, %{status: :accepted}} | {:error, String.t()}
  def submit(ref, payload) do
    case Registry.lookup(@registry, ref) do
      [{pid, _}] -> GenServer.call(pid, {:submit, payload}, @call_timeout_ms)
      _ -> {:error, no_deposit_message(ref)}
    end
  catch
    _, _ -> {:error, no_deposit_message(ref)}
  end

  @doc "Read-only peek at the last valid deposit — `nil` when none landed."
  @spec take(String.t()) :: map() | nil
  def take(ref) do
    case Registry.lookup(@registry, ref) do
      [{pid, _}] -> GenServer.call(pid, :take, @call_timeout_ms)
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  @doc "Gracefully stop the box (idempotent — an already-dead ref is `:ok`)."
  @spec stop(String.t()) :: :ok
  def stop(ref) do
    case Registry.lookup(@registry, ref) do
      [{pid, _}] -> GenServer.stop(pid, :normal, @call_timeout_ms)
      _ -> :ok
    end
  catch
    _, _ -> :ok
  end

  defp via(ref), do: {:via, Registry, {@registry, ref}}

  defp no_deposit_message(ref), do: "no active deposit for #{inspect(ref)}"

  # -- Server -----------------------------------------------------------------

  @impl GenServer
  def init(output) do
    {:ok, %{output: output, last_valid: nil, deposits: 0, invalids: 0}}
  end

  @impl GenServer
  def handle_call({:submit, payload}, _from, %{output: nil} = state) do
    # No declared contract: accept-and-store the raw payload (last-wins).
    {:reply, {:ok, %{status: :accepted}},
     %{state | last_valid: payload, deposits: state.deposits + 1}}
  end

  def handle_call({:submit, payload}, _from, %{output: output} = state) do
    case safe_parse(output, payload) do
      {:ok, typed} ->
        {:reply, {:ok, %{status: :accepted}},
         %{state | last_valid: typed, deposits: state.deposits + 1}}

      {:error, reason} ->
        # Bounded like Verdict.format_reason — garbage never becomes a huge
        # isError string the CLI has to wade through.
        {:reply, {:error, "output failed schema validation: " <> Verdict.format_reason(reason)},
         %{state | invalids: state.invalids + 1}}
    end
  end

  def handle_call(:take, _from, state), do: {:reply, state.last_valid, state}

  # Total over model input: a parse raise (pathological payload) counts as an
  # invalid deposit, never a box crash (the box is linked to the step).
  defp safe_parse(output, payload) do
    AIOutput.parse(output, payload)
  rescue
    # reach:disable-next-line bare_rescue
    e -> {:error, {:parse_raised, Exception.message(e)}}
  end
end
