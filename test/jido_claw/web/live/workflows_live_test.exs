defmodule JidoClaw.Web.WorkflowsLiveTest do
  @moduledoc """
  Direct-socket test (per `approvals_live_test.exs`) of the workflows page's
  Cancel button: the "cancel" `handle_event` routes through
  `Cancellation.cancel/2` and flashes the run's actual resulting status, and
  the button (with its `data-confirm`) renders only for cancellable rows. Also
  pins the `toggle_cell/1` refactor: the steps toggle rides on the 7 data cells
  (never the Actions cell), so each run row emits exactly 7 toggle bindings —
  and the WS6 ownership columns (Owner / Lease expires, expiry blanked on
  terminal rows).
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Orchestration.WorkflowLog
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Web.WorkflowsLive
  alias Phoenix.HTML.Safe

  setup do
    tenant = seed_tenant("workflows-live")
    {:ok, tenant: tenant, actor: actor_for(tenant)}
  end

  test "cancel handle_event cancels a :running run and flashes the resulting status", ctx do
    run = seed_running(ctx, "wf-cancel-me")

    socket = build_socket(%{user_id: Ecto.UUID.generate(), tenant_id: ctx.tenant})

    assert {:noreply, updated} = WorkflowsLive.handle_event("cancel", %{"id" => run.id}, socket)

    {:ok, cancelled} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
    assert cancelled.status == :cancelled
    assert Phoenix.Flash.get(updated.assigns.flash, :info) == "wf-cancel-me is now cancelled"
  end

  test "cancel of an already-finished run flashes the friendly refusal", ctx do
    run = seed_running(ctx, "wf-done")
    {:ok, _} = WorkflowLog.append(run, :run_completed, %{result: %{"ok" => true}})

    socket = build_socket(%{user_id: Ecto.UUID.generate(), tenant_id: ctx.tenant})

    assert {:noreply, updated} = WorkflowsLive.handle_event("cancel", %{"id" => run.id}, socket)

    assert Phoenix.Flash.get(updated.assigns.flash, :error) =~ "already finished"

    {:ok, still} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
    assert still.status == :completed
  end

  test "render shows Cancel (with data-confirm) only for non-terminal rows", ctx do
    running = seed_running(ctx, "wf-live")
    finished = seed_running(ctx, "wf-finished")
    {:ok, _} = WorkflowLog.append(finished, :run_completed, %{result: %{"ok" => true}})
    {:ok, done} = WorkflowRun.by_id(finished.id, tenant: ctx.tenant, actor: ctx.actor)

    html = render_runs([running, done])

    assert html =~ ~s(id="cancel-#{running.id}")
    assert html =~ "data-confirm="
    refute html =~ ~s(id="cancel-#{done.id}")
    # Terminal rows carry Replay instead — the two button sets are inverses.
    assert html =~ ~s(id="replay-#{done.id}")
    refute html =~ ~s(id="replay-#{running.id}")
  end

  test "each run row puts the steps toggle on exactly its 7 data cells", ctx do
    run = seed_running(ctx, "wf-toggle")

    html = render_runs([run])

    # The toggle binding rides on the 7 data cells (Name/Type/Status/Started/
    # Deadline/Owner/Lease expires), each carrying this run's id; the 8th
    # (Actions) cell holds the reveal/cancel/replay buttons and must NOT
    # toggle. Count == 7 proves both.
    assert count_substring(html, ~s(phx-click="toggle_steps" phx-value-id="#{run.id}")) == 7
  end

  test "renders ownership columns; the lease expiry is blanked on terminal rows", ctx do
    live = %{
      seed_running(ctx, "wf-owned")
      | claimed_by: "peer@host",
        claim_expires_at: ~U[2026-07-07 10:30:00Z]
    }

    finished = seed_running(ctx, "wf-owned-done")
    {:ok, _} = WorkflowLog.append(finished, :run_completed, %{result: %{"ok" => true}})
    {:ok, reloaded} = WorkflowRun.by_id(finished.id, tenant: ctx.tenant, actor: ctx.actor)
    # Terminal runs keep their claim columns frozen (lease frozen at terminal):
    # the owner still renders, but the frozen expiry must be blanked or it
    # would imply a live lease on a completed row.
    done = %{reloaded | claimed_by: "gone@host", claim_expires_at: ~U[2026-07-07 09:00:00Z]}

    html = render_runs([live, done])

    assert html =~ "<th>Owner</th>"
    assert html =~ "<th>Lease expires</th>"
    assert html =~ "peer@host"
    assert html =~ "2026-07-07 10:30"
    assert html =~ "gone@host"
    refute html =~ "2026-07-07 09:00"
  end

  test "nil-claim rows render em-dash placeholders in both ownership cells", ctx do
    run = seed_running(ctx, "wf-unclaimed")
    claimed = %{run | claimed_by: "peer@host", claim_expires_at: ~U[2026-07-07 10:30:00Z]}

    # Same run rendered bare vs claimed: exactly the two ownership cells
    # (owner + expiry) fall back to the em dash.
    bare_html = render_runs([run])
    claimed_html = render_runs([claimed])

    assert count_substring(bare_html, "—") == count_substring(claimed_html, "—") + 2
  end

  test "renders the runs_error row (not the empty state) when the load failed" do
    # A load failure writes @runs_error; the template must surface it instead of
    # the misleading "No workflow runs yet" empty state.
    html = render_runs([], runs_error: "Could not load workflow runs")

    assert html =~ "Could not load workflow runs"
    refute html =~ "No workflow runs yet"
  end

  # -- Helpers --

  defp count_substring(haystack, needle) do
    parts = String.split(haystack, needle)
    length(parts) - 1
  end

  defp seed_running(ctx, name) do
    {:ok, run} = WorkflowRun.create(%{name: name}, tenant: ctx.tenant, actor: ctx.actor)
    {:ok, _} = WorkflowLog.append(run, :run_started, %{})
    {:ok, running} = WorkflowRun.by_id(run.id, tenant: ctx.tenant, actor: ctx.actor)
    running
  end

  defp render_runs(runs, overrides \\ []) do
    %{
      __changed__: %{},
      runs: runs,
      runs_error: nil,
      expanded_run_id: nil,
      steps: [],
      steps_error: nil,
      replay_blocked: %{},
      replay_diagnostics: %{},
      reveal_runs: MapSet.new(),
      steps_view: :graph,
      step_graph: nil,
      flash: %{}
    }
    |> Map.merge(Map.new(overrides))
    |> WorkflowsLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp build_socket(actor) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_actor: actor,
        runs: [],
        runs_error: nil,
        flash: %{}
      }
    }
  end
end
