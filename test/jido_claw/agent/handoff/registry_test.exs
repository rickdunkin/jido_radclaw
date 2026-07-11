defmodule JidoClaw.Agent.Handoff.RegistryTest do
  # async-safe against the process-global Registry singleton: tests within
  # this module run serially, and the {"acme"|"other", "s1"|"s2"} keys used
  # here are private to this file (no other test file touches them — keep it
  # that way), so concurrent modules can't observe or disturb them. on_exit
  # clears exactly these keys, never the whole registry.
  use ExUnit.Case, async: true

  alias JidoClaw.Agent.Handoff
  alias JidoClaw.Agent.Handoff.Registry, as: HandoffRegistry

  setup do
    # Clean slate per test — the registry persists across tests because it
    # lives in the supervision tree.
    on_exit(fn ->
      HandoffRegistry.clear("acme", "s1")
      HandoffRegistry.clear("acme", "s2")
      HandoffRegistry.clear("other", "s1")
    end)

    :ok
  end

  defp handoff_fixture(opts \\ []) do
    Handoff.new(%{
      tenant_id: Keyword.get(opts, :tenant_id, "acme"),
      runtime_session_id: Keyword.get(opts, :runtime_session_id, "s1"),
      session_uuid: Keyword.get(opts, :session_uuid, Ecto.UUID.generate()),
      from_template: Keyword.get(opts, :from_template, "main"),
      to_template: Keyword.get(opts, :to_template, "reviewer"),
      to_module: Keyword.get(opts, :to_module, JidoClaw.Agent.Workers.Reviewer),
      message: Keyword.get(opts, :message, "Please review")
    })
  end

  describe "round-trip" do
    test "put_owner/owner/mark_preamble_consumed/clear" do
      handoff = handoff_fixture()

      assert HandoffRegistry.owner("acme", "s1") == nil

      assert :ok = HandoffRegistry.put_owner("acme", "s1", handoff)

      owner = HandoffRegistry.owner("acme", "s1")
      assert owner.template == "reviewer"
      assert owner.module == JidoClaw.Agent.Workers.Reviewer
      assert owner.handoff == handoff
      assert is_integer(owner.updated_at_ms)
      assert owner.preamble_consumed? == false
      assert owner.prompt_injected_pid == nil

      assert :ok = HandoffRegistry.mark_preamble_consumed("acme", "s1")
      assert HandoffRegistry.owner("acme", "s1").preamble_consumed? == true

      worker = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = HandoffRegistry.mark_prompt_injected("acme", "s1", worker)
      assert HandoffRegistry.owner("acme", "s1").prompt_injected_pid == worker
      Process.exit(worker, :kill)

      assert :ok = HandoffRegistry.clear("acme", "s1")
      assert HandoffRegistry.owner("acme", "s1") == nil
    end

    test "put_owner/4 honors :preamble_consumed? and :prompt_injected_pid opts" do
      handoff = handoff_fixture()

      assert :ok =
               HandoffRegistry.put_owner("acme", "s1", handoff,
                 preamble_consumed?: true,
                 prompt_injected_pid: self()
               )

      owner = HandoffRegistry.owner("acme", "s1")
      assert owner.preamble_consumed? == true
      assert owner.prompt_injected_pid == self()
    end
  end

  describe "isolation" do
    test "{tenant, session} keys are independent" do
      h1 = handoff_fixture(runtime_session_id: "s1", to_template: "reviewer")
      h2 = handoff_fixture(runtime_session_id: "s2", to_template: "coder")

      h3 =
        handoff_fixture(
          tenant_id: "other",
          runtime_session_id: "s1",
          to_template: "researcher"
        )

      :ok = HandoffRegistry.put_owner("acme", "s1", h1)
      :ok = HandoffRegistry.put_owner("acme", "s2", h2)
      :ok = HandoffRegistry.put_owner("other", "s1", h3)

      assert HandoffRegistry.owner("acme", "s1").template == "reviewer"
      assert HandoffRegistry.owner("acme", "s2").template == "coder"
      assert HandoffRegistry.owner("other", "s1").template == "researcher"

      :ok = HandoffRegistry.clear("acme", "s1")
      assert HandoffRegistry.owner("acme", "s1") == nil
      assert HandoffRegistry.owner("acme", "s2").template == "coder"
      assert HandoffRegistry.owner("other", "s1").template == "researcher"
    end
  end

  describe "idempotency" do
    test "mark_preamble_consumed on absent entry is a no-op" do
      assert :ok = HandoffRegistry.mark_preamble_consumed("acme", "s1")
      assert HandoffRegistry.owner("acme", "s1") == nil
    end

    test "mark_prompt_injected on absent entry is a no-op" do
      assert :ok = HandoffRegistry.mark_prompt_injected("acme", "s1", self())
      assert HandoffRegistry.owner("acme", "s1") == nil
    end

    test "clear/2 of absent entry returns :ok" do
      assert :ok = HandoffRegistry.clear("acme", "absent")
    end
  end
end
