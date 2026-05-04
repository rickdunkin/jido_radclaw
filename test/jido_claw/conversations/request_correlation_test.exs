defmodule JidoClaw.Conversations.RequestCorrelationTest do
  use ExUnit.Case, async: false

  alias JidoClaw.Conversations.{RequestCorrelation, Session}
  alias JidoClaw.Workspaces.Workspace

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(JidoClaw.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  describe ":register accept list" do
    test "supplying :inserted_at is rejected (not in accept list)" do
      %{tenant_id: tenant, session: session} = seed()

      result =
        RequestCorrelation.register(%{
          request_id: "req-#{System.unique_integer([:positive])}",
          session_id: session.id,
          tenant_id: tenant,
          inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      # Ash returns an Ash.Error.Invalid wrapping an
      # Ash.Error.Invalid.NoSuchInput (or similar) when an unaccepted
      # attribute is supplied. Match loosely on the shape — the
      # important contract is that the call fails, not the exact error
      # struct, which can vary across Ash versions.
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "registering without :inserted_at and :expires_at uses build-time defaults" do
      %{tenant_id: tenant, session: session} = seed()

      request_id = "req-#{System.unique_integer([:positive])}"

      assert {:ok, row} =
               RequestCorrelation.register(%{
                 request_id: request_id,
                 session_id: session.id,
                 tenant_id: tenant
               })

      now = DateTime.utc_now()
      delta_seconds = DateTime.diff(row.expires_at, now, :second)

      # The default should land within a small window of `now + 600`.
      assert delta_seconds in 595..600,
             "expected expires_at ~600s ahead of now, got delta=#{delta_seconds}s"
    end
  end

  defp seed do
    tenant = "tenant-rc-#{System.unique_integer([:positive])}"

    {:ok, ws} =
      Workspace.register(%{
        tenant_id: tenant,
        path: "/tmp/rc-#{System.unique_integer([:positive])}",
        name: "rc"
      })

    {:ok, session} =
      Session.start(%{
        workspace_id: ws.id,
        tenant_id: tenant,
        kind: :api,
        external_id: "ext-rc-#{System.unique_integer([:positive])}",
        started_at: DateTime.utc_now()
      })

    %{tenant_id: tenant, workspace: ws, session: session}
  end
end
