defmodule JidoClaw.Conversations.RequestCorrelationTest do
  @moduledoc """
  `RequestCorrelation` is `global? true`: the resource keeps `tenant_id`
  as a regular accepted attribute, while its public interface still requires
  an active, matching tenant actor. These tests mirror that production-facing
  shape. Internal signal plumbing deliberately opts out of authorization at
  each callsite instead of making this resource a general no-actor hole.
  """
  use JidoClaw.TenantCase, async: false

  alias JidoClaw.Conversations.RequestCorrelation

  describe ":register accept list" do
    test "supplying :inserted_at is rejected (not in accept list)" do
      %{tenant_id: tenant, session: session} = seed()
      actor = actor_for(tenant)

      result =
        RequestCorrelation.register(
          %{
            request_id: "req-#{System.unique_integer([:positive])}",
            session_id: session.id,
            tenant_id: tenant,
            inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)
          },
          tenant: tenant,
          actor: actor
        )

      # Ash returns an Ash.Error.Invalid wrapping an
      # Ash.Error.Invalid.NoSuchInput (or similar) when an unaccepted
      # attribute is supplied. Match loosely on the shape — the
      # important contract is that the call fails, not the exact error
      # struct, which can vary across Ash versions.
      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "registering without :inserted_at and :expires_at uses build-time defaults" do
      %{tenant_id: tenant, session: session} = seed()
      actor = actor_for(tenant)

      request_id = "req-#{System.unique_integer([:positive])}"

      assert {:ok, row} =
               RequestCorrelation.register(
                 %{
                   request_id: request_id,
                   session_id: session.id,
                   tenant_id: tenant
                 },
                 tenant: tenant,
                 actor: actor
               )

      # agent_id omitted → resource default "main" (it is now NOT NULL, so an
      # omitted value must fall back to the main slice, never a NULL);
      # subagent omitted → false.
      assert row.agent_id == "main"
      refute row.subagent

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
