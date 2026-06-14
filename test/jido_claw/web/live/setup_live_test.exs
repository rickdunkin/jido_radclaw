defmodule JidoClaw.Web.SetupLiveTest do
  @moduledoc """
  Direct-socket/direct-render test of the setup wizard's step switcher. The
  "step" `handle_event` uses explicit literal clauses (no `String.to_atom` on
  params), so each known step sets `@step` to its atom and any unknown value is
  a no-op via the catch-all. The tab strip is a `for` comprehension, so all
  three tabs render with their atom keys round-tripped to the param strings.
  """
  use ExUnit.Case, async: true

  alias JidoClaw.Web.SetupLive
  alias Phoenix.HTML.Safe

  describe ~s(handle_event "step") do
    test "sets @step to :prerequisites for the prerequisites param" do
      assert {:noreply, updated} =
               SetupLive.handle_event(
                 "step",
                 %{"step" => "prerequisites"},
                 build_socket(:database)
               )

      assert updated.assigns.step == :prerequisites
    end

    test "sets @step to :credentials for the credentials param" do
      assert {:noreply, updated} =
               SetupLive.handle_event(
                 "step",
                 %{"step" => "credentials"},
                 build_socket(:prerequisites)
               )

      assert updated.assigns.step == :credentials
    end

    test "sets @step to :database for the database param" do
      assert {:noreply, updated} =
               SetupLive.handle_event(
                 "step",
                 %{"step" => "database"},
                 build_socket(:prerequisites)
               )

      assert updated.assigns.step == :database
    end

    test "an unknown step value is a no-op (step unchanged)" do
      assert {:noreply, updated} =
               SetupLive.handle_event("step", %{"step" => "bogus"}, build_socket(:credentials))

      assert updated.assigns.step == :credentials
    end
  end

  test "render emits all three tab buttons with their param strings" do
    html =
      %{__changed__: %{}, step: :prerequisites, status: fake_status()}
      |> SetupLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    # The comprehension's atom keys round-trip to exactly the strings the literal
    # `handle_event("step", …)` clauses match.
    assert html =~ ~s(phx-value-step="prerequisites")
    assert html =~ ~s(phx-value-step="credentials")
    assert html =~ ~s(phx-value-step="database")
  end

  # -- Helpers --

  defp build_socket(step) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, step: step}}
  end

  # Minimal stand-in for `Wizard.run/0`'s status — the tab strip depends only on
  # @step, so the surrounding cards just need non-crashing shapes.
  defp fake_status do
    %{
      prerequisites: [],
      credentials: [],
      database: %{ok?: true, status: "connected"},
      ready?: false,
      has_ai_provider?: true
    }
  end
end
