defmodule JidoClaw.Agent.Handoff.Registry do
  @moduledoc """
  Hot-path registry that maps `{tenant_id, runtime_session_id}` to the
  current handoff owner.

  The registry is the source of truth for *which worker template* handles
  the next user turn for a given session. It is updated when
  `JidoClaw.Tools.Handoff.run/2` succeeds and consulted at dispatch time
  by `JidoClaw.Agent.Handoff.Router.resolve_session_owner/6`.

  An owner record is shaped as:

      %{
        template: String.t(),
        module: module(),
        handoff: JidoClaw.Agent.Handoff.t(),
        updated_at_ms: integer(),
        preamble_consumed?: boolean(),
        prompt_injected?: boolean()
      }

    * `:preamble_consumed?` — toggled to `true` after the first
      post-handoff user turn successfully dispatches with the
      handoff preamble. Cold-start hydration paths set this to `true`
      from the start because the original handoff message is gone.
    * `:prompt_injected?` — toggled to `true` once `Startup.inject_system_prompt/3`
      has successfully primed the worker pid with the project prompt.
      Retries on failure (kept `false`).

  Callers construct a `%JidoClaw.Agent.Handoff{}` and pass that — the
  registry assembles the owner map internally so the boolean flags
  cannot drift.
  """

  use GenServer

  alias JidoClaw.Agent.Handoff

  @type key :: {String.t(), String.t()}
  @type owner :: %{
          template: String.t(),
          module: module(),
          handoff: Handoff.t(),
          updated_at_ms: integer(),
          preamble_consumed?: boolean(),
          prompt_injected?: boolean()
        }

  # ---- Public API ----

  @doc "Start the registry. Singleton — named after the module."
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Return the current owner record for `{tenant, session}` or `nil`."
  @spec owner(String.t(), String.t()) :: owner() | nil
  def owner(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    GenServer.call(__MODULE__, {:owner, {tenant_id, runtime_session_id}})
  end

  @doc """
  Install a fresh handoff owner. Convenience for the Tool's call site —
  no opts means both flags default to `false`.
  """
  @spec put_owner(String.t(), String.t(), Handoff.t()) :: :ok
  def put_owner(tenant_id, runtime_session_id, %Handoff{} = handoff) do
    put_owner(tenant_id, runtime_session_id, handoff, [])
  end

  @doc """
  Install a handoff owner with explicit flags.

  Opts:

    * `:preamble_consumed?` — `true` skips the preamble on the next turn.
      Used by cold-start hydration paths (the original message is gone).
    * `:prompt_injected?` — `true` skips the next `inject_system_prompt`.
      The Router sets this after a successful injection.
  """
  @spec put_owner(String.t(), String.t(), Handoff.t(), keyword()) :: :ok
  def put_owner(tenant_id, runtime_session_id, %Handoff{} = handoff, opts)
      when is_binary(tenant_id) and is_binary(runtime_session_id) and is_list(opts) do
    GenServer.call(
      __MODULE__,
      {:put_owner, {tenant_id, runtime_session_id}, handoff, opts}
    )
  end

  @doc "Mark the handoff preamble as consumed for `{tenant, session}`. No-op if absent."
  @spec mark_preamble_consumed(String.t(), String.t()) :: :ok
  def mark_preamble_consumed(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    GenServer.call(
      __MODULE__,
      {:mark_preamble_consumed, {tenant_id, runtime_session_id}}
    )
  end

  @doc "Mark the worker's system prompt as injected. No-op if absent."
  @spec mark_prompt_injected(String.t(), String.t()) :: :ok
  def mark_prompt_injected(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    GenServer.call(
      __MODULE__,
      {:mark_prompt_injected, {tenant_id, runtime_session_id}}
    )
  end

  @doc "Remove the owner record. Idempotent."
  @spec clear(String.t(), String.t()) :: :ok
  def clear(tenant_id, runtime_session_id)
      when is_binary(tenant_id) and is_binary(runtime_session_id) do
    GenServer.call(__MODULE__, {:clear, {tenant_id, runtime_session_id}})
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(_state) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:owner, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call({:put_owner, key, %Handoff{} = handoff, opts}, _from, state) do
    owner = %{
      template: handoff.to_template,
      module: handoff.to_module,
      handoff: handoff,
      updated_at_ms: System.system_time(:millisecond),
      preamble_consumed?: Keyword.get(opts, :preamble_consumed?, false),
      prompt_injected?: Keyword.get(opts, :prompt_injected?, false)
    }

    {:reply, :ok, Map.put(state, key, owner)}
  end

  def handle_call({:mark_preamble_consumed, key}, _from, state) do
    new_state =
      case Map.get(state, key) do
        nil -> state
        owner -> Map.put(state, key, %{owner | preamble_consumed?: true})
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:mark_prompt_injected, key}, _from, state) do
    new_state =
      case Map.get(state, key) do
        nil -> state
        owner -> Map.put(state, key, %{owner | prompt_injected?: true})
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:clear, key}, _from, state) do
    {:reply, :ok, Map.delete(state, key)}
  end
end
