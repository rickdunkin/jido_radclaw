defmodule JidoClaw.Web.SetupLiveTest do
  @moduledoc """
  Direct-socket/direct-render test of the setup wizard's step switcher. The
  "step" `handle_event` uses explicit literal clauses (no `String.to_atom` on
  params), so each known step sets `@step` to its atom and any unknown value is
  a no-op via the catch-all. The tab strip is a `for` comprehension, so all
  three tabs render with their atom keys round-tripped to the param strings.
  """
  use ExUnit.Case, async: false

  alias JidoClaw.Web.SetupLive
  alias JidoClaw.Web.SetupStatusCache
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.AsyncResult

  defmodule WizardStub do
    @moduledoc false

    @spec run() :: map()
    def run do
      target = Application.fetch_env!(:jido_claw, :setup_cache_test_target)
      send(target, {:wizard_run, self()})

      case Application.get_env(:jido_claw, :setup_cache_test_behavior, :return) do
        :return -> :ok
        :wait -> receive do: (:release -> :ok)
        {:sleep, milliseconds} -> Process.sleep(milliseconds)
      end

      Application.fetch_env!(:jido_claw, :setup_cache_test_status)
    end
  end

  setup do
    previous_impl = Application.fetch_env(:jido_claw, :setup_wizard_impl)
    previous_target = Application.fetch_env(:jido_claw, :setup_cache_test_target)
    previous_status = Application.fetch_env(:jido_claw, :setup_cache_test_status)
    previous_behavior = Application.fetch_env(:jido_claw, :setup_cache_test_behavior)
    previous_cache = Application.fetch_env(:jido_claw, :setup_status_cache)

    Application.put_env(:jido_claw, :setup_wizard_impl, WizardStub)
    Application.put_env(:jido_claw, :setup_cache_test_target, self())
    Application.put_env(:jido_claw, :setup_cache_test_status, fake_status())
    Application.put_env(:jido_claw, :setup_cache_test_behavior, :return)

    Application.put_env(:jido_claw, :setup_status_cache,
      ttl_ms: 60_000,
      min_refresh_ms: 60_000,
      probe_timeout_ms: 500
    )

    :ok = SetupStatusCache.reset()

    on_exit(fn ->
      restore_env(:setup_wizard_impl, previous_impl)
      restore_env(:setup_cache_test_target, previous_target)
      restore_env(:setup_cache_test_status, previous_status)
      restore_env(:setup_cache_test_behavior, previous_behavior)
      restore_env(:setup_status_cache, previous_cache)
      SetupStatusCache.reset()
    end)

    :ok
  end

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
      %{
        __changed__: %{},
        step: :prerequisites,
        status: AsyncResult.ok(fake_status())
      }
      |> SetupLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    # The comprehension's atom keys round-trip to exactly the strings the literal
    # `handle_event("step", …)` clauses match.
    assert html =~ ~s(phx-value-step="prerequisites")
    assert html =~ ~s(phx-value-step="credentials")
    assert html =~ ~s(phx-value-step="database")
  end

  test "setup checks are cached and manual refreshes are throttled" do
    assert SetupStatusCache.fetch() == {:ok, fake_status()}
    assert_receive {:wizard_run, _pid}

    assert SetupStatusCache.fetch() == {:ok, fake_status()}
    assert SetupStatusCache.refresh() == {:ok, fake_status()}
    refute_receive {:wizard_run, _pid}
  end

  test "concurrent stale callers coalesce behind one off-process probe" do
    Application.put_env(:jido_claw, :setup_cache_test_behavior, :wait)

    first = Task.async(&SetupStatusCache.fetch/0)
    second = Task.async(&SetupStatusCache.fetch/0)

    assert_receive {:wizard_run, probe_pid}
    refute_receive {:wizard_run, _other_pid}, 50
    send(probe_pid, :release)

    assert Task.await(first) == {:ok, fake_status()}
    assert Task.await(second) == {:ok, fake_status()}
  end

  test "a probe deadline returns the last known good status and leaves the cache responsive" do
    assert {:ok, status} = SetupStatusCache.fetch()
    assert_receive {:wizard_run, _pid}

    Application.put_env(:jido_claw, :setup_cache_test_behavior, :wait)

    Application.put_env(:jido_claw, :setup_status_cache,
      ttl_ms: 1,
      min_refresh_ms: 1,
      probe_timeout_ms: 50
    )

    Process.sleep(2)
    assert {:ok, ^status} = SetupStatusCache.fetch()
    assert_receive {:wizard_run, _probe_pid}
    assert Process.alive?(Process.whereis(SetupStatusCache))

    Application.put_env(:jido_claw, :setup_cache_test_behavior, :return)
    Process.sleep(2)
    assert {:ok, ^status} = SetupStatusCache.refresh()
    assert_receive {:wizard_run, _pid}
  end

  test "mount assigns diagnostics asynchronously instead of probing inline" do
    Application.put_env(:jido_claw, :setup_cache_test_behavior, :wait)

    assert {:ok, socket} =
             SetupLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    assert %AsyncResult{loading: loading, ok?: false} = socket.assigns.status
    assert loading
    refute_receive {:wizard_run, _pid}
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

  defp restore_env(key, :error), do: Application.delete_env(:jido_claw, key)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_claw, key, value)
end
