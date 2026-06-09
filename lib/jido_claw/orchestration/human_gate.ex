defmodule JidoClaw.Orchestration.HumanGate do
  @moduledoc """
  The consumer base for human approval gate modules.

  `use JidoClaw.Orchestration.HumanGate` brings in the gate-definition Spark
  DSL (`JidoClaw.Orchestration.Gate.Dsl` — `gate do ... end`) and injects the
  `JidoClaw.Orchestration.Gates` notification behaviour with overridable
  no-op defaults for `after_approved/1` / `after_rejected/1`:

      defmodule MyApp.Gates.DeployGate do
        use JidoClaw.Orchestration.HumanGate

        gate do
          kind(:irreversible_write)
          title("Approve production deploy")
        end

        @impl JidoClaw.Orchestration.Gates
        def after_approved(ctx), do: notify_somewhere(ctx)
      end

  The gate's kind/title/fields are declarative data read back through
  `JidoClaw.Orchestration.Gate.Info` (there is no `kind/0` callback — the DSL
  supersedes it); the two hooks stay plain behaviour callbacks because they
  are code, dispatched best-effort by `JidoClaw.Orchestration.Cases`
  (Decision 8 — never durable steps).
  """

  use Spark.Dsl, default_extensions: [extensions: [JidoClaw.Orchestration.Gate.Dsl]]

  @impl Spark.Dsl
  def handle_before_compile(_opts) do
    quote do
      @behaviour JidoClaw.Orchestration.Gates

      @impl JidoClaw.Orchestration.Gates
      def after_approved(_context), do: :ok

      @impl JidoClaw.Orchestration.Gates
      def after_rejected(_context), do: :ok

      defoverridable after_approved: 1, after_rejected: 1
    end
  end
end
