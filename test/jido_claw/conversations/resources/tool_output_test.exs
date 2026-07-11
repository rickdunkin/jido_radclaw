defmodule JidoClaw.Conversations.ToolOutputTest do
  use JidoClaw.TenantCase, async: true

  import Ecto.Query

  alias Ash.Resource.Info
  alias JidoClaw.Conversations.ToolOutput
  alias JidoClaw.Tools.OutputShaper.Store

  defp store_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        ref: JidoClaw.Refs.mint("out_"),
        tool: "run_command",
        command: "mix test",
        command_fingerprint: Store.fingerprint("mix test"),
        content: "full captured output",
        byte_size: 21,
        truncated: false,
        exit_code: 0,
        summary: %{"passed" => 3, "failed" => 0}
      },
      overrides
    )
  end

  defp backdate(ref, tenant_id, datetime) do
    {1, _} =
      JidoClaw.Repo.update_all(
        from(t in "tool_outputs", where: t.ref == ^ref and t.tenant_id == ^tenant_id),
        set: [inserted_at: datetime]
      )

    :ok
  end

  test "store + by_ref roundtrip, tenant-scoped" do
    tenant_id = seed_tenant("tool-output")
    actor = actor_for(tenant_id)
    attrs = store_attrs()

    assert {:ok, row} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor)
    assert row.tenant_id == tenant_id
    assert is_nil(row.session_id)

    assert {:ok, fetched} = ToolOutput.by_ref(attrs.ref, tenant: tenant_id, actor: actor)
    assert fetched.content == "full captured output"
    assert fetched.summary == %{"passed" => 3, "failed" => 0}
  end

  test "content round-trips byte-exact, leading/trailing whitespace included" do
    tenant_id = seed_tenant("tool-output-exact")
    actor = actor_for(tenant_id)
    content = "  indented first line\nmiddle\ntrailing newline kept\n"
    attrs = store_attrs(%{content: content, byte_size: byte_size(content)})

    assert {:ok, _row} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor)
    assert {:ok, fetched} = ToolOutput.by_ref(attrs.ref, tenant: tenant_id, actor: actor)

    assert fetched.content == content
    assert byte_size(fetched.content) == fetched.byte_size
  end

  test "ref is unique per tenant" do
    tenant_id = seed_tenant("tool-output-uniq")
    actor = actor_for(tenant_id)
    attrs = store_attrs()

    assert {:ok, _} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor)
    assert {:error, _} = ToolOutput.store(attrs, tenant: tenant_id, actor: actor)
  end

  test "cross-tenant by_ref does not resolve" do
    tenant_a = seed_tenant("tool-output-a")
    tenant_b = seed_tenant("tool-output-b")
    attrs = store_attrs()

    assert {:ok, _} = ToolOutput.store(attrs, tenant: tenant_a, actor: actor_for(tenant_a))

    assert {:error, _} =
             ToolOutput.by_ref(attrs.ref, tenant: tenant_b, actor: actor_for(tenant_b))
  end

  test "a present session must belong to the row's tenant" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-output-fk")
    other_tenant = seed_tenant("tool-output-fk-other")

    # Matching tenant: accepted.
    assert {:ok, row} =
             ToolOutput.store(store_attrs(%{session_id: session.id}),
               tenant: tenant_id,
               actor: actor_for(tenant_id)
             )

    assert row.session_id == session.id

    # Foreign tenant's session: refused with the canonical message.
    assert {:error, error} =
             ToolOutput.store(store_attrs(%{session_id: session.id}),
               tenant: other_tenant,
               actor: actor_for(other_tenant)
             )

    assert Exception.message(error) =~ "cross_tenant_fk_mismatch"
  end

  test "by_ref_scoped resolves own-session and nil-session rows, blocks a foreign session (S-M2)" do
    %{tenant_id: tenant_id, workspace: workspace, session: session_a} =
      seed_full(tenant_label: "tool-output-scoped")

    {:ok, session_b} = seed_session(tenant_id, workspace.id)
    actor = actor_for(tenant_id)

    own = store_attrs(%{session_id: session_a.id})
    cron = store_attrs(%{session_id: nil})
    assert {:ok, _} = ToolOutput.store(own, tenant: tenant_id, actor: actor)
    assert {:ok, _} = ToolOutput.store(cron, tenant: tenant_id, actor: actor)

    # Own session resolves its row.
    assert {:ok, hit} =
             ToolOutput.by_ref_scoped(own.ref, session_a.id, tenant: tenant_id, actor: actor)

    assert hit.ref == own.ref

    # A nil-session (system/cron-minted) row stays reachable from any session.
    assert {:ok, _} =
             ToolOutput.by_ref_scoped(cron.ref, session_a.id, tenant: tenant_id, actor: actor)

    # A DIFFERENT session cannot resolve the first session's row (cross-session peek).
    assert {:error, _} =
             ToolOutput.by_ref_scoped(own.ref, session_b.id, tenant: tenant_id, actor: actor)

    # The tenant-wide by_ref still resolves it (unchanged, for tenant-wide callers).
    assert {:ok, _} = ToolOutput.by_ref(own.ref, tenant: tenant_id, actor: actor)
  end

  test "latest_for_fingerprint returns the newest row for (session, fingerprint, tool)" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-output-fp")
    actor = actor_for(tenant_id)
    fingerprint = Store.fingerprint("mix test")

    old_attrs = store_attrs(%{session_id: session.id, summary: %{"failed" => 3}})
    assert {:ok, _} = ToolOutput.store(old_attrs, tenant: tenant_id, actor: actor)
    backdate(old_attrs.ref, tenant_id, DateTime.add(DateTime.utc_now(), -3600, :second))

    new_attrs = store_attrs(%{session_id: session.id, summary: %{"failed" => 1}})
    assert {:ok, _} = ToolOutput.store(new_attrs, tenant: tenant_id, actor: actor)

    # A row for a DIFFERENT tool with the same fingerprint must not win.
    diff_tool = store_attrs(%{session_id: session.id, tool: "git_diff"})
    assert {:ok, _} = ToolOutput.store(diff_tool, tenant: tenant_id, actor: actor)

    assert {:ok, latest} =
             ToolOutput.latest_for_fingerprint(session.id, fingerprint, "run_command",
               tenant: tenant_id,
               actor: actor
             )

    assert latest.ref == new_attrs.ref
    assert latest.summary == %{"failed" => 1}
  end

  test "expired read + bulk destroy prunes only rows past the cutoff" do
    tenant_id = seed_tenant("tool-output-prune")
    actor = actor_for(tenant_id)

    old_attrs = store_attrs()
    fresh_attrs = store_attrs()

    assert {:ok, _} = ToolOutput.store(old_attrs, tenant: tenant_id, actor: actor)
    assert {:ok, _} = ToolOutput.store(fresh_attrs, tenant: tenant_id, actor: actor)

    backdate(old_attrs.ref, tenant_id, DateTime.add(DateTime.utc_now(), -10 * 86_400, :second))

    cutoff = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    assert {:ok, [expired]} = ToolOutput.expired(cutoff, tenant: tenant_id, actor: actor)
    assert expired.ref == old_attrs.ref

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_destroy([expired], :destroy, %{},
               tenant: tenant_id,
               actor: actor,
               return_errors?: true
             )

    assert {:error, _} = ToolOutput.by_ref(old_attrs.ref, tenant: tenant_id, actor: actor)
    assert {:ok, _} = ToolOutput.by_ref(fresh_attrs.ref, tenant: tenant_id, actor: actor)
  end

  test "Store.put prunes expired rows for the tenant as a side effect" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-output-sp")
    actor = actor_for(tenant_id)

    stale = store_attrs()
    assert {:ok, _} = ToolOutput.store(stale, tenant: tenant_id, actor: actor)
    backdate(stale.ref, tenant_id, DateTime.add(DateTime.utc_now(), -30 * 86_400, :second))

    tool_context = %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}

    assert {:ok, ref} =
             Store.put(
               %{
                 tool: "run_command",
                 command: "mix test",
                 content: "fresh content",
                 byte_size: 13,
                 truncated: false,
                 exit_code: 0,
                 summary: nil
               },
               tool_context
             )

    assert {:ok, _} = ToolOutput.by_ref(ref, tenant: tenant_id, actor: actor)
    assert {:error, _} = ToolOutput.by_ref(stale.ref, tenant: tenant_id, actor: actor)
  end

  test "Store.put redacts the stored command but fingerprints the raw one" do
    %{tenant_id: tenant_id, session: session} = seed_full(tenant_label: "tool-output-red")
    actor = actor_for(tenant_id)

    secret_command = "curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456'"

    assert {:ok, ref} =
             Store.put(
               %{
                 tool: "run_command",
                 command: secret_command,
                 content: "ok",
                 byte_size: 2,
                 truncated: false,
                 exit_code: 0,
                 summary: nil
               },
               %{tenant_id: tenant_id, session_uuid: session.id, actor: actor}
             )

    assert {:ok, row} = ToolOutput.by_ref(ref, tenant: tenant_id, actor: actor)
    assert row.command =~ "Bearer [REDACTED]"
    refute row.command =~ "abcdefghijklmnopqrstuvwxyz123456"
    assert row.command_fingerprint == Store.fingerprint(secret_command)
  end

  test "content is not a public attribute" do
    refute Info.attribute(ToolOutput, :content).public?
  end
end
