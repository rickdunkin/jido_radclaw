defmodule JidoClaw.Conversations.RequestCorrelationTest do
  @moduledoc """
  `RequestCorrelation` is `global? true` (see
  `lib/jido_claw/conversations/resources/request_correlation.ex:79-83`):
  the resource keeps `tenant_id` as a regular accepted attribute and
  callers (`lib/jido_claw.ex:192`) supply it inside the attrs map.
  These tests mirror that production-call shape rather than threading
  `tenant:` opts through, since the `:attribute` strategy under
  `global? true` does not auto-populate the attribute from the opt and
  the action would fail with `field: :tenant_id ... required`.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.RequestCorrelation

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
    seed_full(
      tenant_label: "rc",
      session: [kind: :api, external_id: "ext-rc-#{System.unique_integer([:positive])}"]
    )
  end
end
