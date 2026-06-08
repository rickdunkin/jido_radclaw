defmodule JidoClaw.Orchestration.Gates do
  @moduledoc """
  Behaviour for human approval gate modules.

  A gate module declares its `kind` and supplies best-effort notification
  hooks. `use JidoClaw.Orchestration.Gates, kind: :irreversible_write` injects
  default `kind/0`, `field_metadata/0`, and `presentation/0` implementations;
  the module must still define `after_approved/1` and `after_rejected/1`.

  ## Hooks are notifications, not durable steps (Decision 8)

  `after_approved/1` / `after_rejected/1` are **best-effort** side-effects that
  fire **once, on the operator decision path** (post-commit, logged on
  failure). They are **NOT** crash-exactly-once: on the boot-recovery resume
  path they are **skipped** entirely (the decision already committed; re-running
  the reactor performs the durable work). Durable, must-happen work belongs in
  the reactor's downstream steps, which resume durably — never in a hook.

  **No Spark DSL** — the gate-definition DSL (T2-5) is a deferred follow-up.
  """

  alias JidoClaw.Orchestration.GateContext

  @doc "The gate kind, mirrored onto the `AgentCase.kind` column."
  @callback kind() :: atom()

  @doc "Best-effort notification fired once after an operator approves."
  @callback after_approved(GateContext.t()) :: :ok | {:error, term()}

  @doc "Best-effort notification fired once after an operator rejects."
  @callback after_rejected(GateContext.t()) :: :ok | {:error, term()}

  @doc "Optional operator-facing field metadata (default `%{}`)."
  @callback field_metadata() :: map()

  @doc "Optional operator-facing presentation hints (default `%{}`)."
  @callback presentation() :: map()

  @optional_callbacks field_metadata: 0, presentation: 0

  defmacro __using__(opts) do
    kind = Keyword.get(opts, :kind, :irreversible_write)

    quote do
      @behaviour JidoClaw.Orchestration.Gates

      @impl JidoClaw.Orchestration.Gates
      def kind, do: unquote(kind)

      @impl JidoClaw.Orchestration.Gates
      def field_metadata, do: %{}

      @impl JidoClaw.Orchestration.Gates
      def presentation, do: %{}

      defoverridable kind: 0, field_metadata: 0, presentation: 0
    end
  end
end
